# Validation contract — #999 (fixture: #307 — non-self-contained Command cells)

> Reconstructs the PR #307 false-positive. These Command cells are NOT runnable
> as written: row 1 has an unfilled `<placeholder>`, row 2 references a bare
> `$VAR` that is never bound. The OLD gate ran them verbatim via `bash -c`; the
> resulting shell errors were reported as code MISMATCHes though the change under
> test was correct. The hardened gate detects each as a CONTRACT AUTHORING ERROR,
> does NOT execute it, and exits 3 (distinct from exit 1 MISMATCH). It must NOT
> print MISMATCH for these rows.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | unfilled placeholder is not runnable | `cat <fixture-logs>` | exit 0 | PASS | (author left a placeholder) |
| 2 | bare unbound variable is not runnable | `echo "$UNBOUND_FIXTURE_VAR_XYZ/out.txt"` | exit 0 | PASS | (author left an unbound $VAR) |
