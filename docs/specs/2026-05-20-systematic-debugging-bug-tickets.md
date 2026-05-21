---
status: proposed
date: 2026-05-20
author: hydra worker
ticket: 177
tier: T1
---

# Wire superpowers:systematic-debugging into worker-implementation for bug-class tickets

**Ticket:** [#177 — Wire superpowers:systematic-debugging into worker-implementation for bug-class tickets](https://github.com/tonychang04/hydra/issues/177)

## Problem

`worker-implementation`'s "Iron Law for bugs" (establish root cause **before** proposing a fix) is **prose-only** in `.claude/agents/worker-implementation.md`. Today it reads:

> **Iron Law for bugs** (borrowed from gstack/investigate): if the ticket is a bug fix, you MUST establish root cause BEFORE proposing a fix. Use `/investigate` or inline reproduction. … "Symptom-patched this" is never an acceptable PR description.

There's intent but no formal procedure wired in — the only pointer is `/investigate` (a gstack skill that is **not** in this agent's `skills:` frontmatter, so the worker can't actually invoke it as a tool) or "inline reproduction" (undefined). The practical result is that a worker under time pressure can still symptom-patch and write a plausible-sounding PR description, because nothing in its loaded tool set forces the four-phase discipline.

The `superpowers:systematic-debugging` skill formalizes exactly the intent the prose gestures at: a four-phase investigation (Phase 1 root cause → Phase 2 pattern analysis → Phase 3 single-hypothesis testing → Phase 4 fix the root cause, not the symptom) under the same Iron Law — "NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST." It is already installed in the superpowers plugin alongside the skills this agent already loads (`brainstorming`, `test-driven-development`, etc.).

This is a P1/safety ticket: symptom-patches are the upstream cause of `worker-review` `SECURITY:`/quality blockers and of the rework cycles the Commander review gate exists to catch. Wiring the discipline in at the worker level reduces blockers downstream.

## Goals / non-goals

**Goals:**

- Add `superpowers:systematic-debugging` to `worker-implementation`'s `skills:` frontmatter so the worker can invoke it as a tool. (This is the correct loader for `superpowers:*` skills — see `memory/learnings-hydra.md` #150: the `skills:` YAML list is for plugin-provided skills loaded explicitly as tools; `.claude/skills/*` is a different, implicit loader.)
- Extend the existing "Iron Law for bugs" item **in place** (match its voice and structure; do not restructure the doc) so it: (a) defines bug-class detection — label `type:bug`/`bug`, or body keywords `error` / `broken` / `regression`, or a stack trace; (b) for those tickets, requires invoking `superpowers:systematic-debugging` before any fix; (c) keeps the existing `QUESTION:`-on-no-root-cause behavior.
- Keep non-bug tickets unchanged — feature/typo/docs work is **not** taxed with debugging ceremony.
- Add a short worked example (bug → investigate → fix) to the agent doc so the flow is concrete.
- Regression test: a standalone self-test fixture that asserts the wiring is present (skill in frontmatter, bug-class detection language present, non-bug-exemption language present, example present, spec exists) and would have failed before this change.

**Non-goals:**

- Changing the worker contract on anything else (output format, skill chain, memory citations, PR body format all stay as-is).
- Forcing systematic-debugging on **non-bug** tickets. The skill itself is broad ("any technical issue"), but the *routing* this ticket adds is bug-class-only by design — taxing feature work with four-phase ceremony was explicitly ruled out in the ticket.
- Touching `CLAUDE.md` (another worker owns it this cycle) or `.claude/skills/` (the repo-local skill loader — out of scope; coordinate-with hint pinned this).
- Wiring the fixture into `self-test/golden-cases.example.json`. That file is operator-pinned as off-limits (same constraint the slim-worker-prompts fixture honored). The new fixture is runnable standalone.
- Editing any other `worker-*.md`. Only `worker-implementation` does code changes / bug fixes; the other workers don't fix bugs (`worker-review` reads diffs, `worker-test-discovery` writes test docs, etc.), so the routing is irrelevant to them.

## Proposed approach

### 1. Frontmatter

Add one line to the existing `skills:` block:

```yaml
skills:
  - superpowers:brainstorming
  - superpowers:writing-plans
  - superpowers:test-driven-development
  - superpowers:systematic-debugging   # <-- new, for bug-class tickets
  - superpowers:executing-plans
  - superpowers:requesting-code-review
  - superpowers:verification-before-completion
```

### 2. Extend the "Iron Law for bugs" item

The current `## Flow` step 2 is a single paragraph. Rewrite it (preserving its voice and the "Symptom-patched this" line) to:

- Define **bug-class detection**: a ticket is bug-class if it carries the label `type:bug` or `bug`, OR its body contains the keywords `error` / `broken` / `regression` (case-insensitive), OR it includes a stack trace.
- For bug-class tickets: invoke `superpowers:systematic-debugging` and complete its Phase 1 (root cause) before writing any fix. The skill's Iron Law and four phases ARE the formalization of the prose Iron Law.
- Keep the escape hatch unchanged: if you can't explain WHY the bug exists after Phase 1, return a `QUESTION:` block with your best hypothesis + the evidence gap rather than shipping a guess.
- Add the explicit non-bug exemption sentence: feature/refactor/docs/typo tickets skip systematic-debugging — don't tax them with debugging ceremony.

### 3. Worked example

Add a short fenced example right after the Flow list (or a `### Bug-class flow` subsection) showing the concrete shape:

```
Ticket #312 (label type:bug): "deploy CLI throws TypeError on empty config"
→ bug-class detected (label + "throws" stack-trace shape)
→ invoke superpowers:systematic-debugging
  Phase 1: reproduce → read stack trace → trace bad value to its origin
  Phase 2: find the working config path, diff against the failing one
  Phase 3: single hypothesis ("origin reads config before defaults applied")
  Phase 4: failing test first (TDD), then fix at the origin, not the throw site
→ PR description names the ROOT CAUSE, not the symptom
```

### 4. Regression test

New standalone fixture `self-test/fixtures/systematic-debugging-routing/run.sh`, modeled exactly on `self-test/fixtures/slim-worker-prompts/run.sh` (same `set -euo pipefail`, `fail()`/`pass()` helpers, exit 0/1 contract). Assertions:

1. `worker-implementation.md` frontmatter lists `superpowers:systematic-debugging`.
2. The agent doc contains bug-class detection language (references the skill + the trigger keywords/labels).
3. The agent doc contains the non-bug exemption language (so feature work isn't taxed).
4. The agent doc contains a worked example referencing the skill's phases.
5. The spec file exists at the expected path.

This fixture would FAIL on the pre-change tree (no `systematic-debugging` in frontmatter, no detection language) — satisfying the "a golden case that would have failed before and now passes" guidance in `docs/specs/TEMPLATE.md`.

### Alternatives considered

- **Alternative A — route ALL tickets through systematic-debugging.** The skill's own scope is "any technical issue." Rejected: the ticket explicitly rules out taxing feature work, and four-phase ceremony on a one-line copy change is pure overhead. Bug-class routing keeps the cost where the benefit is.
- **Alternative B — add it to `.claude/skills/` as a repo-local skill instead of frontmatter.** Rejected per `memory/learnings-hydra.md` #150: `.claude/skills/*` is the implicit Step-0 context loader, NOT the plugin-tool loader. A `superpowers:*` skill belongs in the `skills:` frontmatter so the runtime loads it as an invocable tool; putting it in `.claude/skills/` would fail lookup and be silently skipped.
- **Alternative C — replace the prose Iron Law entirely with "invoke the skill."** Rejected: the Memory Brief instruction was to EXTEND in place and match voice, not restructure. The prose Iron Law carries the "Symptom-patched this is never acceptable" framing that's load-bearing; we keep it and point it at the skill.

## Test plan

1. `bash self-test/fixtures/systematic-debugging-routing/run.sh` on the changed tree → exit 0 (all assertions pass).
2. `git stash` the agent-doc change and re-run the fixture → exit 1 (proves the test actually tests the wiring — red/green).
3. `bash .github/workflows/scripts/syntax-check.sh` (or the documented local dry-run) → validates spec frontmatter + `bash -n` on the new fixture script.
4. Manual read of the edited `## Flow` step 2 — confirm bug-class detection, the skill invocation requirement, the `QUESTION:` escape hatch, and the non-bug exemption are all present and in the agent's original voice.
5. Confirm spec-presence-check passes: this PR touches `.claude/agents/*.md` AND includes `docs/specs/2026-05-20-*.md`, satisfying the CI gate.

## Risks / rollback

1. **False-positive bug-class detection** — a feature ticket whose body happens to contain the word "error" (e.g. "add error toasts to the form") gets routed through systematic-debugging unnecessarily. Mitigation: the cost is a few extra Phase-1 minutes, not a wrong outcome; the worker can note "no defect to root-cause; proceeding as feature work" and move on. The keyword set is deliberately small to limit this. If it proves noisy in practice, a follow-up can tighten detection (e.g. require label OR stack-trace, demote bare keywords to a soft signal).
2. **Skill not installed in some runtime** — if a future runtime lacks the superpowers plugin, the frontmatter entry would fail to load. Mitigation: the prose still carries the Iron Law, so the worker degrades to "establish root cause via inline reproduction" — the same fallback that exists today.
3. **Rollback** — `git revert` the implementation commit. The frontmatter line and the Flow-step rewrite are self-contained; reverting restores the prose-only Iron Law. The spec and fixture are additive and harmless on rollback (the fixture would then fail, signaling the wiring is gone — which is correct).
4. **Coordinate with in-flight CLAUDE.md / .claude/skills work** — this PR touches neither, per the coordinate-with hint. No overlap.

## Implementation notes

(Fill in after the PR lands.)
</content>
</invoke>
