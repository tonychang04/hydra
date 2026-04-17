---
status: implemented
date: 2026-04-16
author: hydra worker (issue #15)
---

# Self-test runner

## Problem

`self-test/golden-cases.example.json` accumulates cases (`memory-validators`, `retro-golden-stub`, `autopickup-tick-behavior`, worker-implementation stubs like `cli-50`) but there is **no runner** that actually executes any of them. Every assertion there is aspirational. `DEVELOPING.md` tells contributors to "run self-test before committing framework changes," but the command it references is a commander chat intent, not an executable.

This means:

- Adding a golden case today is documentation, not a regression guard.
- Changes to `CLAUDE.md`, worker subagents, or `policy.md` can silently regress behavior.
- The script-kind cases (`memory-validators`) already have enough information to be executed end-to-end in shell, but nothing executes them.

## Goals / non-goals

**Goals:**

- An executable `./self-test/run.sh` that reads `self-test/golden-cases.json` (falling back to `golden-cases.example.json`) and runs each case.
- Full support for `kind: script` cases today (`memory-validators`). Run each `steps[].cmd`, check `expected_exit`, `expected_stdout_jq`, `expected_stderr_contains`. Pass only if all steps pass.
- Documented SKIP path for `worker-implementation`, `commander-inline`, `commander-self` kinds. Skips are not failures; they print a reason and exit 0.
- Flags: `--kind=script|commander-inline|commander-self|worker-implementation|all`, `--case <id>`, `--parallel`, `--verbose`, `--help`.
- `--parallel` concurrency bounded by `jq -r .phase1_subscription_caps.max_concurrent_workers budget.json`.
- Runs from worktree root — does not require `cd`.
- Self-meta: a fixture under `self-test/fixtures/self-test-runner/` with a passing case and a failing case, plus a `runner-meta` entry in `golden-cases.example.json` that exercises the runner against itself.

**Non-goals:**

- Actually spawning workers for `worker-implementation` cases. That needs Claude auth and a proper worker harness; a future ticket adds the executor.
- Running `retro` or autopickup tick simulations. `commander-inline` and `commander-self` require orchestration machinery that is not in place. Both are stubbed as SKIP.
- Rewriting the existing `scripts/*.sh`. The runner matches their style but is additive.
- Any change to `.claude/settings.local.json*`, `policy.md`, `budget.json`, worker subagents, or `state/*.json`.

## Proposed approach

One bash script, `self-test/run.sh`, matching the convention of `scripts/*.sh`:

- `#!/usr/bin/env bash`, `set -euo pipefail`
- `usage()` + `--help`
- Color output when stdout is a TTY, plain otherwise.
- Reads `self-test/golden-cases.json` if it exists, else `self-test/golden-cases.example.json`.
- Parses cases with `jq`. Each case has a `kind` (default inferred: if `kind: script` present it is a script case; otherwise the `worker_type` field — `worker-implementation` / `commander-inline` / `commander-self` — decides).
- Dispatches per kind:
  - **script**: iterates `steps[]`, `eval`s each `cmd` from worktree root, captures stdout+stderr+exit, checks `expected_exit` (default 0), optional `expected_stdout_jq` (pipes stdout through `jq -e`), optional `expected_stderr_contains` (substring). All must pass for the case to pass.
  - **worker-implementation / commander-inline / commander-self**: print SKIP with a reason. Exit 0 for the case.
- Prints per-case lines in the format from `self-test/README.md`:

  ```
  ▸ Running self-test (N cases, kind=K)
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ memory-validators (5 steps, 2.3s)
  ∅ retro-golden-stub  (SKIP: requires commander orchestration)
  ✗ fake-fail         FAIL on step 2: expected_exit=0 got 1
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1 passed · 1 failed · 1 skipped    (total 2.4s)
  ```

- On any FAIL, runner exits with status 1. Skips and passes together exit 0.
- `--parallel` uses `xargs -P <N>` where `<N>` is `jq -r .phase1_subscription_caps.max_concurrent_workers budget.json`. Each parallel invocation is a recursive self-call with `--case <id>`; the parent summarizes results.
- `--verbose` prints captured stdout/stderr for every step (on pass and fail), otherwise only on fail.

### Alternatives considered

- **A: Python runner.** Rich JSON + subprocess control, but adds a Python dep to Hydra. Rejected — hard rule is bash + jq only.
- **B: A `just` / `make` target per kind.** Cleaner dispatch, but requires a second tool and still needs a shell script underneath. Rejected.
- **C (picked):** single bash script, jq for JSON, recursive self-call for parallelism.
- **D: Implement the worker-implementation executor now.** Spec-creep — requires real Claude auth, dry-run worker harness, assertion diffing. Deferred to a follow-up ticket; the runner documents the SKIP path.

## Test plan

1. `bash -n self-test/run.sh` — syntax.
2. `jq . self-test/golden-cases.example.json self-test/fixtures/self-test-runner/fake-golden-cases.json` — JSON validity.
3. Execute against the existing `memory-validators` case. All 5 steps pass; runner exits 0.
4. Execute against `self-test/fixtures/self-test-runner/fake-golden-cases.json --case=fake-fail`. Runner exits 1 with a clear failure line.
5. Execute against `self-test/fixtures/self-test-runner/fake-golden-cases.json --case=fake-pass`. Runner exits 0.
6. Non-script kinds (`retro-golden-stub`, `autopickup-tick-behavior`) print SKIP with the documented reason.
7. The `runner-meta` case in `golden-cases.example.json` exercises both fake-pass and fake-fail via nested script steps, giving the runner a regression guard over itself.

## Risks / rollback

- **Risk:** `expected_stdout_jq` filters that are malformed crash the runner with a non-obvious error. Mitigation: we run jq with `-e` and surface both the jq error output and the stdout snippet when a step fails.
- **Risk:** `--parallel` re-invokes the script per case; a per-case timeout is not implemented. Mitigation: script cases are all local shell commands; runaway steps are caller-responsibility. Revisit once real worker-implementation cases land.
- **Rollback:** delete `self-test/run.sh`, `self-test/fixtures/self-test-runner/`, and this spec; revert the `runner-meta` case + README edits. No other files change.

## Implementation notes

- `kind` is inferred from two fields: an explicit `.kind` (`"script"` today) OR `.worker_type` mapped as: `worker-implementation`→worker-implementation, `commander-inline`→commander-inline, `commander-self`→commander-self, `null`/absent→defaults to `script` when `steps` is present.
- The `runner-meta` case is itself `kind: script` — it just shells out to `./self-test/run.sh` with different fixtures. The runner dogfoods itself.
- Skipped cases are counted separately from passes so `DEVELOPING.md`'s "all golden cases must pass" rule still holds strictly for executable kinds; skips are surfaced loudly so they cannot hide a regression.
