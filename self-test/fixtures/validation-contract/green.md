# Validation contract — #999 (fixture: GREEN)

> A complete, filled contract: every assertion names a command and every PASS
> carries captured evidence. `scripts/validate-contract.sh` must exit 0 on this.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | helper rejects a PASS with no evidence | `bash scripts/validate-contract.sh --file red.md` | exit 1 | PASS | `bash scripts/validate-contract.sh --file red.md` -> exit 1; "PASS with NO evidence" |
| 2 | helper accepts a complete contract | `bash scripts/validate-contract.sh --file green.md` | exit 0 | PASS | `bash scripts/validate-contract.sh --file green.md` -> exit 0; "every PASS carries evidence" |
| 3 | spec frontmatter passes CI syntax check | `bash scripts/preflight-syntax.sh` | exit 0 / "syntax-check: OK" | PASS | `scripts/preflight-syntax.sh` -> exit 0; "syntax-check: OK" |
| 4 | live-DB reversal of a migration | `psql -f down.sql` | clean rollback | UNVERIFIED | no live DB in worker scope; deferred |
