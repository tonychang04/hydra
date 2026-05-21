---
title: Evidence-based review gate (two-gate, EviBound pattern)
status: accepted
date: 2026-05-21
ticket: https://github.com/tonychang04/hydra/issues/196
area: review gate / self-test
size: M
authors: [worker-implementation]
supersedes: []
extends:
  - .claude/agents/worker-review.md
  - .claude/skills/classify-pr-for-review/SKILL.md
---

# Evidence-based review gate

## Problem

`worker-review` today produces a verdict that is structurally good — reviewer is
separated from implementer (`docs/specs/`-era split), the comment has
Blockers / Concerns / Nits sections — but "clean" is still a **judgment call**.
A reviewer can write "looks good, no blockers" without ever showing that the
PR actually does what the ticket asked. That is exactly the "code rot because
nobody really reviewed" failure the operator's standing **"verify, don't trust"**
rule exists to prevent (`memory/MEMORY.md` → `feedback_integration_test_completeness.md`,
`superpowers:verification-before-completion`: *"Evidence before claims, always."*).

The ticket (#196) asks us to make the gate **evidence-bound**: for EACH
acceptance criterion the reviewer must cite concrete evidence (test output, a
diff `file:line`, observed command output) or explicitly mark it `UNVERIFIED`.
**No criterion gets a clean `PASS` without evidence.**

Inspiration (operator-provided, not fetched — no web access in worker mode):
the Coordinator–Implementor–Verifier pattern ("Verifier only approves with
concrete evidence — not 'looks good'") and the EviBound two-gate pattern
(Approval gate → Verification gate).

## Goals

1. **Approval gate (a):** before reviewing, extract the ticket's acceptance
   criteria into a machine-checkable list — one row per criterion.
2. **Verification gate (b):** the reviewer attaches concrete evidence per
   criterion. Verdict is one of `PASS` / `FAIL` / `UNVERIFIED`. Hard rule:
   a `PASS` REQUIRES non-empty evidence; a criterion the reviewer could not
   verify is `UNVERIFIED`, never `PASS`.
3. **Encode the gate as a required EVIDENCE TABLE** in the review-comment
   template: `criterion | verdict | evidence`.
4. **Mechanically enforce** the hard rule with a checker
   (`scripts/validate-evidence-table.sh`) + a regression test that a
   `PASS`-without-evidence review is rejected. So the rule is not just prose
   in a skill — it's a script the reviewer (and CI / future automation) can run
   on the comment body before posting.

## Non-goals

- **Do NOT depend on the #197 session trace.** #197 (session-trace evidence
  source) is in progress, NOT merged. This work is independent: evidence comes
  from test output, diffs, and command output the reviewer gathers directly.
  We leave a clearly-marked extension point so #197's trace becomes an
  *additional* evidence source later — but nothing here requires it.
- No change to the diff-scoping decision table, the `/cso` trigger set, the
  `SECURITY:` → `commander-stuck` path, or the `Commander review` body prefix
  the timeout watchdog matches (`rescue-worker.sh`). The evidence table is
  *additive* — it slots between the header and the Blockers section.
- No restructuring of `worker-review.md` or the skill. Extend in place.
- We do NOT auto-extract acceptance criteria with an LLM call inside the
  checker. The reviewer extracts them (gate a); the checker validates the
  *table's shape and the PASS-needs-evidence invariant* (gate b). Keeping the
  checker a pure text validator makes it deterministic and testable.

## Proposed approach

### Where the pieces live

| File | Change |
|---|---|
| `.claude/skills/classify-pr-for-review/SKILL.md` | Add the two-gate process + the EVIDENCE TABLE to the review-comment template; add a worked example and the `validate-evidence-table.sh` pointer; note the #197 extension point. |
| `.claude/agents/worker-review.md` | Wire the approval gate (step: extract criteria) before review, the verification gate (build the table, run the checker) before posting. |
| `scripts/validate-evidence-table.sh` | New. Parses the evidence table out of a review-comment body; enforces the invariant; exits non-zero on a `PASS` without evidence. |
| `scripts/test-validate-evidence-table.sh` | New. Regression test (bash, pass/fail counter, no harness — matches `test-check-claude-md-size.sh`). |
| `docs/specs/2026-05-21-evidence-based-review-gate.md` | This spec. |

### The EVIDENCE TABLE format

A GitHub-Markdown table with a fixed header, embedded in the review comment
between the `Commander review of PR #<n>` header line and the `**Blockers**`
section:

```markdown
**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | <criterion text, from the ticket> | PASS | `pytest tests/x.py::test_y -v` -> `1 passed`; diff `src/x.py:42` |
| 2 | <criterion text> | FAIL | expected JSON 200, got 500 -- `curl .../health` |
| 3 | <criterion text> | UNVERIFIED | needs a live DB; no fixture in this PR |
```

Rules the checker enforces:

- The table header row is exactly `| # | Criterion | Verdict | Evidence |`
  (case-insensitive on the column words; whitespace-tolerant).
- Verdict in {`PASS`, `FAIL`, `UNVERIFIED`} (case-insensitive). Anything else is
  a malformed-verdict error.
- **`PASS` => Evidence cell non-empty** (after trimming whitespace and Markdown
  noise like a lone `-`, `n/a`, `none`, backticks-only). A `PASS` with empty or
  placeholder evidence is the core violation -> exit 1.
- `FAIL` and `UNVERIFIED` rows do not require an evidence-presence check (a
  `FAIL` may legitimately just say what's wrong; `UNVERIFIED` says why it
  couldn't be checked). The checker permits empty cells on those so a
  terse-but-valid `UNVERIFIED` is not blocked.
- At least one criterion row must exist (a review with zero criteria is itself
  a violation — the approval gate produced nothing to verify).

### Why a text checker (alternatives considered)

- **Alternative A — prose-only rule in the skill.** Rejected: the existing
  scoping rules taught us prose drifts and is unenforceable; the operator's
  rule is "verify, don't trust" — the gate itself must be verifiable. A
  script makes the invariant testable and CI-runnable.
- **Alternative B — JSON sidecar instead of a Markdown table.** Rejected:
  the table must be human-readable *in the PR comment* (the whole point is the
  operator/merger reads it). A Markdown table is both human-readable and
  parseable; we don't need a second artifact.
- **Alternative C — LLM-based criterion extraction inside the checker.**
  Rejected: non-deterministic, untestable, and the reviewer (an LLM already)
  does the extraction in gate (a). The checker validates structure + invariant
  only.
- **Chosen:** Markdown table in the comment (gate a fills it, gate b verifies),
  plus a deterministic bash validator for the PASS-needs-evidence invariant.

### #197 extension point (do not depend on it)

The Evidence column accepts any of: a command + its output, a test name + its
pass line, or a diff `file:line`. When #197 (session trace) lands, a fourth
evidence kind — `trace:<id>` pointing at a recorded session-trace step — becomes
available as an *additional* source. The skill marks this with an explicit
`#197 extension point` note and the checker treats any non-empty evidence cell
as valid regardless of kind, so a future `trace:` reference needs **no checker
change**. This spec records the seam so the #197 worker knows where to plug in.

## Test plan

`scripts/test-validate-evidence-table.sh` (bash, self-contained, pass/fail
counter, `NO_COLOR` aware — same shape as `test-check-claude-md-size.sh`):

1. **Valid table -> exit 0.** Every `PASS` row has evidence; verdicts all legal.
2. **PASS without evidence -> exit 1.** The core violation. A row marked `PASS`
   with an empty Evidence cell is rejected; stderr names the offending row.
3. **PASS with placeholder evidence (`-`, `n/a`, `none`, backticks-only) ->
   exit 1.** Placeholder is not evidence.
4. **`UNVERIFIED` with no evidence -> exit 0.** Allowed (not a clean pass).
5. **`FAIL` with no evidence -> exit 0.** Allowed.
6. **Illegal verdict (`MAYBE`) -> exit 1.** Malformed verdict.
7. **Zero criterion rows -> exit 1.** Approval gate produced nothing.
8. **Missing/garbled header row -> exit 2.** Usage/parse error (table not found).
9. **Reads from stdin and from `--file <path>`** — both paths covered.
10. **A `trace:abc123` evidence cell counts as evidence (PASS -> exit 0)** — the
    #197 forward-compat assertion; proves no checker change is needed later.

Run the test, paste output, attach to the PR.

## Risks / rollback

- **Risk: reviewers write low-quality evidence to satisfy the checker** (e.g.
  copy the criterion text into the Evidence cell). Mitigation: the checker
  enforces *presence*, the skill's worked examples set the quality bar, and the
  human merger sees the table. We accept that presence-checking is the
  mechanizable floor; quality stays a review-of-review concern. V1 ship
  principle: enforce the hard invariant now, tighten with data later.
- **Risk: the table breaks the `Commander review` body-prefix contract** the
  watchdog matches (`rescue-worker.sh` -> `startswith("Commander review")`).
  Mitigation: the table goes AFTER the header line; the body still starts with
  `Commander review of PR #<n>`. Covered by leaving that line first in the
  template.
- **Rollback:** revert the three edits + delete the two scripts. The checker is
  opt-in from the agent flow; nothing else calls it, so removal is clean. The
  evidence table degrades gracefully to "extra section in a comment" if the
  checker is removed.
