# Validation contract — #999 (fixture: LYING evidence)

> The verify-first GAP #256 closes. Assertion 1 is marked PASS with non-empty
> pasted evidence ("works") — so it SAILS THROUGH the #255 presence gate
> (`validate-contract.sh` exit 0). But its Command, when actually RE-RUN, exits
> nonzero. `scripts/revalidate-contract.sh` re-runs it, sees the real failure,
> and exits 1 (MISMATCH). This file proves presence != truth.
>
> All commands here are self-contained (no repo paths) so the fixture re-runs
> identically from any --cwd.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | the feature works | `sh -c 'exit 1'` | exit 0 | PASS | works -- ran it, all green |
| 2 | this one is honest | `sh -c 'exit 0'` | exit 0 | PASS | ran it -> exit 0 |
</content>
