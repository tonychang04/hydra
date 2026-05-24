---
status: implemented
date: 2026-05-24
author: hydra worker (ticket #228)
---

# Self-driving autopickup tick: shepherd reconcile + completion-rescue + policy-aware merge surfacing

## Problem

The autopickup tick (spec `docs/specs/2026-04-16-scheduled-autopickup.md`) is described
in `CLAUDE.md` as a procedure Commander hand-runs each interval: preflight, pick, spawn.
The *follow-through* pieces that keep in-flight work moving — reconciling open PRs
(`scripts/pr-shepherd.sh`, #218/#221), rescuing completed-but-unpushed workers
(`scripts/rescue-worker.sh --probe`, #219), and deciding which merge-ready PRs are
policy-eligible to auto-merge (`scripts/merge-policy-lookup.sh`, #20) — exist as
separate, merged scripts but are **not wired into one tick**. Commander therefore
hand-orchestrates each step every interval. The operator asked for "less babysitting"
(2026-05-24); this is the P1/autonomy capstone that chains the pieces.

What's missing is the **deterministic, scriptable glue**: one command that, given the
current state, runs preflight → shepherd reconcile → completion-rescue scan → and
produces a single "what to act on" report (which tickets are pickable, which PRs are
review-ready / merge-ready / orphaned / need-rescue, and — for merge-ready PRs — which
are auto-merge-eligible per policy vs must be surfaced for human merge).

## Goals

- A single `scripts/autopickup-tick.sh` that runs the **deterministic** parts of one
  tick and prints a consolidated status report. It REPORTS; it does not spawn agents,
  run the review gate, or merge. Those decisions remain Commander's.
- Chain, reusing the existing scripts verbatim (no reimplementation):
  1. **Preflight** — `commander/PAUSE` absent + `scripts/validate-state-all.sh` exit 0
     + concurrency headroom (active workers < `budget.json:max_concurrent_workers`).
  2. **PR-shepherd reconcile** — `scripts/pr-shepherd.sh --json` to classify every
     Commander-authored open PR (needs-fix / ci-pending / needs-review-gate /
     ready-to-surface / merge-ready) and flag orphans.
  3. **Completion-rescue scan** — `scripts/rescue-worker.sh --probe` over each
     `state/active.json` worker, surfacing rescuable verdicts
     (`rescue-commits` / `rescue-uncommitted` / `push-only`).
  4. **Merge surfacing** — for each `merge-ready` PR, consult
     `scripts/merge-policy-lookup.sh <slug> <tier>` and classify into
     `auto-merge-eligible` vs `surface-for-human`, obeying the safety rails.
- **Auto-merge safety rails (non-negotiable):**
  - T3 is **never** auto-merge-eligible (merge-policy-lookup hardcodes `never`; the tick
    additionally refuses T3 unconditionally as defense-in-depth).
  - A PR is auto-merge-eligible only if ALL hold: policy is `auto` or
    `auto_if_review_clean`; the PR is review-CLEAN (shepherd state `merge-ready`, i.e.
    reviewed + undrafted + CI-green + no unresolved threads); and the PR does **not**
    touch any safety-rail path.
  - Safety-rail-touching PRs are ALWAYS classified `surface-for-human` regardless of
    policy. Safety-rail paths (the merge mechanism, secrets, hard rails, CI):
    `scripts/merge-policy-lookup.sh`, `scripts/autopickup-tick.sh` itself,
    `scripts/pr-shepherd.sh`, `scripts/rescue-worker.sh`, `policy.md`, `CLAUDE.md`,
    `.github/workflows/`, `*secret*`, `*.env*`, `*auth*`, `*security*`, `*crypto*`,
    and DB migration files.
- A script-kind self-test exercising the whole tick orchestration offline (mocked `gh`
  via the existing `--gh-mock` seam, fixture `state/active.json`, fixture repos file).

## Non-goals

- The tick does **not** spawn workers, run the review gate, or merge. It surfaces a
  report; Commander reads the report and decides. (Keeping the actuation out of the
  script keeps the safety rails in Commander's hands and the script trivially testable.)
- Not a daemon and not a scheduler. `/loop` still drives the cadence; this is the body
  of one tick's deterministic work, callable standalone for inspection.
- Does not change `pr-shepherd.sh`, `rescue-worker.sh`, or `merge-policy-lookup.sh` —
  it composes them.
- Does not add the picking step's `gh issue list` enumeration (that's the existing tick
  procedure and depends on the per-repo `ticket_trigger`); the tick reports pick
  *capacity* (headroom) and leaves enumeration to Commander.

## Proposed approach

`scripts/autopickup-tick.sh` (bash + jq, mirroring `pr-shepherd.sh` / `rescue-worker.sh`
style). Flags:

```
scripts/autopickup-tick.sh [--repo <owner>/<name>] [--tier <T1|T2|T3>] [--json]
    [--state-dir <path>] [--repos-file <path>] [--gh-mock <dir>]
    [--rescue-mock <file>] [--no-rescue] [--no-merge-surface]
```

Flow:

1. **Preflight block.** PAUSE file check; `validate-state-all.sh --state-dir`;
   concurrency headroom = `max_concurrent_workers - active_workers`. Each sub-check is a
   pass/fail line. If preflight fails, the tick still RUNS the read-only shepherd/rescue
   scans (so the operator sees state) but marks `preflight.ok=false` and
   `spawn_blocked=true` in the report — Commander must not spawn.

2. **Shepherd block.** Shell out to `pr-shepherd.sh --json` (passing through `--repo`,
   `--state-dir`, `--gh-mock`). Carry the per-PR rows + summary into the tick report.

3. **Rescue block.** For each worker in `state/active.json`, run
   `rescue-worker.sh --probe <worktree> <branch> <ticket>` and collect the verdict.
   Rescuable verdicts (`rescue-commits`, `rescue-uncommitted`, `push-only`) become
   `needs-rescue` action items; `nothing-to-rescue` is healthy; live-worker verdicts
   (`flaky-tool-retry`, `worker-mid-tool-call`, `worker-looping`) are surfaced verbatim
   so Commander relays/handles per the watchdog spec. A test seam `--rescue-mock <file>`
   reads a JSONL of `{branch, verdict, ...}` lines instead of probing real worktrees
   (self-test fixtures have no real git worktrees to probe).

4. **Merge-surface block.** For each shepherd row with state `merge-ready`, resolve the
   tier (`--tier`, else the repo's `tier_default`, else `T2` — the conservative default)
   and call `merge-policy-lookup.sh <slug> <tier> --repos-file <repos>`. Then:
   - tier `T3` → `surface-for-human` (reason `t3-never`).
   - policy `never` / `human` → `surface-for-human` (reason `policy-<policy>`).
   - PR touches a safety-rail path → `surface-for-human` (reason `safety-rail`). The PR's
     changed files come from the shepherd row when available; if file data is absent the
     tick treats the PR as safety-rail-touching (fail-closed) and surfaces it.
   - else (policy `auto`/`auto_if_review_clean`, non-T3, non-safety-rail, review-clean) →
     `auto-merge-eligible`.

5. **Report.** Human mode: grouped sections (Preflight / Shepherd / Rescue / Merge
   surfacing / Action summary). `--json` mode: one stable additive object
   `{generated_at, repo, preflight:{...}, shepherd:{...}, rescue:[...], merge_surface:[...], actions:{...}}`.

**Why report-only.** The actuation (spawn / review / merge) is where the irreversible
safety decisions live. Keeping the script read-only means (a) it is trivially safe to
run on every tick, (b) the self-test can assert the full classification offline without
mocking `gh pr merge`, and (c) the safety rails (T3-never, policy obey, no rail-touching
auto-merge) are enforced as *classification*, which Commander then obeys — the same
pattern `pr-shepherd.sh` already uses successfully.

### Safety-rail path detection

A PR is "safety-rail-touching" if any of its changed files match a rail glob. The list is
encoded once in the script (`is_safety_rail_path`) and documented above. This is the
mechanism that guarantees: a PR that edits the merge machinery, secrets handling, hard
rails, or CI is **always** surfaced for a human, never auto-merged — even on a repo whose
policy is `auto`. Fail-closed: unknown/absent file lists are treated as rail-touching.

This very ticket's PR touches `scripts/merge-policy-lookup.sh`'s callers + the auto-merge
mechanism, so it is itself safety-rail-adjacent and will be surfaced for human merge.

### Alternatives considered

- **A: Make the tick actuate (spawn + merge) directly.** Rejected — concentrates
  irreversible actions in a shell script, hard to test offline, and removes Commander's
  judgment from the loop. The operator's model is "Commander decides, scripts inform."
- **B: Extend `pr-shepherd.sh` with the merge-policy classification.** Rejected —
  shepherd's contract is "classify open PRs"; merge eligibility needs tier + repos-file +
  rail detection, a distinct concern. Composition keeps each script single-purpose.
- **C (picked):** a thin orchestrator that composes the three existing scripts and adds
  only the merge-eligibility classification + a consolidated report.

## Test plan

`self-test/fixtures/autopickup-tick/run-smoke.sh` (offline; no network, gh, or Claude
auth), wired as the `autopickup-tick-script` golden case (`kind: script`,
`expected_exit: 0`, sentinel `SMOKE_OK`). It asserts:

1. `bash -n` clean; `--help` prints usage; unknown flag exits 2.
2. Full tick with a `--gh-mock` PR fixture (one PR per shepherd state + an orphan), a
   fixture `state/active.json`, a `--rescue-mock` JSONL (one rescuable + one healthy
   worker), and a fixture repos file with mixed merge policies. Assert `--json` shape:
   preflight block present; shepherd summary carried through; rescue list classifies the
   rescuable worker as `needs-rescue` and the healthy one as ok; merge_surface classifies
   the `auto`-policy merge-ready PR as `auto-merge-eligible` and the `human`-policy one as
   `surface-for-human`.
3. **Safety-rail rule:** a merge-ready PR on an `auto`-policy repo whose changed files
   include a rail path (`policy.md`) is `surface-for-human` (reason `safety-rail`), NOT
   auto-merge-eligible.
4. **T3-never rule:** a merge-ready PR resolved at tier T3 is `surface-for-human` (reason
   `t3-never`) even when the repo policy object would otherwise say auto.
5. **Fail-closed:** a merge-ready PR with no changed-file data is `surface-for-human`.
6. Preflight-fail path: with a `commander/PAUSE` marker (fixture state-dir), the report
   sets `spawn_blocked=true` but still emits shepherd + rescue blocks (read-only scans
   never blocked).
7. Human-mode smoke: banner + each section header present.

Run: `./self-test/run.sh --kind script --case autopickup-tick-script` → expect PASS.

## Risks / rollback

- **Risk:** the tick auto-merges something it shouldn't. **Mitigation:** the tick never
  merges — it classifies. The classification is fail-closed (unknown → surface) and
  T3/rail/`human`/`never` always surface. Commander obeys the classification.
- **Risk:** rescue-probe against real worktrees is slow / flaky in the tick. **Mitigation:**
  probes are non-mutating and bounded; the `--rescue-mock` seam keeps the self-test
  offline; a probe failure for one worker is logged and does not abort the tick.
- **Risk:** drift between the rail-path list here and the worker hard-rails in CLAUDE.md.
  **Mitigation:** the list is documented in this spec and encoded in one function; the
  self-test pins the `policy.md` case so a regression in rail detection fails CI.
- **Rollback:** delete `scripts/autopickup-tick.sh` + its fixture + golden case and revert
  the CLAUDE.md tick line. The composed scripts are untouched, so nothing else regresses.

## Implementation notes

- Files added: `scripts/autopickup-tick.sh`, `self-test/fixtures/autopickup-tick/**`
  (run-smoke.sh, gh-mock/, state/, repos/, rescue-mock.jsonl), one golden case in
  `self-test/golden-cases.example.json`.
- Files changed: `CLAUDE.md` "Scheduled autopickup" tick line (chain pr-shepherd +
  completion-rescue + policy-aware merge surfacing) + spec pointer.
- The tick obeys `merge-policy-lookup.sh` verbatim and adds the T3-never +
  rail-surfacing rules on top (defense-in-depth; never weaker than the lookup).
