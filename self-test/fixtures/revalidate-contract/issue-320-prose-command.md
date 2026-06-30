# Validation contract — #999 (fixture: #320 — free-prose Command cells)

> Reconstructs the PR #319 (#127) false-positive: rows 5-8 whose Command column
> holds an English description — no `<placeholder>` and no `$VAR`, so they clear
> the two static authoring arms (#310). The OLD gate executed them verbatim; the
> shell could not find their first word, they exited 127 (command not found), and
> each was reported as a code MISMATCH (a false positive). The widened gate (#320)
> detects a 127 whose first word does NOT resolve via `command -v` and classifies
> the row as a CONTRACT AUTHORING ERROR (exit 3), never a MISMATCH — so this
> reconstruction yields 0 false MISMATCHes.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | stub PATH and assert no real call | `stub-PATH run, assert no REAL_FOO_CALLED` | exit 0 | PASS | (prose, not a runnable command) |
| 2 | assert run output contains a marker | `assert-output-contains SECRETMARKER in run log` | exit 0 | PASS | (prose, not a runnable command) |
