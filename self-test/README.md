# Commander self-test

Regression harness that runs the commander against known-good closed PRs to catch when a change to `CLAUDE.md` / a worker subagent / `policy.md` makes worker output meaningfully worse.

**This IS "using the commander to test the commander"** — the same auto-testing + worktree-spawning primitives that clear real tickets also validate our own changes.

## Files

- `run.sh` — the executable runner (bash + jq). Reads the cases file, dispatches per kind, prints per-case results + a summary.
- `golden-cases.json` — your validated cases (gitignored; copy from `golden-cases.example.json` and fill in). Commander loads this file if it exists; otherwise it falls back to `golden-cases.example.json` so the harness has something to run out of the box.
- `golden-cases.example.json` — committed template + the `memory-validators` and `runner-meta` script cases that actually execute today.
- `baseline.json` — committed floor for net executable assertions. The baseline guard (`scripts/check-self-test-baseline.sh`) fails any PR that drops coverage below it. See "Coverage baseline guard" below (ticket #118).
- `fixtures/` — supporting data (memory-validator fixtures, self-test-runner fixtures).

## When to run

- Before committing changes to `CLAUDE.md`, `.claude/agents/*.md`, or `policy.md`
- Before committing changes to `self-test/run.sh` or any `scripts/*.sh` the golden cases exercise
- Before promoting a skill from memory to a repo
- After any upstream Claude Code / Agent SDK update that could affect worker behavior

## Commands (from worktree root)

```bash
./self-test/run.sh                               # run all cases
./self-test/run.sh --case memory-validators     # run one case by id
./self-test/run.sh --kind script                # only script cases (executable today)
./self-test/run.sh --parallel                   # run concurrently, bounded by budget.json:max_concurrent_workers
./self-test/run.sh --verbose                    # stream command output for each step
./self-test/run.sh --kind script --json         # machine-readable summary (for the baseline guard)
./self-test/run.sh --help                       # full flag reference
```

Exit codes: `0` = all cases passed or skipped · `1` = one or more failed · `2` = usage error / malformed input.

`--json` prints a single object instead of the decorative lines:

```json
{"passed":45,"failed":0,"skipped":4,"executable_assertions":333,"kind":"script"}
```

`executable_assertions` is the count of step-level assertions that actually ran in non-skipped
script cases — the "net assertions" number the coverage guard tracks. It is insensitive to
host-dependent docker/hadolint SKIPs and collapses to 0 in the regression ticket #118 describes.

## Coverage baseline guard (ticket #118)

The harness is Hydra's regression safety net, but a *silent* collapse of its own coverage looks
identical to a green run (exit 0, "0 failed"). That is exactly how #118's "0 cases executing"
regression went unnoticed while workers reported "24 passed". `scripts/check-self-test-baseline.sh`
closes that gap: it runs `run.sh --kind=script --json` and FAILs (exit 1) if `executable_assertions`
drops below `self-test/baseline.json:executable_assertions` (minus `tolerance`).

```bash
scripts/check-self-test-baseline.sh                 # run harness, compare to baseline (exit 1 if regressed)
scripts/check-self-test-baseline.sh --from-json f   # reuse an existing run.sh --json summary (skip the ~90s re-run)
scripts/check-self-test-baseline.sh --update        # rewrite the baseline to the current count (intentional coverage change)
scripts/check-self-test-baseline.sh --json          # {"current":N,"baseline":M,"tolerance":T,"ok":bool}
```

**Where it runs:** wired into `scripts/validate-state-all.sh` (preflight) but **gated behind
`HYDRA_SELFTEST_BASELINE_GATE=1`** so the ~90s harness run is paid at the merge/review gate and in
CI, not on every `pick up` preflight. The canonical merge-gate invocation is
`HYDRA_SELFTEST_BASELINE_GATE=1 scripts/validate-state-all.sh` (or call the guard directly).
A PR that legitimately reduces coverage must lower the baseline via `--update`, making the drop
explicit in the diff. The guard regression-protects itself via the `self-test-baseline-guard`
golden case.

## Case kinds and executor status

| Kind | Executable today? | Example case | Notes |
|---|---|---|---|
| `script` | yes | `memory-validators`, `runner-meta` | Runs each `steps[].cmd` from worktree root; checks `expected_exit`, `expected_stdout_jq`, `expected_stderr_contains`. |
| `worker-implementation` | **SKIP** | `example-case-id`, `cli-50` | Requires Claude auth + dry-run worker harness. Printed as `∅ SKIP: requires Claude auth, not implemented in shell runner`. Future ticket adds the executor. |
| `worker-subagent` | **SKIP** | `test-discovery-dormant-to-active` | Requires spawning a non-implementation worker subagent (e.g. `worker-test-discovery`). Lands with the `worker-implementation` executor. See ticket #32 and `docs/specs/2026-04-16-exercise-test-discovery.md`. |
| `commander-inline` | **SKIP** | `retro-golden-stub` | Requires commander orchestration. |
| `commander-self` | **SKIP** | `autopickup-tick-behavior` | Requires commander orchestration. |

Skips are not failures — the runner exits 0 as long as no executable case FAILs. This lets you land script-kind cases today without being blocked on the worker executor.

## How it works (worker-implementation kind — planned)

For a `worker-implementation` case (currently **SKIP** until the executor lands):
1. Create a worktree at `parent_commit` with branch `commander/self-test-<id>-<timestamp>`
2. Spawn the specified `worker_type` subagent in that worktree with the ticket body summary as the prompt
3. Worker runs DRY RUN: no `gh pr create`, no push — just commits locally
4. Commander diffs the worker's commit against the assertions in `golden-cases.json`
5. Result: pass / fail / degraded (passes hard assertions but regressed quality signals)
6. Clean up the worktree
7. Update `last_run` and `last_result` in `golden-cases.json`

For a `script` case (executable today):
1. Read `steps[]` from the case definition
2. Run each `cmd` from worktree root; capture stdout, stderr, exit code
3. Check `expected_exit`, optional `expected_stdout_jq` (piped through `jq -e`), optional `expected_stderr_contains` (substring)
4. All steps must pass for the case to pass; first failing step stops the case and is reported

## Assertion types (worker-implementation kind — planned)

- `must_touch_paths` — every listed path must appear in the commit's file list
- `must_not_touch_paths` — no listed path may appear (supports globs)
- `must_include_patterns` — each pattern must appear in the commit diff as a string
- `tests_expected` — if true, commit must add at least one `*.test.*` or `*_test.*` file
- `build_must_pass` / `typecheck_must_pass` / `lint_must_pass` — respective command must exit 0
- `typecheck_baseline_compare` — error count ≤ pre-edit baseline (for repos with known pre-existing errors)
- `max_files_changed` — diff touches no more than N files
- `vite_build_must_pass` — npx vite build specifically (for repos where `npm run build` is known-broken on baseline)

## Output format

On a clean run:

```
▸ Running self-test (5 cases, kind=all)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
∅ example-case-id  (SKIP: requires Claude auth, not implemented in shell runner)
∅ retro-golden-stub  (SKIP: requires commander orchestration)
∅ autopickup-tick-behavior  (SKIP: requires commander orchestration)
✓ memory-validators (5 steps, 0s)
✓ runner-meta (4 steps, 1s)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2 passed · 0 failed · 3 skipped    (total 1s)
```

On failure:

```
✗ memory-validators FAIL — step 3 (validate-learning-entry fails on fixture missing frontmatter): expected_exit=1 got 0 (0s)
  --- stdout ---
  ...captured command stdout...
  --- stderr ---
  ...captured command stderr...
```

Use `--verbose` to stream stdout/stderr for every step (not just failures). The captured command output on failure makes it obvious whether the regression is in the runner, the script under test, or the golden assertion itself.

The operator decides whether to revert the commander change or update the golden case (rare — usually means the assertion was too strict). Running the runner against `--cases-file self-test/fixtures/self-test-runner/fake-golden-cases.json` verifies the runner itself still detects failures correctly — this is covered by the `runner-meta` case.
