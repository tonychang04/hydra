## What

## Why (closes #...)

## How

## Test plan

- [ ] `bash -n` / `jq .` on modified shell + JSON files
- [ ] Relevant self-test case passes (once #15 self-test runner lands)
- [ ] Manual smoke test on a fixture repo (if behavior change)
- [ ] Screenshot or log evidence for UI/CLI output changes

## Spec

For non-trivial changes: `docs/specs/YYYY-MM-DD-<slug>.md` is included in this PR. Trivial changes (typo, dep patch, tiny comment edit) skip the spec.

## Risk tier

- [ ] T1 — auto-mergeable (typo, doc, dep patch, pure test addition)
- [ ] T2 — commander auto-merges after review worker clears it
- [ ] T3 — not applicable (T3 tickets are refused, not PR'd)
