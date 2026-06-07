# Validation contract — #256 (worker-validator: re-run the contract for truth)

> Written BEFORE implementation from the ticket's acceptance criteria (#255 dogfood),
> then filled with captured evidence before finalizing the PR.
> Dogfoods BOTH gates: `validate-contract.sh` (presence, #255) AND
> `revalidate-contract.sh` (truth, #256 — re-runs these same commands).
> Spec: docs/specs/2026-06-07-worker-validator.md

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | revalidate helper CATCHES lying evidence (PASS for a command that actually fails) and exits 1 | `bash scripts/revalidate-contract.sh --file self-test/fixtures/revalidate-contract/lying.md --cwd self-test/fixtures/revalidate-contract` | exit 1 / "MISMATCH" | PASS | ran it -> exit 1; "MISMATCH row 1: the feature works" / "expected exit 0, got exit 1" |
| 2 | revalidate helper PASSES an honest contract whose commands reproduce | `bash scripts/revalidate-contract.sh --file self-test/fixtures/revalidate-contract/honest.md --cwd self-test/fixtures/revalidate-contract` | exit 0 | PASS | ran it -> exit 0; "revalidate-contract: OK (4 re-run reproduced, 1 skipped, 0 warn) over 5 row(s)" |
| 3 | the lying contract PASSES the #255 presence gate (proving the gap #256 closes) | `bash scripts/validate-contract.sh --file self-test/fixtures/revalidate-contract/lying.md` | exit 0 | PASS | ran it -> exit 0; "every PASS carries evidence" (presence != truth proven) |
| 4 | revalidate RED to GREEN regression test is green (incl. #256 UTF-8/Illegal-byte-sequence regression) | `bash scripts/test-revalidate-contract.sh` | exit 0 / "test-revalidate-contract: OK" | PASS | ran it -> exit 0; "test-revalidate-contract: OK (25 passed)"; Test 15 (UTF-8 command output) was RED (4 failed: "tr: Illegal byte sequence") before the LC_ALL=C fix, GREEN after |
| 5 | #255 contract test still green (parity on shared splitter/rules) | `bash scripts/test-validate-contract.sh` | exit 0 / "test-validate-contract: OK" | PASS | ran it -> exit 0; "test-validate-contract: OK (31 passed)" |
| 6 | worker-validator subagent + spec frontmatter pass the CI syntax check | `bash scripts/preflight-syntax.sh` | exit 0 / "syntax-check: OK" | PASS | ran it -> exit 0; "ok docs/specs/2026-06-07-worker-validator.md" + "syntax-check: OK" |
| 7 | self-test script kind has no NEW failures vs baseline (only state-schemas/ajv) | `bash self-test/run.sh --kind script` | only the pre-existing state-schemas SKIP_HAS_AJV failure | PASS | "48 passed · 1 failed · 2 skipped" vs baseline "47 passed · 1 failed · 2 skipped"; the +1 pass is `revalidate-contract-script` ✓; the 1 failure is the pre-existing `state-schemas` step 19 (SKIP_HAS_AJV), untouched by this branch |
| 8 | state schemas + CLAUDE.md size gate stay green | `bash scripts/validate-state-all.sh` | exit 0 / "validate-state-all: OK" | PASS | ran it -> exit 0; "validate-state-all: OK (7 passed, 7 skipped) [validator: ajv strict]"; CLAUDE.md 16855/18000 (93%, NOTICE, under ceiling) |
| 9 | THIS ticket's own contract passes the #255 presence gate (dogfood) | `bash scripts/validate-contract.sh --file validation-contract.md` | exit 0 | PASS | ran it -> exit 0; "9 assertion(s); every row names a command, every PASS carries evidence" (see Final verification in PR body) |
</content>
