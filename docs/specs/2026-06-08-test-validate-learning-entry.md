---
status: proposed
date: 2026-06-08
author: hydra worker
ticket: 299
tier: T1
---

# Regression test for `validate-learning-entry.sh`

## Problem

`scripts/validate-learning-entry.sh` is named in `CLAUDE.md` as part of the
canonical memory-hygiene tooling (`scripts/{parse-citations,validate-learning-entry,validate-citations,promote-citations}.sh`),
yet it ships zero regression tests. Its peer `promote-citations.sh` has
`scripts/test-promote-citations.sh` (documented in `scripts/README.md`);
`validate-learning-entry.sh` has none.

The script has a precise, testable contract — required frontmatter keys
(`name`, `description`, `type`), an expected-section regex
(`## Conventions` / `## Test commands` / `## Known gotchas`), a 1500-char
line bound, inline `YYYY-MM-DD` date validation, and "report all errors in
one shot" exit-1 behavior — that can silently regress because nothing
exercises it.

## Goals

- Add `scripts/test-validate-learning-entry.sh`, a self-contained
  `mktemp`-fixtured bash regression test matching the shape of
  `scripts/test-promote-citations.sh` (no external harness; colored
  pass/fail counter; `trap 'rm -rf' EXIT`).
- Cover every branch of the validator's contract (see Test plan).
- Add one row to `scripts/README.md` documenting the new test.

## Non-goals

- No change to `validate-learning-entry.sh` itself. This is a test-only
  ticket. The test pins the *current* behavior; if a test reveals a bug in
  the validator, that is a separate ticket.
- No CI wiring changes — the test follows the same "operator pre-push, or
  CI" convention as the sibling `test-*.sh` scripts.

## Proposed approach

A single bash script, `scripts/test-validate-learning-entry.sh`, that:

1. Resolves the script-under-test relative to its own `BASH_SOURCE` dir
   (same as `test-promote-citations.sh`), so it runs from any cwd.
2. Provides a `write_entry` fixture helper that writes a learnings file
   into a per-test `mktemp` dir.
3. Runs the validator with `--memory-dir` pointed at the fixture dir and
   captures stdout/stderr/exit-code separately.
4. Asserts on exit code AND, for failure cases, on the specific error
   substring in stderr — so the test pins *which* check fired, not just
   that *a* check fired.

**Alternative considered:** a `bats`-based test. Rejected — the repo has no
`bats` dependency and every existing `test-*.sh` is plain bash. Following the
existing pattern (a documented Hydra feedback rule) beats introducing a new
test framework.

## Test plan

The new test script asserts (each an independent fixture):

1. Valid entry (frontmatter + a `## Known gotchas` section, short lines,
   valid date) → exit 0.
2. First line not `---` → exit 1, "missing frontmatter".
3. Frontmatter opens but never closes → exit 1, "no closing".
4. Missing `name` key → exit 1, "missing required key: 'name'".
5. Missing `description` key → exit 1, "required key: 'description'".
6. Missing `type` key → exit 1, "required key: 'type'".
7. No expected section heading → exit 1, "no expected section heading".
8. A line > 1500 chars → exit 1, "exceeds 1500 characters".
9. Invalid month (`2026-13-01`) → exit 1, "invalid month".
10. Invalid day (`2026-06-32`) → exit 1, "invalid day".
11. Multiple defects in one file → exit 1 AND ≥2 distinct `  - ` error
    lines (the all-errors-in-one-shot contract).
12. `--memory-dir` override resolves a relative file argument.
13. Missing file → exit 2 (usage/not-found, distinct from 1).
14. Unknown flag → exit 2.
15. No file argument → exit 2.
16. `--help` → exit 0.

Verification command: `bash scripts/test-validate-learning-entry.sh`
(expected: all assertions pass, exit 0). Plus
`bash .github/workflows/scripts/syntax-check.sh` (docs/specs touched) and
`scripts/validate-state-all.sh` (exit 0).

## Risks / rollback

Low risk — adds one new test file plus a README row; no production script
changes. If the test proves flaky or wrong, revert the single commit; no
runtime behavior depends on it.

Implements: this is a test-coverage ticket (#299, T1).
