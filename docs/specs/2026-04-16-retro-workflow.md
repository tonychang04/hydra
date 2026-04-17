---
status: implemented
date: 2026-04-16
author: hydra design
---

# Weekly Retro Workflow

## Problem

Hydra's learning loop currently runs at two cadences: per-ticket (citations → counters) and every-10-tickets (compact + promote). Neither inspects trends across a longer window.

Gstack has `/retro` which produces weekly summaries across commits and ships. Hydra needs the same but oriented around **what the machine shipped, where it got stuck, and what the human had to intervene on** — because that's the signal for "what should I improve next?"

Today an operator would have to manually read through `logs/*.json` to see patterns. That's friction, and friction loses to "I'll do it later." We need a self-serve retro command that produces the summary automatically.

## Goals

- `retro` command in commander chat produces a structured weekly summary
- Summary reads from `logs/*.json` + `memory/escalation-faq.md` + `state/memory-citations.json`
- Output sections: shipped (counts + notable PRs), stuck (patterns in failures), escalations (what the human had to answer), citation leaderboard (what memory earned its keep), promotion candidates (entries near threshold), proposed policy/CLAUDE.md edits
- Retro output committed to `memory/retros/YYYY-WW.md` so trends compound over time
- Auto-runs once a week at 9am on a cron-like schedule (if scheduled autopickup is wired)

## Non-goals

- Not a dashboard UI. Plain markdown output in chat + on disk.
- Not an accountability report. This is for improving Hydra, not policing it.
- Not per-repo retros (yet). One global retro is enough until multi-repo activity makes it noisy.

## Proposed approach

A new `commander-retro.md` skill or inline procedure in CLAUDE.md that:

1. Reads every `logs/*.json` with `completed_at` in the past 7 days
2. Reads `state/memory-citations.json` and sorts by citation delta over the same window
3. Reads `memory/escalation-faq.md` git log (if in git) to see what was ADDED (= human interventions)
4. Synthesizes into a fixed markdown template:
   ```
   # Hydra Retro — Week of YYYY-WW

   ## Shipped
   - N PRs opened, M merged (auto-merge: X, human-merge: Y)
   - Notable: [links to PRs that were non-obvious]

   ## Stuck
   - K workers hit commander-stuck; top 3 patterns:
     - <pattern>: <count>, likely cause
   - Proposed mitigation: <memory entry to add, or worker prompt tweak>

   ## Escalations
   - Human answered N novel questions; top themes:
     - <theme>: <count>
   - Proposed FAQ additions already appended to escalation-faq.md

   ## Citation leaderboard
   - Most-cited memory entries this week → Y are now promotion-ready
   - PRs queued for skill-promotion: <list>

   ## Proposed edits
   - [if pattern warrants] Policy or CLAUDE.md change with justification
   ```
5. Writes the output to `memory/retros/YYYY-WW.md`
6. Surfaces a one-paragraph summary in chat with "read full retro: memory/retros/..."

### Alternatives considered

- **A: Inline in CLAUDE.md operating loop.** Simpler but bloats the core prompt. Rejected.
- **B: Dedicated `worker-retro` subagent.** Overkill for what's essentially log aggregation; no worktree isolation needed because retro only READS state and WRITES to memory/. Rejected.
- **C: External script that pipes data to Claude.** Inverts the flow — commander should orchestrate its own introspection, not outsource it. Rejected.
- **D (picked):** Inline procedure in the commander's response to `retro` command, structured template.

## Test plan

1. Manually populate 5+ fake log entries with varied outcomes (shipped, stuck, human-escalated)
2. Run `retro` in commander chat
3. Verify the output markdown matches the template structure
4. Verify `memory/retros/YYYY-WW.md` was written
5. Verify the citation leaderboard correctly identifies promotion-ready entries
6. Self-test: add `retro-golden` case that runs retro on a known log snapshot and diffs against expected output

## Risks / rollback

- **Risk:** Retro could surface false patterns from small sample sizes (N=3 "stuck" cases might just be coincidence). **Mitigation:** add a minimum sample-size gate (e.g. require ≥5 data points before proposing a pattern-based edit). Suggest, don't enact.
- **Risk:** Retro output could grow unboundedly in `memory/retros/` over months. **Mitigation:** memory-lifecycle rules apply — old retros auto-archive.
- **Rollback:** remove the `retro` command from CLAUDE.md commands table. No data migration needed.

## Implementation notes

Implemented in PR on `commander/hydra-1` (closes #1). What shipped vs the spec, and things worth flagging for future workers:

- **Command lives inline in CLAUDE.md, not as a skill.** Picked Alternative D from the spec. The new "Weekly retro (runs on demand)" section sits right after "Memory hygiene" because the two procedures share state (`state/memory-citations.json`, `memory/escalation-faq.md`) and reviewers should see them together. A separate `commander-retro.md` skill would have split the context.
- **Output template is locked verbatim.** The six-section template (`Shipped / Stuck / Escalations / Citation leaderboard / Proposed edits`) is reproduced inside a fenced block in CLAUDE.md — the commander treats that block as authoritative. Future edits to the template should change it in CLAUDE.md and in this spec in the same PR so they don't drift.
- **Sample-size gate codified as ≥5 data points.** The spec lists this as a risk mitigation; made it concrete in CLAUDE.md ("Do NOT propose a pattern-based `## Proposed edits` entry unless the supporting signal has ≥5 data points in the window"). Below that, retro writes "no pattern above minimum sample size this week." `Stuck`/`Escalations` still report counts even when small — the gate applies only to proposed edits.
- **Idempotency on re-run:** if `retro` runs twice in the same ISO week, the second run overwrites the first. Retros are cumulative per week, not per invocation. Documented in the procedure.
- **Scheduled auto-run is gated on scheduled autopickup.** Until that spec (`2026-04-16-scheduled-autopickup.md`) lands, retro is operator-invoked only. CLAUDE.md calls this out explicitly so nobody wonders why nothing fires on Mondays.
- **Self-test case is a STUB, not a populated golden.** Added `retro-golden-stub` to `self-test/golden-cases.example.json` with `worker_type: "commander-inline"` (retro is not a spawned worker — it runs in the commander's own response loop). The stub documents the expected assertion shape (`must_write_path`, `expected_sections`, `sample_size_gate_respected`). Populating fixture logs + running the stub against a real commander session is the operator's follow-up once a week of real `logs/*.json` exists.
- **`memory/retros/` is a new committed subdir** with a `.gitkeep` so it ships empty. `memory/MEMORY.md` picked up a new "Weekly retros" section pointing to it. No change to memory lifecycle rules — the spec calls out that old retros auto-archive via existing lifecycle, which is the right call (no new rule needed).
- **Nothing changed in** `policy.md`, `budget.json`, worker subagents, `.claude/settings.local.json*`, or `state/*.json`. Retro is a READ-only command over state + a WRITE into `memory/retros/`, so it stays within commander's existing permission envelope.
