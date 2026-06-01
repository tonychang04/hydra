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

---

## Amendment — verification flexibility (#191, 2026-06-01)

### Problem (the #191 delta)

A dogfood run proved an app worked end-to-end via **behavioral assertions
(REST/SDK/DOM state checks) + one representative screenshot**, despite a flaky
browser daemon. Read rigidly, a "screenshot at every step" expectation would
have *blocked a genuinely-verified ticket*: the behavior was proven, but the
capture tool that takes the pretty pictures was flaky. The original gate above
already accepts "command + output / test + pass line / diff `file:line`" as
evidence kinds — but it never named **behavioral assertions** as a first-class
kind, never said **one screenshot is enough** (vs. one per step), and gave no
guidance that **a flaky evidence-capture tool must not block** a ticket whose
behavior is otherwise proven.

This amendment makes that policy explicit AND keeps the bar meaningful, so the
flexibility does NOT re-open the "tests claimed not run" regression that #118
just closed.

### Goals (amendment)

1. Name **behavioral assertion** as a first-class evidence kind: a *real
   asserted state check* — an exit code, a DOM/SDK/REST body value, an HTTP
   status — observed and quoted. NOT a claim ("it works", "looks right").
2. State that **one representative screenshot is sufficient corroboration**, not
   a screenshot at every step. A screenshot supplements a behavioral assertion;
   it is never the *sole* proof of a PASS.
3. State that **a flaky evidence-capture tool (e.g. the browse daemon) must not
   block** a criterion whose behavior is proven by a non-visual assertion. This
   reuses the existing flaky-tool fallback already wired at the watchdog layer
   (`docs/specs/2026-05-21-flaky-tool-probe-verdict.md` → "curl/SDK + single
   screenshot") and brings the same posture into the *review gate*.
4. **Keep the bar meaningful (the load-bearing constraint).** A PASS backed by
   *only* a screenshot reference — a picture with no asserted state — is NOT a
   clean pass. A screenshot is not an assertion; it can show a rendered page
   while the underlying state is wrong. So: a **screenshot-only** evidence cell
   is rejected exactly like an empty one. The behavioral assertion is the
   load-bearing evidence; the screenshot rides along.

### Non-goals (amendment)

- Do **not** weaken the core invariant. PASS still REQUIRES non-empty,
  non-placeholder evidence. We are *adding* a rejected sub-case
  (screenshot-only), not removing any.
- Do **not** make screenshots mandatory. A behavioral assertion alone is a
  valid PASS — the screenshot is optional corroboration. We accept assertion-only
  and assertion+screenshot; we reject screenshot-only and empty.
- No change to the security FINDINGS TABLE, the `/cso` trigger set, or the
  `Commander review` body-prefix contract.

### Approach (amendment) — where the pieces change, in lock-step

| File | Change |
|---|---|
| `scripts/validate-evidence-table.sh` | Add a **screenshot-only PASS → exit 1** rule: if a PASS row's evidence, after stripping a leading/embedded screenshot reference (`screenshot`, `screencap`, an image link `![…](…)`, a `.png`/`.jpg` path), has no remaining asserted content, it is treated as EMPTY. Any behavioral assertion in the cell (an exit code, an HTTP status, a quoted body, a `file:line`, a command+output, a `trace:<id>`) keeps the PASS valid. Pure non-screenshot evidence is unaffected. |
| `scripts/test-validate-evidence-table.sh` | New cases: (a) **screenshot-only PASS → exit 1** (the new meaningful-bar assertion); (b) **behavioral assertion + one screenshot → exit 0** (the #191 happy path); (c) **behavioral assertion alone → exit 0** (screenshots stay optional). |
| `.claude/skills/classify-pr-for-review/SKILL.md` | Evidence-kind list + template gain "behavioral assertion (exit code / DOM / SDK / REST body / HTTP status)" and the "one screenshot corroborates, never proves; a flaky capture tool does not block a proven behavior" note. |
| `.claude/agents/worker-review.md` | Verification-gate step (9) names the behavioral-assertion + one-screenshot policy and the flaky-capture-tool-does-not-block rule. |
| `.github/PULL_REQUEST_TEMPLATE.md` | The "Screenshot or log evidence for UI/CLI output changes" line softens to "Behavioral assertion (exit code / DOM / REST state) — plus one screenshot if useful — for UI/CLI output changes; a flaky capture tool doesn't block a proven behavior." |

### Why a screenshot-only PASS is the right thing to reject (alternatives)

- **Alternative A — accept screenshot-only as evidence (any non-empty cell).**
  Rejected: that is exactly the "looks right" pass the gate exists to prevent. A
  screenshot proves a render happened, not that the state is correct (a page can
  render a stale or wrong value). #191 asks for *behavioral assertion + one
  screenshot*, where the assertion is load-bearing — accepting screenshot-only
  would invert that.
- **Alternative B — require a screenshot on every UI PASS.** Rejected: that is
  the rigid "screenshot at every step" rule #191 is removing; it blocks a proven
  ticket when the capture tool is flaky.
- **Chosen:** behavioral assertion is required for a PASS; a screenshot is
  optional corroboration; screenshot-*only* is rejected like empty. The checker
  enforces presence-of-an-assertion deterministically; the human merger still
  sees the screenshot for the human-eyeball check.

### Test plan (amendment)

Extends `scripts/test-validate-evidence-table.sh` (same bash/pass-fail-counter
shape). New assertions, all in the one suite, run + paste output in the PR:

- **Screenshot-only PASS → exit 1.** `| 1 | … | PASS | screenshot dashboard.png |`
  is rejected; stderr names the row and says a screenshot is not an assertion.
- **Behavioral assertion + one screenshot → exit 0.** `… PASS | `curl …/items`
  -> `[{"id":1}]` 200; screenshot dashboard.png |` passes — the assertion
  carries it, the screenshot rides along.
- **Behavioral assertion alone → exit 0.** Screenshots stay optional; an
  assertion-only PASS is still valid (regression guard for non-goal #2).
- All **pre-existing** cases still pass unchanged (the core invariant, the
  trace: forward-compat case, the placeholder cases) — proves additive.

### Risks / rollback (amendment)

- **Risk: the screenshot-detector strips a legitimately-named criterion.** e.g.
  a PASS whose real evidence is the string "screenshot" in a command name.
  Mitigation: the detector only strips a *leading/standalone* screenshot
  reference and an image link; an exit code, HTTP status, quoted body, command
  output, `file:line`, or `trace:` token anywhere in the cell keeps the PASS
  valid. The rejected set is narrow: a cell that is *nothing but* a screenshot
  reference.
- **Risk: re-opening "claimed not run".** Mitigation: this amendment only widens
  the *accepted assertion kinds* (REST/DOM/SDK/exit-code already counted as
  "command + output") and *narrows* PASS by rejecting screenshot-only. The
  non-empty-assertion requirement that #118 relies on is strictly preserved.
- **Rollback:** revert the checker hunk + the new test cases + the three prose
  edits. The core gate is untouched, so rollback returns to the pre-#191 gate
  with no residue.
