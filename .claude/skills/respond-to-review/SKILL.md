---
name: respond-to-review
version: 1.0.0
description: |
  Process review feedback when Hydra's review gate re-spawns you with blockers.
  Use when your spawn prompt contains review findings from `worker-review` /
  `worker-validator`, the ticket carries a re-spawn / "address review feedback"
  hint, or a PR you authored has unresolved review comments to act on. Teaches
  the per-finding protocol: restate the technical requirement, VERIFY it against
  THIS codebase (breaks tests? legacy reason still holds? reviewer has full
  context?), then respond with an implementation plan OR reasoned pushback backed
  by evidence — never blind implementation, never reflexive over-defense, never
  performative agreement. Adapts superpowers `receiving-code-review` to Hydra's
  automated review-gate loop. (Hydra)
---

# Respond to review feedback (verify before implementing)

## Overview

Hydra's review gate (`worker-review` → `worker-validator`) re-spawns
`worker-implementation` with findings when it sees blockers (CLAUDE.md §
"Commander review gate", max 2 cycles). A re-spawned worker fails two ways:
**blind implementation** (treat each finding as an order, implement verbatim,
break a test or strip a load-bearing legacy guard) and **reflexive over-defense**
(argue without first verifying, burning a cycle on friction). This skill teaches
the disciplined middle: for EACH finding, restate → verify-against-codebase →
respond with an impl plan or evidence-backed pushback. It distills superpowers
`receiving-code-review` (the 3-gate response pattern) into Hydra's
review-gate vocabulary. That source skill is the authoritative pattern; this is
its Hydra-adapted, Step-0 context-read form. On conflict, prefer the concrete
verification a command gives you over either skill's prose.

## When to Use

- Your spawn prompt contains review findings from `worker-review` or
  `worker-validator`, or a "re-implement with feedback" / "address review" hint.
- The ticket loops back to you after a draft PR opened (the review gate's
  re-spawn — distinct from a fresh ticket or a `commander-rescued` resume).
- You're acting on unresolved inline review comments on a PR you authored.

Skip when:
- Fresh ticket with no prior review (normal implement flow — no feedback to
  process).
- The branch came back via `scripts/rescue-worker.sh --rescue` with no review
  findings → that's `worker-resume-from-rescue`, not this.
- You are the reviewer (`worker-review`/`worker-validator`) producing findings →
  that's `classify-pr-for-review`, not this.

## Process / How-To

1. **Read ALL findings first; don't react.** No "good catch", no "you're
   absolutely right", no "let me implement that now". If any finding is unclear,
   STOP and emit a `QUESTION:` block before touching code — findings can be
   related, and partial understanding yields wrong fixes.
2. **For each finding, restate the technical requirement** in one line, in your
   own words. If you cannot restate it, you do not understand it — ask.
3. **Verify against THIS codebase before implementing.** Run the check, don't
   assume: does it break an existing test (`grep`/run the suite)? Is the current
   code that way for a legacy/compat reason that still holds? Does the reviewer
   have full context, or did it miss a constraint in the spec/ticket? Is the
   suggested feature actually used (`grep` for the call site — YAGNI)?
4. **Decide and respond per finding:**
   - **Valid** → state the fix factually ("Fixed: <what changed> in <file>"),
     implement it, test it. No gratitude, no preamble.
   - **Wrong/inapplicable** → push back with *technical evidence*: name the test
     it would break, the legacy reason, or the missing context — cite file:line
     or command output. Not defensiveness; verifiable reasoning.
   - **Can't verify** → say so explicitly: "Can't verify <X> without <Y> —
     investigate, or proceed under assumption Z?" Never proceed silently.
5. **Implement valid findings one at a time, in order:** blocking/security →
   simple (typo, import) → complex (logic, refactor). Test each before the next;
   a batch with no per-fix test hides regressions.
6. **Record the dispositions in the PR.** When you finalize, update the PR body
   with a short "Review response" list: each finding → fixed (where) or pushed
   back (why, with evidence). The reviewer re-runs the contract — make the
   handoff legible. For inline GitHub review comments, reply in the comment
   thread (`gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies`), not
   as a top-level PR comment.
7. **If you pushed back and were wrong, correct factually and move on:**
   "Verified — you're correct, <reason my read was off>. Fixing." No apology
   paragraph, no defending the pushback.

## Examples

### Good — verify, then respond (mix of fix + evidence-backed pushback)

Review finding: "The `NO_COLOR` guard in `self-test/run.sh` is dead — just emit
ANSI unconditionally." → **Don't strip it reflexively.** `grep -n 'NO_COLOR'
self-test/run.sh` shows the live guard (`[[ "${NO_COLOR:-}" != "1" ]]`), and
the surrounding `[[ -t 1 ]]` test means color is already suppressed when output
is captured (not a TTY) — so byte-stable non-TTY output depends on this guard
staying. Response: "Pushed back: the `NO_COLOR` guard is load-bearing —
self-test/run.sh:NN gates ANSI on `[[ -t 1 ]] && NO_COLOR != 1`; removing it
would inject escape codes into captured golden output. Keeping it. Second
finding (an unguarded array index) is real — Fixed at <file:line>." Each
disposition cites a line the reviewer can re-check.

### Bad — blind implementation (the failure this skill prevents)

Same finding. Worker writes "You're absolutely right!" and rips the `NO_COLOR`
guard out without grepping. The next `worker-validator` run reruns the contract;
any assertion that captures `self-test/run.sh` output and diffs it now sees ANSI
escape codes and fails. A cycle is burned re-adding the guard — the operator's
"changes land in weird ways without project context" failure mode (Commander
memory, `feedback_context_and_testing_weakness`). One `grep` before
implementing would have caught it.

## Verification

Confirmed offline against the current corpus:
- **Shape:** `grep -nE '^## '` → the six canonical sections in order; `name:`
  matches the directory; `description` ends `(Hydra)`; `wc -l` under the ~150
  ceiling — matches sibling seeds (`worker-resume-from-rescue`,
  `author-repo-skill`).
- **Pressure test:** the "Bad" example is the concrete failure; the Process step
  3 `grep` is the single action that prevents it — the skill's claim is testable
  by walking that scenario.
- **Non-duplication:** `grep -ni 'review feedback\|receiving-code-review'
  .claude/skills/*/SKILL.md memory/escalation-faq.md` → no sibling Hydra skill
  covers processing inbound review findings;
  `classify-pr-for-review` is the *reviewer* side (producing findings), this is
  the *implementer* side (consuming them) — complementary, not redundant.

## Related

- `.claude/skills/README.md` — authoritative skill shape + authoring checklist.
- gstack `superpowers:receiving-code-review` — the source 3-gate response pattern
  this skill adapts (Main-Agent runtime skill; this is the Hydra Step-0 form).
- `classify-pr-for-review` — the reviewer-side counterpart (scoping a diff,
  producing Blockers/Concerns/Nits); this skill consumes that output.
- `worker-resume-from-rescue` — sibling re-spawn flow, but for timeout rescue
  (no review findings), not the review gate. Different trigger, different skill.
- `worker-emit-memory-citations` — emit `MEMORY_CITED:` correctly in your report.
- CLAUDE.md § "Commander review gate" — the loop that re-spawns you with feedback;
  CLAUDE.md § "Applying labels" — REST, not `gh pr edit`, for any label step.
