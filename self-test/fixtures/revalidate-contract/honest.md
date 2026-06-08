# Validation contract — #999 (fixture: HONEST)

> Every claimed-PASS Command actually reproduces its Expected when re-run.
> `scripts/revalidate-contract.sh` re-runs them all and exits 0.
>
> Covers the parse cases the truth gate must honor:
>   - PASS + `exit 0` Expected, command really exits 0
>   - PASS + `exit 1` Expected, command really exits 1 (a "rejects bad input"
>     proof where a NONZERO exit is the success signal)
>   - PASS + output-substring Expected the command really prints
>   - FAIL row (validator does not need it to pass; informational)
>   - UNVERIFIED row (validator SKIPS it — must not try to run it)
>
> All commands are self-contained so the fixture re-runs from any --cwd.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | a passing command exits 0 | `sh -c 'exit 0'` | exit 0 | PASS | ran it -> exit 0 |
| 2 | a rejecter exits nonzero on bad input | `sh -c 'exit 1'` | exit 1 | PASS | ran it -> exit 1; correctly rejected |
| 3 | the command prints the expected token | `sh -c 'echo READY'` | exit 0 / `READY` | PASS | ran it -> exit 0; stdout `READY` |
| 4 | a known-broken path is observed broken | `sh -c 'exit 3'` | nonzero | FAIL | observed exit 3 |
| 5 | needs production data, not run in worker scope | `psql -f down.sql` | clean rollback | UNVERIFIED | no live DB in worker scope |
