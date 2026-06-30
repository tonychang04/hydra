# Validation contract — #999 (fixture: #320 no-regression — real command, real 127)

> The load-bearing guard. Exit 127 is an AUTHORING signal ONLY when the Command's
> first word does NOT resolve via `command -v`. Here the first word is `sh` — a
> real command — that legitimately exits 127. The widened gate MUST still report
> this as a MISMATCH (exit 1): hardening must never silence a true failure just
> because the exit code happens to be 127.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | a real command (sh) that exits 127 stays a MISMATCH | `sh -c 'exit 127'` | exit 0 | PASS | claimed it returns 0 |
