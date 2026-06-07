# Validation contract — #999 (fixture: RED)

> A broken contract: assertion 1 is marked PASS but its Evidence cell is empty
> (the worker CLAIMED it passed without proving it), and assertion 2 names no
> command at all (not verify-first). `scripts/validate-contract.sh` must exit 1.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | helper rejects a PASS with no evidence | `bash scripts/validate-contract.sh --file red.md` | exit 1 | PASS |  |
| 2 | helper accepts a complete contract |  | exit 0 | PASS | claimed it works |
