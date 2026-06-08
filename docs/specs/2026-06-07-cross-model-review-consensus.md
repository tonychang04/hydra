---
status: accepted
date: 2026-06-07
ticket: https://github.com/tonychang04/hydra/issues/276
area: worker-review / cross-model review consensus / quality
size: M
authors: [worker-implementation]
---

# Cross-model review consensus + codex graceful degradation in worker-review

**Ticket:** #276 ([P1/quality] Verify + harden cross-model review (Codex consensus) in worker-review)
**Owner artifact:** `.claude/agents/worker-review.md` (+ this spec)

## Problem

The ticket's stated premise is that `worker-review`'s description "claims it runs
/review + /codex review" and asks us to VERIFY whether that is actually wired and,
if it is "documented-but-not-wired", to wire it. A verify-first survey of the real
agent file (`.claude/agents/worker-review.md`, read 2026-06-07) found the premise
is partly inverted, so the fix is NOT what the ticket literally asks:

1. **`/codex review` IS wired — but deliberately OFF by default.** Flow step 6
   reads verbatim: *"`/codex review` is OFF by default — SKIP it unless the spawn
   prompt explicitly opts in (e.g. `codex: on`)."* This is an **intentional
   anti-stall hardening decision**, not an oversight: `/codex review` is "the
   single most reliable reviewer killer (#222)" and killed reviewers on PRs #8,
   #181, #182, #187 by emitting no stream output while polling (see Anti-stall
   discipline section + `docs/specs/2026-05-24-worker-anti-stall-discipline.md`).
   Flipping it on by default would REGRESS that hardening. We must not do that.

2. **Graceful degradation already exists — but only on ONE codex code path.**
   The step-8 security-critic path already says: *"If codex stalls or is
   unavailable as the critic, fall back to Claude's own rigorous re-examination."*
   The step-6 opt-in default path has **no** equivalent "codex missing/errored →
   note it, don't fail the gate" language. That is a real gap.

3. **The agent description (frontmatter line 3) overstates codex.** It says the
   worker *"Runs /review and /codex review"* unconditionally, which contradicts
   step 6 (opt-in only). A future reader / Commander trusts the description.
   Misleading.

4. **No cross-model overlap section in the synthesized comment.** Even when codex
   DOES run (opt-in, or as the step-8 critic), the single posted comment has no
   place that says *which findings only Claude caught / only Codex caught / both*.
   gstack's whole `/codex` lesson is that cross-model consensus catches
   single-model blind spots; surfacing the overlap is what makes the second
   opinion legible to the operator. This is the ticket's core deliverable and a
   genuine gap.

## Goals

- Correct the agent description so "runs codex" reflects the opt-in reality.
- Add graceful-degradation language to the step-6 opt-in path: a one-line binary
  presence check; if codex is missing or errors, the comment carries a
  `codex: unavailable` note and the review still posts (never fails the gate on a
  missing optional engine).
- Add a **Cross-model consensus** section to the synthesized review comment:
  three buckets — *Claude-only*, *Codex-only*, *Both* — populated only when codex
  actually ran; otherwise a single `codex: unavailable` / `codex: not run
  (opt-in)` line so the comment shape is stable.

## Non-goals

- **Do NOT flip `/codex review` on by default.** Opt-in stays opt-in; this is the
  load-bearing anti-stall decision. We harden the path that exists, we don't
  re-route the gate.
- Do NOT touch `worker-implementation.md`, `CLAUDE.md`, `README.md`, `scripts/`,
  or `.claude/skills/*` source (COORDINATE constraint). The consensus-section
  *template* conceptually belongs in `classify-pr-for-review`, but since this
  worker may not edit that skill, the agent file describes the section inline and
  points at the skill as the eventual home — a follow-up ticket can fold the
  literal template into the skill.
- No new bash validator script this ticket (the consensus section is
  informational prose, not a gated invariant like the evidence/findings tables).
  A future ticket can add `validate-consensus-section.sh` if it becomes a gate.

## Proposed approach

Edit `.claude/agents/worker-review.md` only:

1. **Frontmatter description (line 3):** change *"Runs /review and /codex review
   (plus /cso …)"* to make codex conditional: *"Runs /review (plus /cso if
   security-adjacent); /codex review is opt-in (anti-stall) and used as the
   cross-family security critic."* Keeps the adversarial-pass sentence.

2. **Step 6 (opt-in codex path):** prepend a binary-presence guard and a
   degradation rule before the existing bounded-wait instruction:
   - `CODEX_BIN=$(which codex 2>/dev/null || true)` — if empty, SKIP codex and
     record `codex: unavailable (binary not found)` for the consensus section.
   - if codex runs but the bounded wait kills it / it exits nonzero, record
     `codex: unavailable (timed out / errored)` and post the `/review`-only
     partial — **never fail the gate** on the optional engine. (Mirrors the
     step-8 critic fallback, now applied to the default opt-in path too.)

3. **New Flow step 9b (after the evidence gate, before synthesis) — Cross-model
   consensus:** describe building the three buckets (Claude-only / Codex-only /
   Both) by comparing `/review` (+`/cso`) findings against `/codex review`
   findings, keyed on the same file:line / issue. When codex did not run, the
   section is a single status line (`codex: not run (opt-in)` or
   `codex: unavailable (<reason>)`).

4. **Step 10 (synthesis template):** add the **Cross-model consensus** section to
   the comment ordering, AFTER the EVIDENCE TABLE and (when present) the FINDINGS
   TABLE, BEFORE Blockers — so the existing `Commander review` body-prefix
   contract and both validator scripts (which parse only their own tables by
   header) are unaffected. The consensus section is prose/bullets, not a
   pipe-table, so neither `validate-evidence-table.sh` nor
   `validate-security-findings.sh` will mis-parse it.

### Alternatives considered

- **Flip codex on by default + add fallback.** Rejected: regresses the #222
  anti-stall hardening; the fallback would fire on most reviews and add latency
  for little gain, since codex's value is highest as the opt-in security critic.
- **Add a new gated `validate-consensus-section.sh`.** Rejected for this ticket
  (YAGNI): the consensus section is informational, not pass/fail. If it later
  needs enforcement, clone the `validate-*.sh` shape per the #199 learning. Noted
  as a follow-up.
- **Put the literal template in `classify-pr-for-review`.** Correct long-term home
  but out of this worker's edit scope. Describe inline, point at the skill, file a
  follow-up.

## Test plan

This is a documentation/agent-contract change (no executable code), so the tests
are doc-flow assertions following the #188 learning (scope each grep to its
section; assert literal canonical lines; prove the guard with a mutation):

1. **Description reflects opt-in:** the frontmatter `description:` no longer
   asserts unconditional `/codex review`; it qualifies codex as opt-in / critic.
   Assert the line does NOT match `Runs /review and /codex review`.
2. **Step-6 degradation present:** the opt-in codex section contains a
   `which codex` presence check AND a `codex: unavailable` record-and-continue
   rule AND the words "never fail the gate".
3. **Consensus section wired into flow:** a Flow step describes the three buckets
   (`Claude-only`, `Codex-only`, `Both`) AND the synthesis template lists a
   **Cross-model consensus** section positioned after the evidence/findings
   tables and before Blockers.
4. **No regression to existing gate ordering:** the `Commander review` header is
   still the first synthesized line; the EVIDENCE TABLE still precedes the
   consensus section.
5. **No forbidden files touched:** `git diff --name-only origin/main` lists ONLY
   `.claude/agents/worker-review.md` and this spec.

## Risks / rollback

- **Risk:** future reader thinks codex now runs by default. Mitigated: the
  description explicitly says opt-in; step 6 still leads with "OFF by default".
- **Risk:** consensus section confuses the two validator scripts. Mitigated: the
  section is prose/bullets (no `|`-delimited header row matching either
  validator's 4/5-column signature), placed outside both tables.
- **Rollback:** revert the single agent-file edit + delete this spec. No code, no
  state, no script depends on the change; zero blast radius.
