---
status: draft
date: 2026-06-01
author: hydra worker (#118)
ticket: 118
tier: T2
---

# Self-test assertion-count baseline guard

Ticket: #118 — "Self-test harness has zero script-kind cases executing — trust undermined"
Tier: T2 (meta-reliability — the harness IS the safety net)

## Problem

The self-test harness (`self-test/run.sh`) is documented in `CLAUDE.md` as Hydra's
regression safety net — the thing that catches framework drift before a merge lands.
#118 was filed because a smoke-test reported `./self-test/run.sh --kind=script` printing
`no cases matched kind=script` and `--kind=all` SKIPping all cases — net **0 assertions
executing** — while worker reports throughout that session claimed `24 passed`, `26 passed`.

### Root-cause investigation (systematic-debugging Phase 1, on this worktree)

The ticket lists three candidate causes. Investigation findings:

1. **Runtime symptom is no longer reproducible.** On current `main`/this worktree:
   - `./self-test/run.sh --kind=script` → `45 passed · 0 failed · 4 skipped` (106s)
   - `./self-test/run.sh` (all kinds) → `45 passed · 0 failed · 13 skipped` (93s)
   The "0 cases" state was a transient regression fixed by PR #122 (see the ticket's
   own 2026-04-17 correction comment). The golden cases now carry an explicit `kind`
   field; 49 cases are `kind: script` and execute real assertions.

2. **No accounting bug.** `run.sh` tallies `passed` / `failed` / `skipped` in three
   distinct counters (lines ~525-555); a SKIP increments `skipped`, never `passed`.
   Hypothesis #1 from the ticket ("count includes SKIPs as pass") is disproven by reading
   the code. The `N passed` worker claims came from worker self-reports, not from the
   runner mislabelling skips.

3. **The durable defect — the reason nobody noticed — is the missing guard.** The harness
   had no mechanism to detect that its own executable-assertion count had collapsed to 0.
   A regression that silently drops coverage looks identical to a green run: exit 0,
   "0 failed". Checklist item 4 ("Commander preflight adds an assertion: refuse to merge
   any PR that makes self-test net assertions go below the previous baseline") is the only
   un-implemented item and is the fix for the *cause*, not the symptom.

We fix the cause: add a regression detector so a future coverage collapse is caught
automatically instead of relying on a human spotting `0 passed`.

## Goals

- `run.sh` can emit a machine-readable summary (`--json`) including the count of
  **executable assertions** (script-case steps that actually ran — not skips).
- A standalone guard script `scripts/check-self-test-baseline.sh` compares the current
  executable-assertion count against a committed baseline and FAILs (exit 1) when the
  count drops below baseline by more than an allowed tolerance.
- The baseline lives in a committed JSON file (`self-test/baseline.json`) so the guard is
  deterministic and reviewable; a PR that legitimately reduces coverage must update it,
  making the drop explicit in the diff.
- Wire the guard into the Commander preflight (`scripts/validate-state-all.sh`) so it runs
  alongside the existing CLAUDE.md size gate, exactly as #118 item 4 specifies.
- Verify the runtime acceptance items (1-3) with real run output captured in the PR.

## Non-goals

- Building the `worker-subagent` / `worker-implementation` SKIP-path executor (ticket #15
  / #32 territory; the stubbed cases stay SKIP by design).
- Changing how the harness counts pass/fail/skip in human output (the existing format is
  the documented contract).
- Fixing `memory-sync-roundtrip` / docker-gated SKIPs (#115; those SKIP cleanly here).

## Proposed approach

### 1. `run.sh --json`

Add a `--json` flag. When set, suppress the decorative per-case lines and emit one JSON
object to stdout at the end:

```json
{ "passed": 45, "failed": 0, "skipped": 4, "executable_assertions": 312, "kind": "script" }
```

`executable_assertions` = total number of assertion steps that **actually executed** in
passing/failing script cases (sum of `steps[]` length for every script case that was not
skipped). This is the "net assertions" number #118 asks the baseline to track — it goes to
0 precisely in the regression the ticket describes, and is insensitive to docker/hadolint
SKIPs (which legitimately fluctuate by host).

Counting at the step granularity (not the case granularity) makes the metric sensitive to
a case being gutted of its steps, not just deleted wholesale.

**Alternative considered:** count passing *cases* instead of *steps*. Rejected — a case
whose `steps[]` is emptied to `[]` would still "pass" (the for-loop over zero steps
succeeds) and the case count wouldn't move, so the metric would miss exactly the kind of
silent gutting #118 is about. Step-count catches it.

**Alternative considered:** make the runner itself refuse to exit 0 below a hardcoded
threshold. Rejected — couples policy (the threshold) to the executor, and the threshold
grows as cases are added. A separate committed baseline + guard keeps the runner a pure
executor and the policy reviewable in one file.

### 2. `self-test/baseline.json`

```json
{
  "executable_assertions": 300,
  "tolerance": 0,
  "note": "Floor for net executable self-test assertions. A PR that lowers this must say why. Generated/refreshed via scripts/check-self-test-baseline.sh --update.",
  "updated": "2026-06-01",
  "updated_by_ticket": 118
}
```

`tolerance` allows host-dependent SKIP jitter to be absorbed without false alarms; default
0 because `executable_assertions` already excludes skips. The committed baseline is set
conservatively **below** the observed count so host variation (a case that SKIPs on a
machine without docker) cannot trip the guard — the guard's job is catching a *collapse*
(the #118 scenario: count → 0), not policing ±a-few drift.

### 3. `scripts/check-self-test-baseline.sh`

Mirrors `scripts/check-claude-md-size.sh` in shape (same header style, `SCRIPT_DIR`/
`ROOT_DIR` resolution, `--quiet` one-liner, `--help`, exit codes 0/1/2). Behavior:

- Runs `self-test/run.sh --kind=script --json` (script kind only — the deterministic,
  host-runnable subset), parses `executable_assertions`.
- Reads `self-test/baseline.json:executable_assertions` and `tolerance`.
- If `current < baseline - tolerance` → exit 1 with a clear message naming both numbers
  and pointing at `--update`. Else exit 0.
- `--update` rewrites `baseline.json:executable_assertions` to the current count (used by a
  human/worker intentionally changing coverage; the diff makes the change explicit).
- `--quiet` prints nothing on PASS, one line on FAIL (session-greeting/preflight style).
- `--json` emits `{ "current": N, "baseline": M, "tolerance": T, "ok": true|false }`.

To keep preflight fast, the guard caches: it accepts `--from-json <file>` so a caller that
already ran the harness can feed the summary in rather than re-running 90s of cases.

### 4. Preflight wiring

`scripts/validate-state-all.sh` already calls `check-claude-md-size.sh` as its last gate.
Add `check-self-test-baseline.sh --quiet` after it, **non-blocking by default in preflight**
guarded behind an env flag `HYDRA_SELFTEST_BASELINE_GATE` so the 90s harness run does not
tax every `pick up` preflight. The merge-gate use (the #118 ask — "refuse to *merge* a PR")
sets the flag. Document in the spec and `self-test/README.md` that the canonical merge-gate
invocation is `HYDRA_SELFTEST_BASELINE_GATE=1` (or calling the guard directly in CI / the
review gate). This honors "refuse to merge a PR that drops assertions" without making every
ticket-pickup pay a 90s tax — the gate fires where merges are decided.

#### Recursion guard (mandatory — found during resume verification)

The gate runs `check-self-test-baseline.sh`, which runs `self-test/run.sh --kind=script`,
which executes **every** script golden case — including the `state-schemas` case, which
itself shells out to `scripts/validate-state-all.sh --state-dir <fixture>`. Because
`HYDRA_SELFTEST_BASELINE_GATE` is an *exported* env var, a naive gate re-fires inside that
nested `validate-state-all.sh`, which re-runs the harness, which re-runs the nested case — an
unbounded fork explosion (observed: 343 runaway processes; the canonical
`HYDRA_SELFTEST_BASELINE_GATE=1 validate-state-all.sh` never terminated). Two independent
defenses, **either sufficient**, both applied:

1. **`--state-dir` suppression.** Skip the gate whenever `--state-dir` was explicitly passed
   (`state_dir_overridden=1`). A fixture/self-test sub-run has no real `state/` coverage to
   gate, so the gate is meaningless there. This breaks the nested call directly, since the
   `state-schemas` case always passes `--state-dir`.
2. **In-progress marker.** Export `HYDRA_SELFTEST_BASELINE_GATE_ACTIVE=1` around the guard
   invocation and skip the gate if it is already set. Any nested `validate-state-all.sh`
   (however reached) sees the marker and declines to re-enter.

Regression-protected by a 5th step in the `self-test-baseline-guard` golden case asserting
`HYDRA_SELFTEST_BASELINE_GATE=1 validate-state-all.sh --state-dir <fixture>` exits 0 and
emits the skip line (i.e. does not re-enter the harness).

## Test plan

All via `self-test/run.sh` itself (the harness tests the harness — dogfood) plus a new
golden `script` case so the guard is itself under regression protection:

1. **Manual / captured in PR:** `./self-test/run.sh --kind=script` → `N passed · 0 failed`,
   N ≥ 10 (acceptance items 1-3). Paste real output.
2. **`run.sh --json`** emits valid JSON with `executable_assertions` > 0
   (`./self-test/run.sh --kind=script --json | jq -e '.executable_assertions > 100'`).
3. **Guard PASS:** with baseline at the conservative floor, `check-self-test-baseline.sh`
   exits 0.
4. **Guard FAIL (red-green):** feed a synthetic low summary via `--from-json` (a fixture
   reporting `executable_assertions: 0`) → guard exits 1 and names both numbers. This is
   the #118 scenario reproduced as an automated assertion.
5. **`--update`** rewrites the baseline and the guard then passes.
6. **New golden case `self-test-baseline-guard`** (`kind: script`) added to
   `golden-cases.example.json` exercising steps 2-5 above so the guard regression-protects
   itself and shows up in `--kind=script` runs (also nudges the baseline count up).

## Risks / rollback

- **Risk:** baseline set too high → false FAIL on hosts that SKIP docker/hadolint cases.
  Mitigated: the metric excludes skips, and the floor is set below the observed count.
- **Risk:** 90s harness run slows preflight. Mitigated: gated behind
  `HYDRA_SELFTEST_BASELINE_GATE`; default `pick up` preflight unaffected; `--from-json`
  lets a caller reuse an existing run.
- **Touches a safety mechanism** (the merge/preflight gate). Per worker rules this PR is
  surfaced for HUMAN merge, not auto-merged. No change to hard safety rails, secrets, auth,
  or `.github/workflows/`.
- **Rollback:** revert the PR. The guard is additive — `run.sh`'s existing human output and
  exit codes are unchanged when `--json` is absent; removing the preflight line restores
  prior behavior with zero residue.
