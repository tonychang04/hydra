---
status: draft
date: 2026-05-21
author: hydra worker (ticket #190)
---

# Worker watchdog: distinguish idle-stall from blocked-on-flaky-external-tool

## Problem

The worker timeout watchdog (PR #69, ticket #45) treats every silent worker the
same: `scripts/rescue-worker.sh --probe` inspects the worktree, and if there's
nothing to commit/push it returns `nothing-to-rescue` → commander labels the
ticket `commander-stuck` and the worker is killed. The implicit assumption is
"silent past 12 min == idle ghost worth rescuing-and-restarting."

A real dogfood incident broke that assumption. A worker appeared to "stall" for
~13 minutes, but it was **not idle** — the browse/gstack browser daemon was
resetting itself between commands (AVX-less CPU; the daemon crash-loops on that
hardware). The worker was alive the whole time, repeatedly retrying the same
external tool and getting a reset each time. The right response there is **not**
rescue-and-restart (which throws away a live, recoverable worker and re-runs the
exact same failure mode against the same flaky daemon). The right response is to
tell the worker "that external tool is flaky — fall back to a different path"
(e.g. browser daemon down → curl/SDK + a single screenshot) and let the same
live worker continue.

`--probe` currently has no way to express this distinction. Its four verdicts
(`rescue-commits`, `rescue-uncommitted`, `push-only`, `nothing-to-rescue`) are
all derived purely from worktree git state, which is identical between a genuine
idle ghost and a worker that's alive-but-blocked on a flaky tool. Commander
therefore mis-routes the flaky-tool case into the rescue-and-restart path.

## Goals / non-goals

**Goals:**

1. Add a new `--probe` verdict `flaky-tool-retry` that fires when the worker has
   left evidence it is **alive and blocked on a repeatedly-failing external
   tool**, distinct from `nothing-to-rescue` (idle, no progress, safe to
   rescue/restart).
2. Add a new exit code `5 = blocked on flaky external tool; retry with fallback`
   so commander can branch on it without parsing stdout, orthogonal to the
   existing codes (0 success, 1 I/O, 2 usage, 3 rescue-conflict, 4 review-rescue).
3. Carry the failing tool name **and** a worker-supplied fallback path in the
   verdict JSON, so commander can `SendMessage` the worker an actionable
   "retry via <fallback>" hint instead of rescuing.
4. Leave the existing four verdicts and their exit codes (0/3) byte-for-byte
   unchanged — this PR is purely additive. A worker with no flaky-tool evidence
   probes exactly as it does today.
5. Document the new verdict + commander's response, and extend the self-test
   fixture (`self-test/fixtures/rescue-worker/run.sh`) so the idle case, the new
   flaky-tool case, and the unchanged existing verdicts are all asserted in CI.

**Non-goals:**

- **Auto-detecting tool flakiness from the outside.** The watchdog does not
  sniff the browse daemon's health, parse the worker's chat stream, or probe
  hardware capabilities. The *worker* is the authority on "this tool keeps
  failing" — it records that locally; `--probe` reads the record. Keeping the
  detection worker-authored avoids the watchdog re-implementing per-tool health
  checks for every external dependency.
- **Implementing the worker-side fallback logic itself** (curl/SDK substitution,
  screenshot capture). That is worker behavior, documented in the worker prompt /
  skills, out of scope for the watchdog script. This PR defines the *signal* and
  commander's *response*, not the per-tool fallback implementations.
- **Mutating the worktree from `--probe`.** Probe stays read-only, as it is today.
  Commander's response to `flaky-tool-retry` is a `SendMessage` to the live
  worker, not a commit/push.
- **A retry limit / escalation state machine.** This PR gives commander the
  signal and the fallback hint. If the *same* worker emits `flaky-tool-retry`
  again after being told the fallback, commander treats the second occurrence as
  a genuine stall (the fallback didn't help) and falls through to the normal
  rescue/stuck path — documented in the procedure, not encoded as new state.
- **Changing the 12-min watchdog threshold or the `--rescue` / `--probe-review`
  paths.** Untouched.

## Proposed approach

**A worker-authored marker file is the signal.** When a worker detects that an
external tool has failed repeatedly (the daemon keeps resetting), it writes a
small JSON marker into its own worktree at:

```
<worktree>/.hydra/flaky-tool.json
```

Shape:

```json
{
  "tool": "browse-daemon",
  "failures": 4,
  "last_failure_epoch": 1747000000,
  "fallback": "curl/SDK + single screenshot"
}
```

`--probe` checks for this marker **first**, before the existing dirty/commits
logic. If the marker exists, is valid JSON, has `failures >= HYDRA_FLAKY_TOOL_MIN_FAILURES`
(default 2), and `last_failure_epoch` is within the staleness window
(`HYDRA_FLAKY_TOOL_MAX_AGE_S`, default 1800s / 30 min — long enough to cover the
~13-min stall, short enough that a stale marker from an earlier phase of the run
doesn't mis-fire), then `--probe` emits:

```json
{"verdict":"flaky-tool-retry","tool":"browse-daemon","fallback":"curl/SDK + single screenshot","failures":4,"commits_ahead":N,"dirty":true|false}
```

and exits **5**. The worktree git state (`commits_ahead`, `dirty`) is still
reported for observability, but it does **not** change the verdict — a live
worker blocked on a flaky tool is `flaky-tool-retry` whether or not it has
committed partial work.

If the marker is absent, malformed, below the failure threshold, or stale, the
flaky-tool branch is skipped entirely and `--probe` continues into the existing
dirty/commits/pushed logic unchanged. **No marker ⇒ identical behavior to
today.** This is the key safety property: the new path is gated behind an
explicit, recent, worker-written file.

**Commander's response (documented procedure, exit 5):** instead of running
`--rescue`, commander reads `tool` + `fallback` from the verdict and
`SendMessage`s the live worker: *"External tool `<tool>` is flaky and timing out.
Stop retrying it; fall back to `<fallback>` and continue."* The worker — still
alive — picks a different path and proceeds. Commander labels the ticket
`commander-flaky-tool-retry` for observability (P1 pillar). If the same worker
later probes `flaky-tool-retry` a second time (the fallback also failed) or goes
genuinely silent (no fresh marker, worktree idle), commander falls through to the
existing rescue / `commander-stuck` path — no infinite retry.

**Why a marker file (vs. parsing the stream, vs. a new state/*.json):**

- The `--gh-mock` test seam in `--probe-review` already established the pattern of
  a **file-based, offline-testable signal** for this script. A worktree-local
  marker file is the same idea: the fixture seeds it directly; production workers
  write it; CI never needs a live daemon.
- The worker is the only component that *knows* a tool is flaky (it's the one
  getting the resets). A worktree-local file is the natural place for a worker to
  record local run state, and it travels with the worktree the watchdog already
  inspects.
- It keeps the watchdog's blast radius tiny: one extra read of one optional file,
  gated behind existence + recency + a failure threshold. No new global state, no
  daemon health-checking, no chat-stream parsing.

### Alternatives considered

- **A — derive flakiness from worktree mtime + git state heuristics.** E.g. "if
  the worktree was modified in the last 60s but has no new commits, the worker is
  alive but stuck." Rejected: mtime churn doesn't tell you *why* the worker is
  stuck or *which* tool is flaky, so commander couldn't supply a fallback. It
  would also false-fire on a worker that's just thinking/editing slowly.

- **B — a new `--probe-flaky <worktree>` subcommand**, symmetric with
  `--probe-review`. Rejected: `--probe-review` is a separate subcommand because it
  inspects a *different surface* (a PR on GitHub) with *different positional args*.
  Flaky-tool detection inspects the *same surface* `--probe` already does (the
  worktree) with the *same args*, so it belongs as an additional verdict inside
  `--probe`, not a parallel subcommand. Folding it in means commander makes one
  probe call and gets back whichever of the five verdicts applies.

- **C — a marker on the PR / a label instead of a worktree file.** Rejected: the
  worker may die before opening a PR (the implementation-rescue case proves
  workers often time out pre-PR), so there may be no PR to mark. The worktree
  always exists. A worktree-local marker is reachable in every timeout scenario.

- **D — encode the fallback in commander/CLAUDE.md per-tool instead of in the
  marker.** Rejected: the worker knows which tool failed and the most appropriate
  fallback for the work it's doing; baking a static tool→fallback table into
  commander would drift from reality and couldn't express work-specific fallbacks.
  The worker writes the fallback it wants; commander relays it.

## Test plan

All assertions extend the existing offline fixture
`self-test/fixtures/rescue-worker/run.sh` (no network, no `gh`, no live daemon),
which is run by the `worker-timeout-watchdog-script` golden case.

**Existing-behavior regression (verdicts unchanged):**

- `nothing-to-rescue` on a clean branch with **no** flaky-tool marker → unchanged
  (existing fixture step retained).
- `rescue-uncommitted` / `rescue-commits` with **no** marker → unchanged.

**New verdict:**

- A worktree with a valid, recent `.hydra/flaky-tool.json`
  (`failures >= 2`, fresh epoch) → `--probe` emits `"verdict":"flaky-tool-retry"`,
  includes `"tool"` and `"fallback"` from the marker, and exits **5**.
- `flaky-tool-retry` fires **regardless** of worktree dirtiness: assert it on
  both a clean worktree and a dirty one (proves the flaky signal takes precedence
  over the dirty→`rescue-uncommitted` path for a *live* worker).

**Gating / no-false-fire:**

- Marker present but `failures` below the threshold (e.g. `failures: 1`) → falls
  through to the normal verdict (NOT `flaky-tool-retry`).
- Marker present but **stale** (`last_failure_epoch` older than the max-age
  window) → falls through to the normal verdict.
- Marker present but **malformed** (not valid JSON) → falls through to the normal
  verdict, no crash (probe must stay robust; a garbled marker must not break the
  watchdog).

**Contract:**

- `scripts/rescue-worker.sh --help` documents the `flaky-tool-retry` verdict and
  exit code 5.
- `bash -n scripts/rescue-worker.sh` passes (CI `syntax` job).

## Risks / rollback

- **Risk: a stale marker from early in a long run mis-fires `flaky-tool-retry`
  near the end.** Mitigation: the recency window (`last_failure_epoch` within
  `HYDRA_FLAKY_TOOL_MAX_AGE_S`, default 30 min). A marker whose last failure was
  >30 min ago is ignored and probe falls through to git-state verdicts.

- **Risk: commander relays the fallback but the fallback is also flaky → loop.**
  Mitigation: documented "second `flaky-tool-retry` from the same worker, or a
  subsequent genuine silence, falls through to the normal rescue/stuck path." No
  infinite retry; the watchdog degrades to existing behavior.

- **Risk: a malformed marker breaks `--probe` and the whole watchdog jams.**
  Mitigation: the marker read is fully defensive — `jq` parse failures, missing
  fields, and non-numeric `failures`/`last_failure_epoch` all cause the
  flaky-tool branch to be *skipped* (fall through), never to error out. Asserted
  by the malformed-marker fixture step.

- **Risk: exit code 5 collides with a future code.** Mitigation: documented in the
  script header and `--help` (`0` success, `1` I/O, `2` usage, `3`
  rescue-conflict, `4` review-rescue, `5` flaky-tool-retry). Any future code picks
  an unused number.

- **Risk: the marker path `.hydra/` collides with something in a target repo's
  worktree.** Mitigation: `.hydra/` is a hydra-namespaced dir; it is not part of
  any target repo's tree and the marker is read-only from the watchdog's side.
  Workers write it and it travels only inside the worktree.

**Rollback:** revert the single commit that adds the flaky-tool branch to
`--probe`, the `--help`/header lines, and the fixture steps. With the branch
removed, `--probe` returns to its four-verdict behavior; any leftover
`.hydra/flaky-tool.json` markers are simply ignored (no reader). The
implementation- and review-rescue paths are untouched.

## Implementation notes

(Filled in after the PR lands.)
