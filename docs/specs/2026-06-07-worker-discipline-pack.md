---
status: accepted
date: 2026-06-07
ticket: https://github.com/tonychang04/hydra/issues/272
area: worker contract / quality / prompt-engineering
size: S
authors: [worker-implementation]
supersedes: []
extends:
  - .claude/agents/worker-implementation.md
  - docs/specs/2026-06-07-validation-contract.md
  - docs/specs/2026-04-17-slim-worker-prompts.md
---

# Worker discipline pack — import four superpowers disciplines into the worker prompt

## Problem

`.claude/agents/worker-implementation.md` already *applies* four superpowers
disciplines — but only implicitly. The skills are listed in frontmatter
(`superpowers:{brainstorming,writing-plans,test-driven-development,systematic-debugging,verification-before-completion}`),
yet the prose prompt never turns them into **explicit, checkable steps** the
worker can be held to. Four gaps:

1. **No pre-finalization evidence checklist.** The validation-contract section
   says "fill evidence before you finalize," but there is no single
   stop-the-line checklist a worker runs immediately before drafting the PR.
   This is exactly the gate `superpowers:verification-before-completion`
   formalizes ("NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE"), and
   it directly attacks Hydra's #1 documented weakness — workers CLAIMING tests
   ran when they did not (`memory/MEMORY.md` → `feedback_context_and_testing_weakness`).

2. **No ambiguous-AC gate.** The spec-driven section mentions brainstorming
   "if the ticket is genuinely ambiguous," but doesn't define *when* a ticket
   counts as ambiguous or *what* the brainstorming pass must produce before the
   spec is written. Ambiguity caused the 2026-04-18 agent-auth thrash
   (`memory/MEMORY.md` → `feedback_survey_before_propose`).

3. **No large-ticket plan artifact.** For big tickets the worker jumps from
   spec to code with no committed task breakdown, so a mid-implementation stall
   leaves nothing on the draft PR that says *what was left to do*.
   `superpowers:writing-plans` is listed but never triggered.

4. **Bug detection is buried.** The Iron Law for bugs lives in Flow step 2, but
   there's no up-front, mechanical "scan labels/body → emit BUG DETECTED" banner
   that forces the systematic-debugging Phase-1 root-cause pass before any fix.

## Goals

- Surface all four disciplines as **explicit, checkable steps** in the worker
  prompt, each citing its source superpowers skill.
- Keep the additions **tight** — the prompt is read on every spawn; no bloat,
  no restating what the validation-contract / spec-driven / bug-class-flow
  sections already say. Cross-reference instead of duplicating.
- **Additive only.** Delete no existing rule. Follow the existing prompt's
  structure and voice (`memory: follow_existing_patterns`).

## Non-goals

- No change to CLAUDE.md, worker-review.md, scripts, or `.claude/skills/`
  (other workers / specs own those).
- No new tooling — the steps reference the *existing* `validate-contract.sh`
  gate and the *existing* skills; nothing new is built.
- Not a rewrite of the validation-contract, spec-driven, or bug-class-flow
  sections — the new steps are thin checklists that *point at* them.

## Proposed approach

Adapt (not copy verbatim) the four source skills at
`/Users/gary/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/`
into four additions to `worker-implementation.md`:

1. **Pre-finalization evidence checklist** — a new
   "## Pre-finalization gate (verification-before-completion)" section placed
   right before the Flow, as a numbered checklist the worker runs immediately
   before drafting the PR: every AC has a contract row; every PASS carries
   FRESH evidence (a command run in the finalize step, not a remembered run);
   zero UNVERIFIED rows where a command *could* have run; `validate-contract.sh`
   exits 0. Only then finalize. Adapts the skill's "Gate Function".

2. **Ambiguous-AC gate** — an additive bullet in the spec-driven section: a
   concrete ambiguity test (acceptance criteria that could be read two ways,
   missing success definition, or conflicting requirements) → run a short
   `superpowers:brainstorming` pass that RESTATES the intent in one paragraph,
   then write the spec against the restatement. Adapts the brainstorming
   skill's "crystallize intent before implementation" without dragging in its
   full interactive question loop (workers are non-interactive).

3. **Large-ticket plan artifact** — an additive bullet in the spec-driven
   section: if the ticket has **≥5 acceptance criteria** OR is estimated to
   touch **≥10 files**, commit a short `plan.md` (task list + file paths + test
   commands) alongside the skeleton, before the first implementation commit. It
   doubles as a watchdog-recovery artifact (a stall leaves the task list on the
   draft PR). Adapts `superpowers:writing-plans` bite-sized-task structure,
   scoped down to a checklist (not the full TDD-per-task plan doc).

4. **Bug-detection banner** — an additive step at the very top of the Flow
   (Flow step 1): mechanically scan ticket labels + body for
   `bug` / `error` / `regression` / `broken` (and stack traces); on a match,
   emit a literal `BUG DETECTED` line and route into the existing Iron-Law /
   systematic-debugging Phase-1 path (Flow step 2) before any fix. This makes
   the existing bug-class detection *visible and mechanical* rather than buried.

### Alternatives considered

- **Inline everything into CLAUDE.md** — rejected: CLAUDE.md is routing + hard
  rails only (`memory/feedback_claudemd_bloat.md`), and a separate worker owns
  it (coordinate-with constraint).
- **One big new "Disciplines" section** — rejected: it would duplicate the
  validation-contract, spec-driven, and bug-class-flow sections. Threading each
  discipline into its natural existing section keeps the prompt DRY and tight.
- **Copy the skill bodies verbatim** — rejected by the ticket: adapt to the
  worker's non-interactive, prompt-read-every-spawn context.

## Test plan

This ticket edits a Markdown agent prompt + adds a spec; there is no code path
to unit-test. Verification is structural:

- `scripts/validate-state-all.sh` exits 0 (schema + CLAUDE.md size gate
  unaffected; this is the ticket's stated acceptance check).
- The four disciplines are each present as an explicit, greppable, checkable
  step in `worker-implementation.md` (grep asserts each anchor phrase).
- The spec has valid frontmatter (the self-test's spec-frontmatter check).
- No existing rule deleted: `git diff` on `worker-implementation.md` shows only
  additions (no `-` lines that remove a rule).

See `validation-contract.md` (worktree-local) for the row-by-row evidence.

## Risks / rollback

- **Risk:** prompt bloat slows every spawn. *Mitigation:* additions are thin
  checklists that cross-reference existing sections; net add is small.
- **Risk:** a new mandatory step over-taxes trivial tickets. *Mitigation:* each
  step is conditional (ambiguous-AC only when ambiguous; plan only for big
  tickets; bug banner only on a keyword match; the evidence gate already scales
  via the one-row contract for trivial tickets).
- **Rollback:** revert the single commit to `worker-implementation.md`; the
  spec stays as the "why" record.
