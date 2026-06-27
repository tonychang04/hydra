---
status: draft
date: 2026-06-26
author: hydra worker (ticket #310)
---

# Harden revalidate-contract.sh parser — stop false-positive MISMATCHes

## Problem

`scripts/revalidate-contract.sh` is the **truth gate** (#256): the worker-validator
re-runs each `validation-contract` row's Command and compares the ACTUAL exit/output
to the contract's `Expected`. A claimed-PASS row that does not reproduce is a
`MISMATCH` (nonzero exit) — that is how Hydra catches a worker whose pasted evidence
lies. The gate is only useful if a MISMATCH *means* "the code is wrong."

In one session (2026-06-18) the gate produced **false-positive MISMATCHes** on two
PRs because the parser mis-reads contract cells:

- **PR #307** — Command cells that were **not self-contained** were run verbatim via
  `bash -c` and errored: unfilled angle-bracket placeholders (`<fixture>`,
  `<fixture-logs>`), a bare unset `$T`, and trailing parenthetical prose. A shell
  error became a `MISMATCH`, though the change under test was correct.
- **PR #309** — a `grep` Command (grep exits 0 on a match) whose `Expected`
  *description prose* contained the literal string `exit 1`. `expected_exit()`
  scraped `exit 1` out of the prose and demanded the pipeline exit 1 → false
  `MISMATCH`.

Each false positive forced the validator to manually distinguish "parser quirk"
from "real failure." Repeated, that trains the gate's consumers to dismiss real
failures as "probably the parser again" — which destroys the gate's signal. The
truth gate IS observability/safety (P1), so a noisy gate is a P1 regression.

Root causes, confirmed in code:

- `expected_exit()` / `expected_says_nonzero()` match `exit <N>` / nonzero phrasing
  **anywhere** in the `Expected` cell, including free-text prose (the #309 cause).
- A non-self-contained Command cell is run verbatim and its shell error is reported
  as a code `MISMATCH`, indistinguishable from a genuine failure (the #307 cause).

## Goals / non-goals

**Goals:**

1. Read the expected exit code **only from a structured field** — the leading
   `exit <N>` clause of the `Expected` cell — never from free-text prose elsewhere
   in the cell. (Fixes #309.)
2. When a Command cell is **not self-contained / not runnable** (an unfilled
   `<placeholder>`, or a bare `$VAR` with no inline assignment), surface it as a
   **distinct, non-MISMATCH status** ("contract authoring error") with its own
   exit code, and do NOT execute it. (Fixes #307.)
3. Document the contract-cell authoring rules in the authoritative
   validation-contract spec so workers write self-contained, machine-checkable rows.
4. **Preserve true-positive detection.** A row whose self-contained command genuinely
   produces the wrong exit/output is STILL a `MISMATCH`. Regression fixtures prove it.

**Non-goals:**

- **No new table column.** The 6-column contract header (`# | Assertion | Command |
  Expected | Verdict | Evidence`) is shared with `validate-contract.sh`,
  `contract-path.sh`, every existing contract, and the spec. The "structured exit
  field" is the existing **leading `exit <N>` clause** of the `Expected` cell, parsed
  strictly — not a 7th column.
- **No change to the lenient output-substring / verdict-fallback rules.** Those
  stay: exit code is the hard signal, a missing output substring is a `WARN`.
- **No attempt to auto-repair a malformed cell.** The gate reports the authoring
  error; the worker fixes the contract.

## Proposed approach

Two surgical parser changes in `scripts/revalidate-contract.sh`:

1. **Structured leading-clause exit parse.** `expected_exit()` and
   `expected_says_nonzero()` now look only at the **leading clause** of `Expected`
   (the segment before the first ` / ` output separator) and require the exit token
   to be **anchored at the start** of that clause (`^[^a-z0-9]*exits? <N>`). Prose
   that merely *contains* "exit 1" no longer parses as an exit expectation; it falls
   back to the verdict (PASS ⇒ require exit 0). The documented `Expected` grammar is
   `exit <N>[ / <output substring>]`, so the exit code always lives in the leading
   clause.

2. **Contract authoring-error pre-flight.** Before re-running a row, a new
   `command_authoring_error()` checks the Command is self-contained. It flags:
   - an angle-bracket placeholder `<token>` (e.g. `<fixture>`, `<n>`), and
   - a bare `$VAR` / `${VAR}` referenced with no inline binding (`VAR=`, `for VAR`,
     `read VAR`, `local/declare/export`) and not an allowlisted env/special var
     (`$HOME`, `$COMMANDER_ROOT`, `$?`, `$HYDRA_*`, …).
   A flagged row is reported as `AUTHORING-ERROR`, is **not executed**, and fails the
   gate with new **exit 3** (distinct from exit 1 MISMATCH / exit 2 parse error). A
   real MISMATCH still takes precedence (exit 1) when both are present.

### Alternatives considered

- **Alternative A — add a 7th `ExpectedExit` column.** Cleanest "structured field",
  but breaks the 6-column header shared across `validate-contract.sh`,
  `contract-path.sh`, every committed contract, and the spec. Rejected: too invasive
  for the bug, and the leading `exit <N>` clause is already a structured field.
- **Alternative B — keep running non-self-contained cells but downgrade their
  failure to a WARN.** Rejected: a WARN doesn't fail the gate, so a genuinely broken
  contract would silently certify. An authoring error must be loud and distinct.
- **Chosen:** anchor the exit parse to the leading clause + a pre-run
  self-containment check with a distinct exit 3, no schema change.

## Test plan

`scripts/test-revalidate-contract.sh` (existing harness) gains cases:

- **(a)** well-formed row → PASS reproduces → exit 0.
- **(b)** grep row whose `Expected` prose contains `exit 1` but whose command exits
  0 → NOT a false MISMATCH → exit 0 (reconstructs #309).
- **(c)** placeholder Command (`<fixture-logs>`) and bare-`$VAR` Command → reported
  `AUTHORING-ERROR`, not run, gate exits 3 (reconstructs #307).
- **(d)** no-regression: a self-contained command that genuinely exits nonzero with
  `Expected: exit 0` → STILL `MISMATCH` → exit 1.

Also: every pre-existing test in `test-revalidate-contract.sh` and
`test-validate-contract.sh` still passes; `scripts/validate-state-all.sh` exits 0;
`.github/workflows/scripts/syntax-check.sh` prints `syntax-check: OK` (this spec +
the validation-contract spec edit have valid frontmatter).

## Risks / rollback

- **Risk: the authoring-error check false-flags a legitimate self-contained command**
  (e.g. one that uses `$HOME`). Mitigation: an env/special-var allowlist + inline-
  binding detection (`for`/`read`/`VAR=`/`local`); the placeholder pattern excludes
  shell redirection (`< file`, `<(...)`, `2>&1`). Regression tests pin both the
  flag and the no-flag cases.
- **Risk: anchoring the exit parse misses an exit expectation a worker wrote in an
  unusual place.** Mitigation: the documented grammar puts `exit <N>` in the leading
  clause; a worker who needs an exact exit writes it there. Worst case the row falls
  back to the verdict (PASS ⇒ exit 0), the existing safe default.
- **Rollback:** revert this spec + the validation-contract spec edit + the
  `revalidate-contract.sh` diff + the new test cases/fixtures. Nothing else depends
  on exit 3; removal is clean.

## Implementation notes

- Implemented in `scripts/revalidate-contract.sh`:
  - `expected_lead()` (new) returns the structured leading clause of Expected;
    `expected_exit()` now anchors `^(arrow )?exit[s]? (code)? <N>` against that
    clause only, and `expected_says_nonzero()` also reads the leading clause —
    so no exit expectation is ever scraped from free-text prose.
  - `command_authoring_error()` (new) flags an unfilled `<placeholder>` (a
    `<word>` token preceded by start/space/`(`, inner begins with a letter — the
    left boundary keeps shell redirection `< file` / `<(…)` / `2>&1` / `<<EOF`
    and quoted markup like `grep '<html>'` from matching) or a bare `$VAR` with
    no inline binding (`VAR=`, `for VAR`, `read/local/declare/export/typeset/
    readonly … VAR`) that is also not allowlisted and not present in the
    environment. Flagged rows are reported `AUTHORING-ERROR`, not executed, and
    fail the gate with **exit 3**; a real MISMATCH (exit 1) takes precedence.
- The PR #307 fixture surfaced a subtlety: the bare-`$VAR` row did not even error
  when run — `echo "$UNBOUND…/out.txt"` expanded the unset var to empty and
  exited 0, so the OLD gate marked it a false **PASS** (treating a placeholder as
  a real value). The authoring-error pre-flight catches both the erroring and the
  silently-empty case.
- Consumer wiring: `.claude/agents/worker-validator.md` gained an exit-3 routing
  bullet (treat as `UNVALIDATED` Concern / fix the contract — never
  `commander-stuck`), so the new distinct exit code does not get misrouted as a
  code BLOCKER (which would re-introduce the false-positive paging this fixes).
- No table-schema change: the 6-column header shared with `validate-contract.sh`
  / `contract-path.sh` / every existing contract is untouched; the "structured
  exit field" is the pre-existing leading `exit <N>` clause, parsed strictly.
