---
status: draft
date: 2026-05-23
author: hydra worker
---

# PR Shepherd v1 — reconcile + classify in-flight PRs

## Problem

The Commander loop largely ends at "PR #N passed commander review." After a PR
opens, nothing on the Commander side keeps following it through CI + review
comments to merge-ready. Two concrete failure modes have already been observed:

1. **Orphaned PRs across a session boundary.** A session began with three
   complete, CI-green PRs (#215 / #216 / #217) that had been opened in a prior
   session, then never review-gated and never surfaced for merge. `state/active.json`
   was empty, so nothing tracked them — Commander only found them by luck. There
   is no session-start or per-tick reconciliation that re-attaches in-flight PRs
   to the loop.
2. **Last-mile drift.** Once a PR is open, red CI or a reviewer asking for a
   change requires the operator to notice and re-dispatch. The "follow each PR to
   merge-ready" behavior the ticket asks for (HN "Agent System" PR Shepherd:
   polls CI + review comments until merge-ready) does not exist.

This is squarely on Hydra's directional goal — *every ticket, question, and
failure should make Commander slightly less dependent on the human*. A PR that
goes green and sits unnoticed is a human dependency we can remove.

The triggering signal is the orphaned-PR incident above plus ticket #198
(P2/autonomy, "PR Shepherd"). Extends the existing watchdog/rescue plumbing
(`scripts/rescue-worker.sh`) and the live-board observability tool
(`scripts/build-board.sh`, #193) rather than introducing a new subsystem.

## Goals / non-goals

**Goals (v1):**

- A read-only `scripts/pr-shepherd.sh` that lists Commander-authored open PRs on
  a given repo and classifies each into one actionable state:
  - `needs-fix` — CI red, **or** unresolved human/bot review threads.
  - `needs-review-gate` — CI green and no `commander-reviewed` label yet.
  - `ready-to-surface` — CI green, `commander-reviewed` present, still a draft.
  - `orphaned` — open PR with no matching worker in `state/active.json`.
  - `merge-ready` — CI green, `commander-reviewed`, not a draft (the terminal
    healthy state; printed for completeness so the operator sees "nothing to do").
- A compact human report **and** a machine-readable `--json` mode (so the
  autopickup tick / a future auto-dispatcher can consume it).
- Wire-in documentation: how `pr-shepherd.sh` is called at **session start**
  (reconcile orphans) and on the **autopickup tick** (re-classify in-flight PRs).
- A `script`-kind self-test golden case that exercises every classification
  branch offline via a `--gh-mock` seam (no network, no live `gh`), matching the
  rescue-worker fixture pattern. Advances the self-test-trust theme (#118).

**Non-goals (deferred to v2):**

- **No mutation.** The script never merges, never pushes code, never re-drafts /
  un-drafts a PR, never posts comments. It reports + recommends only.
- **No worker dispatch.** v1 emits a recommended action per PR; it does not spawn
  fix/review workers. Auto-dispatch of fix workers and auto-undraft is v2.
- **No polling daemon.** v1 is a single-shot classifier invoked by the existing
  session-start greeting and the existing autopickup `/loop` tick. No new long-
  running process, no cron beyond what autopickup already provides.
- **No cross-repo fan-out in one call.** One invocation targets one repo
  (default: the current repo). Commander loops over `state/repos.json` itself,
  the same way it already does for ticket pickup.

## Proposed approach

`scripts/pr-shepherd.sh` is a single bash script in the house style
(`set -euo pipefail`, `SCRIPT_DIR`/`ROOT_DIR` resolution, `--help`/`--json`/
value-flag parsing copied from `build-board.sh` and `rescue-worker.sh`, jq for
all JSON handling, exit codes `0` success / `2` usage error / `1` I/O error).

### Inputs

- `gh pr list --repo <owner>/<repo> --author <login> --state open --json
  number,title,headRefName,isDraft,labels,statusCheckRollup,reviewDecision,url`
  — the Commander-authored open PRs and everything needed to classify them.
  `--author` defaults to `@me` (the `gh auth`'d user that authors Commander PRs);
  overridable with `--author <login>`.
- For unresolved-thread detection, `gh pr view <n> --repo <repo> --json
  reviewThreads` per PR (review threads aren't available on `gh pr list`). Only
  fetched for PRs that are otherwise green, to bound the number of calls.
- `state/active.json` — the in-flight worker list. A PR is **matched** to a
  worker when the PR's `headRefName` equals a worker's `branch` (primary join
  key — branch is exact and already recorded per the active.json schema), OR the
  issue number the PR closes equals the worker's ticket number (fallback for
  pre-2026-04-17 entries without `branch`). No match → `orphaned`.

### Classification contract (precedence order)

Evaluated top-down; first match wins, so a red-CI orphan still classifies as
`needs-fix` (the actionable state) while its orphan status is reported as a
boolean field alongside.

1. CI rollup is `FAILURE` / `ERROR` / `TIMED_OUT`  → `needs-fix` (reason: `ci-red`)
2. CI rollup is `PENDING` (still running)          → `ci-pending` (reason: `ci-pending`; no action, re-check next tick)
3. Otherwise CI is green (`SUCCESS` or no checks configured):
   a. unresolved review thread present              → `needs-fix` (reason: `unresolved-threads`)
   b. no `commander-reviewed` label                 → `needs-review-gate`
   c. `commander-reviewed` present **and** isDraft  → `ready-to-surface`
   d. `commander-reviewed` present **and** not draft → `merge-ready`

`orphaned` is an **independent boolean** (`orphaned: true|false`) carried on
every row, not a mutually-exclusive state — because an orphaned PR still has a
CI/review state the operator needs. The session-start reconcile path filters on
`orphaned == true`; the per-tick path acts on the `state` field. This avoids the
"is it orphaned OR red?" ambiguity.

CI rollup mapping uses `statusCheckRollup` from `gh pr list`: the array of check
runs / statuses. Green = every entry `COMPLETED/SUCCESS` (or `state == SUCCESS`)
or an empty array (no checks configured — treated as green, matching `gh pr
merge` behavior). Any `FAILURE`/`ERROR`/`TIMED_OUT`/`CANCELLED` → red. Any
`IN_PROGRESS`/`QUEUED`/`PENDING`/`EXPECTED` with no failures → pending.

### Output

- **Human mode (default):** a compact grouped report — one line per PR with
  `#N  <state>  [orphaned]  <title>` and a trailing recommended-action hint
  (`→ /review`, `→ respawn implementation with CI logs`, `→ surface for merge`,
  `→ wait (CI pending)`, `→ none`). Mirrors `build-board.sh`'s section style.
- **`--json` mode:** `{generated_at, repo, author, prs: [{number, title, url,
  branch, state, reason, orphaned, ci, review_decision, is_draft,
  recommended_action}], summary: {total, needs_fix, needs_review_gate,
  ready_to_surface, merge_ready, ci_pending, orphaned}}`. Stable, additive-only.

### Test seam

A `--gh-mock <dir>` flag (env `HYDRA_PR_SHEPHERD_GH_MOCK`) makes the script read
mocked `gh` responses from `<dir>/pr-list.json` and `<dir>/threads-<n>.json`
instead of shelling out — copied verbatim in spirit from rescue-worker.sh's
`--gh-mock`. This lets the self-test golden case run offline in CI.

### Wire-in (documentation only in v1)

- **Session start:** the greeting path (CLAUDE.md "Session greeting") gains a
  reconcile step — after computing queue counts, run `pr-shepherd.sh --json` per
  enabled repo and, for any `orphaned == true` PR, re-attach it: spawn
  `worker-review` (if `needs-review-gate`) or surface (if `ready-to-surface`).
  This is the fix for the #215/#216/#217 incident.
- **Autopickup tick:** the `/loop` tick (CLAUDE.md "Scheduled autopickup") gains
  a step that runs `pr-shepherd.sh --json` per repo and routes by `state`:
  `needs-review-gate` → spawn `worker-review`; `ready-to-surface` → surface
  "ready for merge"; `needs-fix`/`ci-pending` → note and re-check next tick
  (v1 surfaces; v2 auto-dispatches the fix worker).

In v1 the **script** is the deliverable + the wiring is documented; the actual
auto-dispatch wiring edits to the tick are deliberately a follow-up so this lands
in one worker without touching the autopickup control flow.

### Alternatives considered

- **Alternative A — extend `build-board.sh` to also classify PRs.** Rejected:
  build-board renders *worker* lifecycle from `active.json`/`logs`; PR shepherding
  is a different data source (`gh`) and a different cadence (per-PR network
  calls). Bolting `gh` calls onto the board would make the board slow and couple
  two concerns. A sibling script keeps each tool single-purpose (matches the
  repo's "one clear responsibility per file" norm).
- **Alternative B — a real polling daemon (cron / background process).** Rejected
  for v1: Hydra explicitly avoids daemons (autopickup is a `/loop` tick, not a
  daemon — see `docs/specs/2026-04-16-scheduled-autopickup.md`). A single-shot
  classifier invoked by the existing tick reuses all the existing scheduling and
  preflight machinery for free, and is far easier to self-test.
- **Alternative C — match PRs to workers by issue number only.** Rejected as the
  *primary* key: not every worker entry records its ticket in a parseable form,
  and a PR can close multiple issues. Branch (`headRefName` == worker `branch`)
  is exact and already in the schema; issue number is the documented fallback.

## Test plan

A `script`-kind self-test golden case `pr-shepherd-script` (in
`self-test/golden-cases.example.json`) that:

1. `bash -n scripts/pr-shepherd.sh` — syntax clean.
2. `pr-shepherd.sh --help` exits 0 and prints `Usage:`.
3. `pr-shepherd.sh --bogus` exits 2 (usage error).
4. Runs `self-test/fixtures/pr-shepherd/run-smoke.sh`, which:
   - stages a `--gh-mock` dir with a `pr-list.json` containing one PR per
     classification branch (red CI; pending CI; green+no-label; green+label+draft;
     green+label+undraft; green-but-unresolved-thread) plus an orphan (branch not
     in `active.json`),
   - stages a fixture `active.json` whose worker branches match all but the orphan,
   - asserts human-mode substrings for each state,
   - asserts `--json` mode shape with `jq -e` (per-state counts in `.summary`,
     `orphaned` boolean on the right row, correct `recommended_action`),
   - prints `SMOKE_OK` and exits non-zero on any failed assertion.

This golden case would have failed before this PR (script absent) and passes
after — the canonical Hydra "self-test trust" shape (#118). Run locally with
`self-test/run.sh --case pr-shepherd-script` and `bash self-test/fixtures/pr-shepherd/run-smoke.sh`.

## Risks / rollback

- **Risk: `gh` API field drift.** `statusCheckRollup` / `reviewThreads` JSON
  shapes could change. Mitigation: all parsing is defensive (`// empty`, `// []`)
  and the `--gh-mock` golden case pins the expected shape; a drift breaks the
  self-test loudly rather than silently misclassifying.
- **Risk: rate / call volume.** Per-PR `gh pr view` for threads. Mitigation:
  threads are only fetched for otherwise-green PRs, and v1 is single-shot per
  tick (not a tight poll). v2 can add a `--no-threads` fast mode if needed.
- **Risk: orphan false-positives** when a PR's branch legitimately isn't tracked
  (e.g. a human-authored PR slipped through `--author`). Mitigation: `--author`
  defaults to the Commander's own login, so only Commander-authored PRs are
  considered; everything else is out of scope by construction.
- **Rollback:** the script is read-only and additive (new file + new spec + new
  golden case + one CLAUDE.md pointer line). Revert the PR commit; nothing in the
  live loop depends on it until the documented wire-in edits land in a follow-up.

## Implementation notes

(Filled in after the PR lands.)
