---
status: proposed
date: 2026-06-08
author: hydra worker
ticket: 300
tier: T1
---

# Spec: regression test for `validate-citations.sh`

Ticket: tonychang04/hydra#300 — "missing-test: validate-citations.sh (canonical citation-liveness check, no coverage)". Tier T1.

## Problem

`scripts/validate-citations.sh` is named in CLAUDE.md as canonical memory-hygiene
tooling (the citation-liveness check that gates skill promotion), but it has **no
regression test**. Its substring-match / quote-unwrap / case-sensitivity logic is
exactly the kind of quiet-breaking code that a refactor can silently regress with
nothing to catch it. A stale citation that still resolves "live" would let a
learning whose source quote no longer exists keep counting toward the 3-cite
promotion threshold.

## Goals

- Add `scripts/test-validate-citations.sh`, a self-contained bash+jq regression
  test matching the shape of the sibling `test-*.sh` scripts (mktemp fixtures,
  pass/fail counter, no external harness, exits non-zero on any failure).
- Cover the behaviors enumerated in the ticket:
  - all citations resolve → exit 0;
  - a key whose quote was deleted from the memory file → exit 1, listed on stderr;
  - quoted (`#"..."`) vs unquoted (`#...`) unwrap both match;
  - case-sensitivity (a case-mismatched quote is stale);
  - a citation pointing at a nonexistent file → stale, exit 1;
  - empty / `{}` citations file → no-op exit 0;
  - `--memory-dir` / `--citations` overrides honored;
  - usage errors (unknown flag, missing flag value, missing files) → exit 2;
  - the `citations`-wrapper vs flat top-level JSON shapes both parse;
  - `_`-prefixed keys (e.g. `_schema`) are skipped;
  - malformed key (no `#`) → stale.

## Non-goals

- **No change to `validate-citations.sh`.** Test-only ticket.
- No touching the S3-sync hook path (`HYDRA_MEMORY_BACKEND=s3`): the test never
  sets that env var, so the hook stays dormant.

## Proposed approach

Mirror `scripts/test-promote-citations.sh`: a `SCRIPT_DIR`-relative locate of the
script under test, colored `ok`/`bad` helpers, a `mktemp -d` fixture root with an
`EXIT` trap, and one numbered `say` block per case. Each case writes a small
memory dir + a citations JSON under tmpdir, runs the script with
`--memory-dir`/`--citations` pointed at the fixtures, and asserts exit code +
stderr content. Run with `NO_COLOR=1` so assertions on captured output are clean.

Add a `scripts/README.md` row for the new test (alongside the
`test-promote-citations.sh` row).

## Test plan

- `bash scripts/test-validate-citations.sh` → exit 0, all cases pass.
- `bash .github/workflows/scripts/syntax-check.sh` → exit 0 (docs/specs touched).
- `scripts/validate-state-all.sh` → exit 0 (no state changed; sanity).

## Risks / rollback

Negligible — additive test + one doc row. Rollback is deleting the new file and
the README row. The test is hermetic (mktemp only); it never reads real
`state/memory-citations.json` or the real `memory/` tree except where a case
explicitly points at the real repo (none here), so it cannot be flaky on memory
content drift.
