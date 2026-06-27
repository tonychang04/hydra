# Validation contract — #999 (fixture: #309 — exit code in Expected PROSE)

> Reconstructs the PR #309 false-positive. The Command is a `grep` that EXITS 0
> on a match (success). Its Expected cell is human prose that merely *mentions*
> the literal `exit 1` to describe what a no-match would have meant. The OLD
> parser scraped `exit 1` out of that prose and demanded the pipeline exit 1 —
> a false MISMATCH. The hardened parser reads the exit code only from the
> structured leading `exit <N>` clause (absent here), falls back to the verdict
> (PASS ⇒ exit 0), and the grep's real exit 0 reproduces. Expected: exit 0 (OK).
>
> Self-contained so it re-runs from any --cwd.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | grep finds the token and exits 0 | `printf 'foobar\n' \| grep -q foo` | grep prints the matching line; exit 1 would mean the token was absent | PASS | ran it -> exit 0; matched |
