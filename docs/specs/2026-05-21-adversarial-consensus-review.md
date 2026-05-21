---
title: Adversarial/consensus review pass for security-sensitive PRs (Refute-or-Promote)
status: accepted
date: 2026-05-21
ticket: https://github.com/tonychang04/hydra/issues/199
area: review gate / safety
size: M
authors: [worker-implementation]
supersedes: []
extends:
  - .claude/agents/worker-review.md
  - .claude/skills/classify-pr-for-review/SKILL.md
  - docs/specs/2026-05-21-evidence-based-review-gate.md
---

# Adversarial/consensus review pass for security-sensitive PRs

## Problem

`worker-review` already (a) scopes a diff and runs `/cso` on security-adjacent
files (`*auth*` / `*security*` / `*crypto*` / migrations — `classify-pr-for-review`),
and (b) since #196, binds every acceptance criterion to concrete evidence
(`validate-evidence-table.sh`). What it does NOT yet do is **stress-test the
security findings themselves**.

Today a `/cso` (or `/review`/`/codex`) pass emits security findings and they go
straight into the `SECURITY:`-prefixed Blockers list — which then labels the PR
`commander-stuck` and pages the operator. That is exactly the failure mode the
ticket (#199) cites from the CodeForge / CodeRabbit landscape research: **raw AI
security review gets muted as noise** (one audit: 15% noise + 21% nitpicking,
"engineers mute them"). A security finding that is plausible-but-not-reproducible
costs an operator page, and pages that turn out to be nothing train the operator
to ignore the channel — the worst outcome for the safety pillar.

The community lesson the ticket distills: **the consensus/validation gate is
what makes findings trusted.** A finding has to *survive* an adversarial pass
AND be backed by an empirical oracle before it earns a human's attention.

## Goals

1. **Adversarial pass for security findings only.** For a PR whose diff is
   security-adjacent (the EXISTING `security-trigger` set — unchanged), after the
   first reviewer (`/review` + `/codex review` + `/cso`) produces security
   finding *claims*, run a second, adversarial reviewer over each claim under an
   explicit **KILL MANDATE**: *try to disprove this finding, do not improve it.*
2. **Context asymmetry (anti-anchoring).** The critic sees only the finding
   *claim* + the diff — NOT the first reviewer's reasoning, severity rating, or
   confidence. This prevents the critic from anchoring on the proposer's framing
   and rubber-stamping it.
3. **Cross-family critic.** The critic runs on a DIFFERENT model family than the
   proposer. `codex` is already wired into the review flow (`/codex review`); it
   IS the cross-family critic. No new backend.
4. **The load-bearing HARD RULE: unanimity is not confidence.** Two reviewers
   agreeing does NOT promote a finding. Belief changes ONLY on:
   - a **code-grounded empirical refutation** (the critic shows, against the
     diff, that the finding cannot occur — e.g. the "unsanitized" input is in
     fact validated two lines up), which DROPS the finding; or
   - an **empirical oracle** — a PoC, a failing test, or a reproduction command
     with output — that demonstrates the finding is real, which PROMOTES it.
   A finding with neither (only opinion, only "looks exploitable", only
   agreement) is **DROPPED**, not reported.
5. **Report only validated findings.** Only a finding that (a) was NOT killed by
   the critic AND (b) carries an empirical oracle reaches the
   `SECURITY:`-prefixed Blockers list (and thus the operator page). Everything
   else is dropped (logged in the table as DROPPED with the reason), so the
   operator only ever sees findings worth a page.
6. **Mechanically enforce it** with a deterministic checker
   (`scripts/validate-security-findings.sh`) + a regression test, exactly the
   way #196 enforced the evidence table. The hard rule is a script the reviewer
   runs on the findings table BEFORE escalating — not just prose in a skill.

## Non-goals

- **No new model backend.** The cross-family critic is `/codex review`, already
  wired. We do not add a worker type or a second LLM provider.
- **No change to the `security-trigger` set.** Scope is *exactly* the existing
  `*auth*` / `*security*` / `*crypto*` / migrations triggers from
  `classify-pr-for-review`. T1 / non-security PRs are untouched — the adversarial
  pass simply does not run for them, so no T1 cost.
- **Does not replace the #196 evidence table.** The two gates are orthogonal and
  composable: the EVIDENCE TABLE (#196) binds *acceptance criteria* → evidence;
  the FINDINGS TABLE (#199) binds *security findings* → survived-kill-mandate +
  empirical-oracle. A security PR carries both tables; both checkers must pass.
- **No auto-fix.** `worker-review` never edits code (hard rule). A validated
  finding becomes a `SECURITY:` blocker for the implementer to fix; a dropped
  finding is just logged.
- **The checker does not run the LLM adversarial pass.** The reviewer (an LLM)
  runs the critic + fills the table (gate a/b); the checker validates the
  *table's shape and the report-needs-oracle invariant* (gate c). Keeping the
  checker a pure text validator makes it deterministic and testable — same call
  as #196 (Alternative C, rejected there for the same reason).

## Proposed approach

### Where the pieces live

| File | Change |
|---|---|
| `.claude/skills/classify-pr-for-review/SKILL.md` | Add the "Adversarial pass for security findings" section: kill mandate, context asymmetry, cross-family critic, the FINDINGS TABLE format + a worked example, and the `validate-security-findings.sh` pointer. Conditional on a `security-trigger` diff. |
| `.claude/agents/worker-review.md` | Add a step (after the `/cso` step, before synthesis): for a security-adjacent diff, run the adversarial pass over each security finding claim, build the FINDINGS TABLE, run the checker; only REPORTED rows become `SECURITY:` blockers. |
| `scripts/validate-security-findings.sh` | New. Parses the FINDINGS TABLE out of a review-comment body; enforces the invariant (REPORTED ⇒ survived kill mandate AND has an empirical oracle); exits non-zero on a REPORTED finding without an oracle, or one the critic killed but still REPORTED. |
| `scripts/test-validate-security-findings.sh` | New. Regression test (bash, pass/fail counter, no harness — matches `test-validate-evidence-table.sh` / `test-check-claude-md-size.sh`). The headline assertion: a non-reproducible finding is DROPPED; a PoC-backed one is KEPT. |
| `docs/specs/2026-05-21-adversarial-consensus-review.md` | This spec. |

### The FINDINGS TABLE format

A GitHub-Markdown table with a fixed header, embedded in the review comment for
a security-adjacent PR, AFTER the #196 evidence table (so both coexist) and
BEFORE the `**Blockers**` section:

```markdown
**Security findings — adversarial pass (kill mandate)**

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | SQL injection via `name` param | SURVIVED | PoC `curl ... -d "name=';DROP--"` -> 500 + stacktrace | REPORTED |
| 2 | Timing attack on token compare | REFUTED | critic: compare uses `crypto.timingSafeEqual`, diff `auth.ts:88` | DROPPED |
| 3 | Missing rate limit on /login | SURVIVED | (none) | DROPPED |
```

Columns:

- **`#`** — finding number.
- **`Finding`** — the security finding claim (one line), from the first
  reviewer's `/review`/`/codex`/`/cso` output.
- **`Critic verdict`** — the adversarial pass's verdict on the claim. One of:
  - `SURVIVED` — the critic tried to kill it and could not.
  - `REFUTED` — the critic produced a code-grounded refutation; the finding is
    disproven.
- **`Oracle`** — the empirical demonstration the finding is real: a PoC, a
  failing/added test, or a reproduction command + its output. May be `(none)`.
- **`Disposition`** — `REPORTED` or `DROPPED`. The reviewer's final call,
  which the checker validates against the invariant below.

Rules the checker enforces (the load-bearing HARD RULE, made mechanical):

- Header row is exactly `| # | Finding | Critic verdict | Oracle | Disposition |`
  (case-insensitive on the column words; whitespace-tolerant).
- `Critic verdict` ∈ {`SURVIVED`, `REFUTED`} (case-insensitive). Else malformed.
- `Disposition` ∈ {`REPORTED`, `DROPPED`} (case-insensitive). Else malformed.
- **`REPORTED` ⇒ `Critic verdict` is `SURVIVED` AND `Oracle` is non-empty**
  (after trimming whitespace / placeholders like `-`, `n/a`, `none`,
  backticks-only). This is the whole point: a reported finding survived the kill
  mandate AND has an empirical oracle. Violations:
  - `REPORTED` + `REFUTED`  → the critic disproved it; reporting it pages the
    operator on a non-finding → exit 1.
  - `REPORTED` + empty `Oracle` → "unanimity / opinion is not confidence" → exit 1.
- `DROPPED` rows are always legal regardless of verdict/oracle (a dropped finding
  is the safe direction — it just doesn't reach the operator). A `SURVIVED` +
  no-oracle finding is *correctly* `DROPPED` (row 3 above): it survived critique
  but nobody could demonstrate it, so it is not promoted.
- At least one finding row must exist *when the table is present*. (The table is
  only present for security-adjacent PRs; a clean security PR with zero findings
  simply omits the table — see "When the table is required" below.)

### When the table is required (scope)

The FINDINGS TABLE is required **iff** the diff is security-adjacent (any
`security-trigger` file) AND the first reviewer raised ≥1 security finding. The
checker is invoked by the reviewer in that case. For:

- a non-security PR → no table, checker not run (no T1 cost);
- a security PR with zero raised findings → the reviewer states "0 security
  findings raised" and skips the table (the checker is not run; there is nothing
  to validate).

This keeps the gate scoped to risky PRs exactly as the ticket demands.

### Why a text checker (alternatives considered)

- **Alternative A — prose-only rule in the skill.** Rejected, same as #196:
  prose drifts and is unenforceable; "verify, don't trust" means the gate itself
  must be verifiable. A script makes the invariant testable + CI-runnable.
- **Alternative B — fold the disposition into the #196 evidence table** (add a
  "security?" column). Rejected: conflates two orthogonal invariants (criteria→
  evidence vs finding→oracle), and would force every PR's evidence table to
  carry security columns it doesn't need. A separate, conditionally-present table
  keeps each checker single-purpose and keeps T1 evidence tables lean.
- **Alternative C — let the critic auto-decide disposition inside the checker
  (LLM call).** Rejected: non-deterministic + untestable. The reviewer (already
  an LLM) runs the critic and fills the table; the checker validates structure +
  the report-needs-oracle invariant only. Same split as #196.
- **Chosen:** a conditionally-present Markdown FINDINGS TABLE (reviewer fills it
  from the adversarial pass) + a deterministic bash validator for the
  REPORTED⇒SURVIVED∧oracle invariant.

### Relationship to the watchdog body-prefix contract

The review comment still starts with `Commander review of PR #<n>` (the
`rescue-worker.sh` → `startswith("Commander review")` contract). Both tables are
*additive* sections AFTER that first line. Order in the comment for a security
PR: header → EVIDENCE TABLE (#196) → FINDINGS TABLE (#199) → Blockers /
Concerns / Nits. No watchdog change.

## Test plan

`scripts/test-validate-security-findings.sh` (bash, self-contained, pass/fail
counter, `NO_COLOR` aware — same shape as `test-validate-evidence-table.sh`):

1. **Headline (the ticket's "test for real"): a non-reproducible finding is
   DROPPED, a PoC-backed one is KEPT.** A two-row table where row 1 is
   `SURVIVED` + a real PoC oracle + `REPORTED`, and row 2 is `SURVIVED` + no
   oracle + `DROPPED` → exit 0 (valid). Then flip row 2 to `REPORTED` → exit 1
   (a finding with no oracle cannot be reported).
2. **Valid table → exit 0.** Every `REPORTED` row is `SURVIVED` + has an oracle.
3. **REPORTED with empty Oracle → exit 1.** The "opinion is not confidence"
   violation; stderr names the row.
4. **REPORTED with placeholder Oracle (`-`, `n/a`, `none`, backticks-only) →
   exit 1.** Placeholder is not an oracle.
5. **REPORTED + REFUTED → exit 1.** The critic disproved it; reporting pages the
   operator on a non-finding.
6. **DROPPED + REFUTED + no oracle → exit 0.** A disproven, dropped finding is
   the safe path.
7. **DROPPED + SURVIVED + no oracle → exit 0.** Survived critique but no oracle
   → correctly not promoted.
8. **Illegal critic verdict (`MAYBE`) → exit 1.** Malformed verdict.
9. **Illegal disposition (`ESCALATE`) → exit 1.** Malformed disposition.
10. **Zero finding rows → exit 1.** Table present but empty (the reviewer should
    omit the table entirely if there are no findings, not emit an empty one).
11. **Missing/garbled header → exit 2.** Parse error (table not found).
12. **Reads from stdin and from `--file <path>`** — both input paths.
13. **PoC oracle containing a shell pipe (escaped `\|`) → exit 0.** Confirms the
    pipe-escaping splitter (borrowed from the #196 checker) handles a real
    `curl ... \| grep` oracle without column-shifting.
14. **Full review-comment body with BOTH the #196 evidence table and the #199
    findings table embedded → exit 0** (against this checker) — proves the two
    tables coexist; the findings checker ignores the evidence table and vice
    versa.
15. **--help → exit 0.**

Run the test, paste output, attach to the PR.

## Risks / rollback

- **Risk: reviewers fabricate a weak "oracle" to satisfy the checker** (paste the
  finding text into the Oracle cell). Mitigation: the checker enforces
  *presence*; the skill's worked examples set the quality bar (a real PoC /
  failing test); the human merger sees the table. Presence-checking is the
  mechanizable floor — quality stays a review-of-review concern. V1 ship
  principle: enforce the hard invariant now, tighten with data later (mirrors
  #196's identical risk note).
- **Risk: a real finding gets DROPPED for lack of a PoC** (false negative —
  worse than #196's risk, since this is security). Mitigation: this is the
  *intended* trade — the ticket's hard rule is explicit that unanimity/opinion
  is not enough; a finding nobody can demonstrate is not worth an operator page.
  A `SURVIVED`-but-DROPPED row is still *logged in the table*, so the operator
  scanning the PR can see "we suspected X but couldn't reproduce it" and choose
  to dig. We surface the suspicion without paging on it.
- **Risk: the table breaks the `Commander review` body-prefix contract.**
  Mitigation: both tables go AFTER the header line; the body still starts with
  `Commander review of PR #<n>` (same mitigation as #196).
- **Rollback:** revert the two doc/agent edits + delete the two scripts. The
  checker is opt-in from the agent flow (only for security PRs); nothing else
  calls it, so removal is clean. The findings table degrades to "extra section
  in a comment" if the checker is removed.
