# Validation contract — #255 (verify-first validation contract + evidence gate)

> Written verify-first from ticket #255's acceptance criteria, then filled with
> captured evidence before finalizing the PR. This file dogfoods the very
> mechanism this PR ships — `scripts/validate-contract.sh` validates it.
> Spec: docs/specs/2026-06-07-validation-contract.md

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | A worker emits a contract artifact with per-assertion commands + evidence | `cat validation-contract.md` | this 6-column table exists at the worktree root | PASS | this file IS the artifact; the table parses under `validate-contract.sh` (assertion 4) |
| 2 | Review gate FAILS a contract with an unproven assertion (RED fixture) | `bash scripts/validate-contract.sh --file self-test/fixtures/validation-contract/red.md` | exit 1 | PASS | ran it -> `exit=1`; "row 1 ... PASS with NO evidence" + "row 2 ... names NO command" |
| 3 | Review gate PASSES a complete contract (GREEN fixture) | `bash scripts/validate-contract.sh --file self-test/fixtures/validation-contract/green.md` | exit 0 | PASS | ran it -> `exit=0`; "4 assertion(s); every row names a command, every PASS carries evidence" |
| 4 | Helper validates THIS contract (every PASS has evidence) | `bash scripts/validate-contract.sh --file validation-contract.md` | exit 0 | PASS | ran it -> `exit=0` (see "Final verification" in the PR body) |
| 5 | Full RED->GREEN regression suite passes | `bash scripts/test-validate-contract.sh` | exit 0 / "test-validate-contract: OK" | PASS | ran it -> `FINAL_EXIT=0`; "test-validate-contract: OK (31 passed)" |
| 6 | Spec written with valid frontmatter (CI syntax check) | `bash scripts/preflight-syntax.sh` | exit 0 / "syntax-check: OK" | PASS | ran it -> `PREFLIGHT_EXIT=0`; "ok docs/specs/2026-06-07-validation-contract.md" + "syntax-check: OK" |
| 7 | State schemas + CLAUDE.md size gate stay green | `bash scripts/validate-state-all.sh` | exit 0 | PASS | ran it -> `VSA_EXIT=0`; "validate-state-all: OK (2 passed, 12 skipped)" |
| 8 | CLAUDE.md addition stays under the size ceiling | `bash scripts/check-claude-md-size.sh --quiet` | exit 0 | PASS | ran it -> `exit=0`; "CLAUDE.md: 16413/18000 (91%)" (NOTICE band, under ceiling) |
| 9 | No NEW self-test failures vs baseline | `bash self-test/run.sh --kind script` | only the pre-existing env-dependent `state-schemas` (ajv-present) failure | PASS | "47 passed · 1 failed · 2 skipped"; the 1 failure is `state-schemas` step 19 (`SKIP_HAS_AJV` — ajv installed), pre-existing + untouched by this branch (`git diff --name-only origin/main...HEAD` lists none of validate-state.sh / run.sh / state-schemas) |
| 10 | Both agent definitions mandate the contract (additive wiring) | `grep -l 'validation-contract' .claude/agents/worker-implementation.md .claude/agents/worker-review.md` | both files match | PASS | `grep -l` -> both `.claude/agents/worker-implementation.md` and `.claude/agents/worker-review.md` printed |
