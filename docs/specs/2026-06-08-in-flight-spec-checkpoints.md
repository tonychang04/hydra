# In-flight spec-compliance checkpoints for multi-task tickets

Ticket: #285 — [P1/quality] Two-stage in-flight review checkpoints for multi-task tickets
Owner of edited file: `.claude/agents/worker-implementation.md` (this PR is the sole owner per the #285 coordinate-with hint).

## Problem

Today a Hydra `worker-implementation` is reviewed **only at end-of-ticket**: it implements every task, opens the draft PR, and *then* `worker-review` (and `worker-validator`) scrutinise the whole diff at once. For a small ticket that is fine. For a **multi-task ticket** — the ≥5-AC / ≥10-file class that #272/#278 already taught the worker to plan out in a `plan.md` checklist — it is a known failure mode: an early task can drift from the spec (wrong name, wrong interface, misread acceptance criterion), and every later task is then built *on top of* that mistake. By the time end-of-ticket review catches it, the fix is a cascading rewrite of several tasks instead of a one-line correction caught at task 1.

superpowers' `subagent-driven-development` skill solves this with a **two-stage review after each task — spec compliance first, then code quality** — so "spec compliance prevents over/under-building" and drift is caught before it compounds. Hydra applies that pattern only at the very end. The `plan.md` artifact from #272 gives us the natural seam to add a cheap intermediate checkpoint: the worker already enumerated its tasks, so it can pause after each one and self-check against the spec before starting the next.

**Why now:** #272 (PR #278) landed the `plan.md` large-ticket artifact and the end-of-ticket `## Pre-finalization gate`. The intermediate checkpoint is the missing middle: per-task drift detection that the plan artifact makes possible and the pre-finalization gate (a single end-of-ticket read-through) does not provide.

## Goals

- Add ONE lightweight in-flight checkpoint rule to `.claude/agents/worker-implementation.md`, **gated on the #272 `plan.md` artifact** (so it only kicks in for the multi-task tickets that have a `plan.md`; sub-threshold tickets are untouched).
- After completing each `plan.md` task, the worker runs a quick **spec-compliance self-review** (does this task match the spec — nothing missing, nothing extra?) before starting the next task. Drift is corrected at the task boundary, not at end-of-ticket.
- Additive only: no existing rule deleted or reworded; follows the file's existing voice/structure (terse, greppable, spec-pointer-per-section), per the `follow_existing_patterns` learning.
- `scripts/validate-state-all.sh` exits 0 after the edit (the CLAUDE.md size guard + state-schema validator that gate every spawn).

## Non-goals

- **No new sub-agent dispatch.** A Hydra worker cannot spawn sub-subagents per task the way the source skill's controller does; the checkpoint is an in-context *self*-review, not a dispatched reviewer. The full independent review still happens once, at the end, via `worker-review` + `worker-validator`.
- **No code-quality stage in-flight.** The source skill's second stage (code quality) stays at end-of-ticket — `worker-review` + `/codex review` already own it. Adding a per-task quality pass would tax every task with ceremony for little gain; spec-compliance drift is the cascading risk, quality nits are not.
- No change to `CLAUDE.md`, `worker-review.md`, `README.md`, or `.claude/skills/` (owned by other in-flight PRs / out of scope per the coordinate-with hint).
- No change to the sub-threshold path: tickets without a `plan.md` skip the checkpoint entirely.

## Proposed approach

Insert a new `### In-flight spec checkpoint (subagent-driven-development)` subsection in `worker-implementation.md`, placed **immediately after the `### Large-ticket plan artifact (writing-plans)` subsection** (the artifact it depends on) and before `## Early-PR discipline`. Co-locating it with the plan-artifact section makes the gate self-evident: the rule lives right under the artifact it keys off.

The rule, in the file's existing terse voice:

- **Gate:** applies ONLY when a `plan.md` exists (i.e. the ≥5-AC / ≥10-file threshold from the section above tripped). No `plan.md` → no checkpoint; the spec + validation contract already carry enough structure for small tickets.
- **Trigger:** after you finish each `plan.md` task (and its incremental commit), before starting the next.
- **The check (adapted spec-compliance stage):** re-read the spec + that task's acceptance criterion and confirm the just-finished task (a) implements exactly what the spec asked — nothing silently dropped, and (b) added nothing the spec did not ask for (no scope creep). If it drifted, correct it NOW, in the next commit, before later tasks build on it.
- **Record:** tick the task's `plan.md` checkbox only after the self-check passes (the checkbox doubles as the checkpoint log — a stall mid-ticket leaves an honest "task N done & spec-checked, N+1 pending" state on the draft PR).
- **Scope discipline:** the checkpoint is a self-review, NOT the full review gate — the final PR still goes through `worker-review` + `worker-validator`. This is the cheap early-drift catch, not a replacement for independent review.

Cross-reference the source pattern (`superpowers:subagent-driven-development` — "two-stage review after each task: spec compliance first … prevents over/under-building") and point at this spec, matching how sibling subsections cite their superpowers source + a spec path.

### Alternatives considered

1. **Full two-stage (spec + quality) self-review per task.** Rejected — doubles the per-task ceremony; quality is already covered end-of-ticket by `worker-review`/`/codex review`, and spec-drift (not quality) is the cascading risk. (Matches the source skill's own framing that spec compliance is the gate that "prevents over/under-building.")
2. **Dispatch a real reviewer subagent per task** (literal port of the source skill). Rejected — a Hydra worker is itself the leaf agent; it has no controller seam to spawn per-task reviewers, and the timeout/stall budget can't absorb 2 extra dispatches per task. The in-context self-review is the faithful adaptation for a single-agent worker.
3. **Apply the checkpoint to every ticket, not just plan.md ones.** Rejected — small tickets have one logical unit of work; an intermediate checkpoint there is just the pre-finalization gate fired early. Gating on `plan.md` targets exactly the multi-task tickets where drift cascades, which is the ticket's intent.
4. **Put the rule in the Flow section instead of beside the plan artifact.** Rejected — Flow is the ordered run-list; the checkpoint is a conditional discipline tied to an artifact, so it belongs with that artifact (mirrors how the validation-contract discipline lives in its own section, referenced from Flow).

## Test plan

This ticket edits an agent-prompt Markdown file; "tests" are structural assertions (the same shape the validation contract uses):

1. **Checkpoint rule present:** `grep -q "In-flight spec checkpoint" .claude/agents/worker-implementation.md` → exit 0.
2. **Gated on the plan artifact:** the new subsection names `plan.md` as its gate (`grep -A30 "In-flight spec checkpoint" … | grep -q "plan.md"`) and sits after the `### Large-ticket plan artifact` heading (line-order check).
3. **Additive — nothing removed:** `git diff origin/main -- .claude/agents/worker-implementation.md` shows only added lines (no deletions of existing rules); confirm with `git diff --numstat` (deletions count is 0).
4. **State validation green:** `bash scripts/validate-state-all.sh` → exit 0 (CLAUDE.md size guard unaffected; this PR does not touch CLAUDE.md, and worker-implementation.md is not size-gated, but the suite must still pass clean).
5. **Spec committed + referenced:** this spec file exists at `docs/specs/2026-06-08-in-flight-spec-checkpoints.md` and the PR body cites it.

## Risks / rollback

- **Risk:** prompt bloat — adding prose to an already-long worker prompt. Mitigated by keeping the subsection to a tight paragraph + bullet list in the file's existing density, and by gating it (most tickets never read it as load-bearing because they have no `plan.md`). worker-implementation.md is not under the CLAUDE.md size guard, so no ceiling is tripped.
- **Risk:** worker over-applies the checkpoint to small tickets and slows them down. Mitigated by the explicit `plan.md`-only gate and the "skip below threshold" line carried from the section above.
- **Risk:** collision with another PR editing the same file. Mitigated by the #285 coordinate-with hint designating this PR the sole owner of `worker-implementation.md`; based off current `origin/main` which already contains #278's edits to that file.
- **Rollback:** revert this single commit. The change is one additive subsection in one Markdown file; reverting restores the prior prompt with zero behavioural state to unwind.
