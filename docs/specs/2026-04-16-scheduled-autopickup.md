---
status: implemented
date: 2026-04-16
author: hydra design
---

# Scheduled Auto-Pickup

## Problem

Hydra today only works when the operator is present — the Commander session has to be running and receiving chat input. The vision (24/7 auto-machine, human is the exception) requires Hydra to **keep clearing tickets while the operator sleeps**.

We need a scheduling layer that periodically checks the queue and spawns workers autonomously, subject to all existing safety rails (budget, PAUSE, tier classification).

Hermes has this as built-in cron + natural-language task scheduling. Gstack's `/schedule` + `/loop` primitives achieve the same from the operator side. Hydra should adopt the pattern.

## Goals

- An operator-triggered command `autopickup every N min` that enters an auto-pickup mode
- In auto-pickup mode: every N minutes, commander checks the queue, spawns workers up to `max_concurrent_workers`, reports activity concisely
- Operator can disengage with `autopickup off`
- All existing safety rails apply verbatim: PAUSE, budget, tier, rate-limit health
- Auto-pickup yields to foreground chat: if the operator types anything, auto-pickup waits for response before resuming the cron tick

## Non-goals

- Not a full cron server. Leverage Claude Code's existing `CronCreate` / `/loop` primitives where available; fall back to in-session sleep otherwise.
- Not multi-scheduled-rule. One cron per commander session is enough until we have evidence more is needed.
- Not cross-commander-instance scheduling. That's a Phase 2 concern (when commander is on a VM).

## Proposed approach

Leverage the existing `/loop` skill which already handles interval-based re-entry into a commander session. The `autopickup every N min` command:

1. Validates N (clamp to [5, 120] minutes; default 30)
2. Records scheduler state in `state/autopickup.json`: `{enabled: true, interval_min: N, last_run: <ts>, last_picked_count: K}`
3. Invokes the `/loop` skill with a prompt template: "check queue + pick up ≤ max_concurrent_workers, then sleep N min, unless state/autopickup.json:enabled is false"

Commander's autopickup tick logic (runs each interval):
1. Preflight: PAUSE absent? budget OK? rate-limit healthy?
2. `gh issue list` (or Linear MCP) — count new ready tickets
3. Spawn up to `(max_concurrent_workers - current_active)` worker-implementation agents
4. Log tick to `state/autopickup.json:last_run`
5. Quiet by default; only chat-report if: a new ticket was picked up, or a worker finished, or something triggered a question/escalation

When the operator types anything in chat, the scheduler pauses until the operator's task completes, then resumes on next tick.

### Alternatives considered

- **A: Full cron via CronCreate.** More robust (survives session crashes) but requires the commander to be a remote agent (Phase 2). Rejected for Phase 1.
- **B: Poll every tick regardless of quiet mode.** Simpler but chatty; operator gets pinged for every "nothing happened." Rejected.
- **C (picked):** `/loop`-based inline scheduling, state file coordinates, quiet-by-default reports.

## Test plan

1. Manually run `autopickup every 5 min` with one commander-ready issue in a test repo
2. Verify commander spawns worker, completes, reports, then goes quiet
3. Add a second ready issue mid-cycle; verify pickup on next tick
4. Set PAUSE; verify autopickup respects it without disabling
5. Type something in chat; verify auto-pickup yields
6. `autopickup off` + verify state/autopickup.json updated and no further ticks
7. Golden self-test case: simulated log of 3 autopickup ticks with expected spawn counts

## Risks / rollback

- **Risk:** Unbounded chat narration from an over-chatty scheduler. **Mitigation:** quiet-by-default; only report state changes.
- **Risk:** Scheduled spawn during rate-limit window exhausts quota silently. **Mitigation:** preflight gate already handles; auto-pause on rate-limit error. Add a hard stop: if 2 consecutive ticks hit rate-limit, disable autopickup and notify.
- **Risk:** The operator comes back to 50 PRs they didn't approve. **Mitigation:** T2+ never auto-merge regardless of autopickup. Only T1 eligible. And the operator can cap daily throughput via `budget.json:daily_ticket_cap`.
- **Rollback:** set `state/autopickup.json:enabled=false`. All in-flight workers continue; no new ticks. Remove the command from CLAUDE.md if we decide it's a bad fit.

## Implementation notes

Landed in PR closing #2. Scope is intentionally prompt-only — no new shell scripts, no daemon, no CronCreate. Files touched:

- `CLAUDE.md` — added `autopickup every N min` / `autopickup off` rows to the commands table (placed next to `pause`/`resume` since both are spawn-control), plus a new "Scheduled autopickup (runs silently)" section just before "Memory hygiene" that documents the tick procedure, state schema, yield-to-foreground behavior, and the 2-strike rate-limit auto-disable rule.
- `state/autopickup.json.example` — committed template matching the spec schema (`enabled`, `interval_min`, `last_run`, `last_picked_count`, `consecutive_rate_limit_hits`). Runtime `state/autopickup.json` is gitignored alongside the other runtime state files.
- `.gitignore` — added `state/autopickup.json`.
- `budget.json` — extended `notes` to record that autopickup rides on the existing preflight gate and auto-disables after 2 consecutive rate-limit ticks, so operators reading `budget.json` in isolation find the cross-reference.
- `self-test/golden-cases.example.json` — added a `worker-commander` fixture-style case that simulates three ticks (ready queue, rate-limit, then PAUSE) and asserts the commander-side spawn counts + yield behavior. It's a template case operators can copy into `golden-cases.json`.

Design points worth remembering:
- Quiet-by-default is enforced by the tick procedure in CLAUDE.md ("only chat-surface on state changes"). The loop skill itself is already silent when the subagent produces no output, so there's nothing else to wire up.
- Yield-to-foreground is inherent to `/loop` semantics — ticks run in the same session, so a live operator turn naturally blocks the next tick. We documented the expectation rather than adding enforcement code.
- The 2-strike rate-limit counter is the only new piece of runtime state that didn't already exist. It lives on `state/autopickup.json` itself (not `state/quota-health.json`) so that disabling autopickup doesn't mutate the shared quota-health signal used by regular `pick up N`.
- We did NOT touch `.claude/settings.local.json*`, `policy.md`, or any worker subagent. Autopickup is purely a commander-side scheduling wrapper over existing primitives.
- Known soft-conflict: PR #3 on `main` also edits `CLAUDE.md` (adds a `retro` command row). Conflict resolution is a separate concern; this PR simply appends to the commands table and inserts a new section, so the textual overlap is small.
