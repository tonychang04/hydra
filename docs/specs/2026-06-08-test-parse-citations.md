---
status: proposed
date: 2026-06-08
author: hydra worker
ticket: 301
tier: T1
---

# Spec: regression test for `parse-citations.sh`

**Ticket:** #301 — missing-test: parse-citations.sh (learning-loop entry point, no coverage)
**Tier:** T1
**Date:** 2026-06-08

## Problem

`scripts/parse-citations.sh` is the entry point of Hydra's learning loop: it
extracts `MEMORY_CITED:` markers from a worker report and emits the JSON delta
Commander merges into `state/memory-citations.json`. That citation count drives
the 3-cite-across-3-tickets skill-promotion threshold (CLAUDE.md). Both
downstream consumers (`promote-citations.sh`) and the sibling validator are
partially covered, but `parse-citations.sh` itself has **no regression test**.
A silent parsing bug here corrupts citation counts and the promotion gate, with
no test to catch it. Of the four scripts named on the memory-lifecycle line in
CLAUDE.md, this is the one whose output feeds all the others — the
highest-leverage coverage gap.

## Goals

- Add `scripts/test-parse-citations.sh`: a self-contained bash + jq regression
  test that locks down the documented contract of `parse-citations.sh`.
- Add a `scripts/README.md` row for the new test, matching the existing
  `test-promote-citations.sh` row style.

## Non-goals

- **Do not modify `parse-citations.sh`.** This is a test-only ticket. The
  script's behavior is the oracle; tests are written against observed,
  contract-matching behavior, not a desired-but-absent behavior.
- No CI-wiring changes (the repo has no central test-runner workflow that
  enumerates `scripts/test-*.sh`; tests are run by operator pre-push / on
  demand, consistent with every existing `test-*.sh`).
- No new fixtures committed to the tree — everything lives in `mktemp`, matching
  the sibling tests' "No fixtures outside `mktemp`" rule.

## Proposed approach

Mirror `scripts/test-promote-citations.sh`'s harness exactly (the established
pattern — `say`/`ok`/`bad` helpers, colored output gated on `NO_COLOR`,
`passed`/`failed` counters, `mktemp -d` + `trap` cleanup, exit 1 if any
assertion failed). Each test feeds a crafted report to `parse-citations.sh` and
asserts on the emitted JSON via `jq` and on the exit code.

Reports point `--memory-dir` at a real tmp dir containing the cited file so the
"referenced file not found" warning (stderr, non-fatal) does not fire — keeping
stderr assertions clean. One case deliberately omits the file to assert the
warning IS emitted and does NOT change the exit code.

### Cases (derived from the ticket's "Proposed fix" enumeration + the script header contract)

1. **Single marker, correct key + `count_delta:1`.** One `MEMORY_CITED:` line →
   one citation key equal to `<file>#"<quote>"` verbatim, `count_delta == 1`,
   `tickets_added == []`.
2. **Multiple markers incl. a duplicate key — counts aggregate.** Two identical
   keys + one distinct key → duplicate key has `count_delta == 2`, distinct key
   `count_delta == 1`; exactly two citation keys total.
3. **`TICKET:` line present → ref attached to every citation.** A leading
   `TICKET: <ref>` line → every citation's `tickets_added == [<ref>]`. With the
   key repeated, `tickets_added` is de-duped to a single entry (`length == 1`).
4. **`TICKET:` absent → empty `tickets_added`.** No ticket line and no `--ticket`
   → every citation's `tickets_added == []`.
5. **Zero markers → `{"citations":{}}` and exit 0.**
6. **Quoted-quote form preserved verbatim in the key.** A quote containing inner
   text + the surrounding straight double quotes survives byte-for-byte as the
   `<file>#"<quote>"` key.
7. **stdin path == `<report-file>` arg path.** The same report via stdin and via
   a filename argument produce byte-identical JSON.
8. **`--ticket` flag overrides/supplements the inline `TICKET:`.** With both a
   `TICKET: from-line` line and `--ticket flag-ref`, the flag value wins
   (`tickets_added == ["flag-ref"]`) — the flag short-circuits the `TICKET:`
   scan in the script.
9. **`--ticket` with no `TICKET:` line.** Flag value attaches to all citations.
10. **Missing cited file → stderr warning, exit still 0.** `--memory-dir` points
    at a dir lacking the cited file → a `warning: referenced file not found`
    line on stderr, JSON still emitted on stdout, exit 0 (lenient by contract).
11. **Usage errors → exit 2.** Unknown flag; `--ticket` / `--memory-dir` with no
    value; two positional file args; nonexistent input file.
12. **`-h` / `--help` → exit 0** and prints the usage banner.
13. **Whitespace tolerance.** A marker with leading indentation and trailing
    whitespace is still extracted and trimmed to the canonical key.

## Test plan

- `bash scripts/test-parse-citations.sh` exits 0 with all assertions passing.
- Negative check: temporarily break an assertion's expectation locally to
  confirm the harness reports `failed > 0` and exits 1 (the harness is the same
  proven one as `test-promote-citations.sh`).
- `bash .github/workflows/scripts/syntax-check.sh` passes (this PR touches a
  `docs/specs/*.md` file).
- `scripts/validate-state-all.sh` exits 0 (no state files touched; regression
  guard).

## Risks / rollback

Minimal. Test-only addition plus a docs row; no production script changes.
Rollback = delete `scripts/test-parse-citations.sh` and revert the README row.
The only behavioral coupling is to `parse-citations.sh`'s contract: if that
script is intentionally changed later, this test must be updated in the same PR
(which is the point — it now guards the contract).
