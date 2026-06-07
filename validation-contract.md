# Validation contract — #256 (worker-validator: re-run the contract for truth)

> Written BEFORE implementation from the ticket's acceptance criteria (#255 dogfood).
> Each assertion names the command that proves it; evidence captured before PR.
> Dogfoods BOTH gates: `validate-contract.sh` (presence, #255) AND
> `revalidate-contract.sh` (truth, #256 — re-runs these same commands).
> Spec: docs/specs/2026-06-07-worker-validator.md

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | revalidate helper CATCHES lying evidence (PASS for a command that actually fails) and exits 1 | `bash scripts/revalidate-contract.sh --file self-test/fixtures/revalidate-contract/lying.md --cwd self-test/fixtures/revalidate-contract` | exit 1 / "MISMATCH" | UNVERIFIED | filled in Phase 2 |
| 2 | revalidate helper PASSES an honest contract whose commands reproduce | `bash scripts/revalidate-contract.sh --file self-test/fixtures/revalidate-contract/honest.md --cwd self-test/fixtures/revalidate-contract` | exit 0 | UNVERIFIED | filled in Phase 2 |
| 3 | the lying contract PASSES the #255 presence gate (proving the gap #256 closes) | `bash scripts/validate-contract.sh --file self-test/fixtures/revalidate-contract/lying.md` | exit 0 | UNVERIFIED | filled in Phase 2 |
| 4 | revalidate RED to GREEN regression test is green | `bash scripts/test-revalidate-contract.sh` | exit 0 / "test-revalidate-contract: OK" | UNVERIFIED | filled in Phase 2 |
| 5 | #255 contract test still green (parity on shared splitter/rules) | `bash scripts/test-validate-contract.sh` | exit 0 / "test-validate-contract: OK" | UNVERIFIED | filled in Phase 2 |
| 6 | worker-validator subagent + spec frontmatter pass the CI syntax check | `bash scripts/preflight-syntax.sh` | exit 0 / "syntax-check: OK" | UNVERIFIED | filled in Phase 2 |
| 7 | self-test script kind has no NEW failures vs baseline (only state-schemas/ajv) | `bash self-test/run.sh --kind script` | only the pre-existing state-schemas SKIP_HAS_AJV failure | UNVERIFIED | filled in Phase 2 |
| 8 | state schemas + CLAUDE.md size gate stay green | `bash scripts/validate-state-all.sh` | exit 0 / "validate-state-all: OK" | UNVERIFIED | filled in Phase 2 |
| 9 | THIS ticket's own contract passes the #255 presence gate (dogfood) | `bash scripts/validate-contract.sh --file validation-contract.md` | exit 0 | UNVERIFIED | filled in Phase 2 |
</content>
