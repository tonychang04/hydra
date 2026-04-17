---
status: approved
date: 2026-04-17
author: hydra commander
---

# Scheduled Retro — Monday 09:00 Local via Autopickup Tick

## Problem

CLAUDE.md's "Weekly retro" section promises:

> **Scheduled retro (when scheduled autopickup ships):** auto-run every Monday 09:00 local. Until then, `retro` is operator-invoked only.

Scheduled autopickup shipped in ticket #23 (spec `docs/specs/2026-04-16-scheduled-autopickup.md`). The scheduled retro never did. Result: the retro is still operator-invoked, so for any week in which the operator forgets (or is away), no retro is written and the compounding "last-week's trend next to this week's" mental model breaks.

For a run-while-the-operator-sleeps machine, this gap is at odds with the autonomy principle.

## Goals

- On every autopickup tick, check whether a retro is due; if yes, run it **before** the ticket-pickup loop so retros aren't starved by workers contending for `max_concurrent_workers`.
- Store `last_retro_run` (ISO-8601) on `state/autopickup.json` so the check is idempotent across ticks — two ticks in the same Monday window must not double-run.
- Default cadence: Monday ≥ 09:00 **in the host's local timezone** (per Python `datetime.now()` / `date`). Single-operator tool; "local" means whatever the host says it is.
- When the operator already typed `retro` earlier in the same Monday 09:00 window, the scheduled path must be a no-op — the manual run writes `last_retro_run` too, which the scheduled check reads.

## Non-goals

- **Configurable day/hour.** Default Monday 09:00 only. Operator who wants Tuesday 07:00 edits `state/autopickup.json` manually; a proper config flag is a follow-up.
- **Multi-timezone / travel-day DST rigor.** If the operator spans timezones, retros may fire slightly earlier or later on travel days. Acceptable for a weekly cadence.
- **Multi-week rollups** (month-view retro, quarter-view retro). Separate spec if/when demand appears.
- **New cron daemon.** The check rides on the existing `/loop`-driven autopickup tick. No new scheduler.

## Proposed approach

### Where the check lives

Inside the **Scheduled autopickup → Tick procedure** in CLAUDE.md, as **step 1.5** (after preflight, before ticket-pickup):

> **1.5 Retro due check.** Compute `now_local` (host timezone). If `now_local.weekday == Monday AND now_local.time >= 09:00`, and `state/autopickup.json:last_retro_run` is null or is lexicographically less than `<today>T09:00` (ISO-8601 local), run the `retro` procedure, write `last_retro_run = now_local.isoformat()`, and — only if the operator is interactive — surface a single chat line: `Auto-retro for week YYYY-WW written to memory/retros/YYYY-WW.md`. Otherwise skip silently.

This keeps the logic where other tick-local state decisions already live and avoids introducing a new script.

### Idempotency

ISO-8601 local strings compare correctly lexicographically when the format is consistent. Concretely: `last_retro_run >= <today>T09:00` → already ran in this Monday's window → skip. Null → first run, fire.

We deliberately DO NOT use UTC for this comparison — "09:00 local" is exactly the semantic the operator cares about, and UTC conversion adds DST complexity with no user-facing benefit.

### Manual + scheduled interplay

When the operator types `retro` directly (manual path in CLAUDE.md "Weekly retro"), the procedure writes `state/autopickup.json:last_retro_run` at completion. The scheduled tick's idempotency check therefore no-ops for the rest of that Monday window. No race: `/loop` yields to foreground chat, and two sequential retros for the same week overwrite the same file (`memory/retros/YYYY-WW.md`) — this is already documented as acceptable in CLAUDE.md ("If the file already exists for this week, overwrite").

### Alternatives considered

- **A: Separate `/schedule`-based cron entry for Monday 09:00.** More "proper" cron semantics and survives session crashes. Rejected because Hydra's autopickup intentionally avoids adding cron infrastructure (see `docs/specs/2026-04-16-scheduled-autopickup.md`). One scheduler pattern is enough for Phase 1.
- **B: UTC storage with local conversion on read.** More rigorous on travel days. Rejected for the same reason — single-operator tool, weekly cadence tolerates the edge case, and the implementation is twice the code for ~0 extra correctness.
- **C (picked):** In-tick check at step 1.5, local-time comparison, idempotency via `last_retro_run` on the same state file.

## Test plan

1. **Fixture: never run before.** `last_retro_run = null`, mocked `now = Monday 09:05 local` → retro fires, `last_retro_run` set to the mocked timestamp.
2. **Fixture: already ran today.** `last_retro_run = today T09:00:00` local, mocked `now = Monday 10:00 local` → retro does NOT fire.
3. **Fixture: ran last Monday.** `last_retro_run = 7 days ago T09:00 local`, mocked `now = Monday 09:05 local` → retro fires.
4. **Fixture: Sunday / not yet 09:00.** mocked `now = Sunday 23:59 local` or `now = Monday 08:59 local` → retro does NOT fire.
5. **Self-test case** `scheduled-retro-trigger` (kind: `script`) — drives a bash helper function with an `HYDRA_FAKE_NOW=<ISO8601>` override to assert each of the above. If cleanest path requires an executor that doesn't exist yet, SKIP with a clear `_skip_reason`.
6. **Schema validation** — `scripts/validate-state.sh state/autopickup.json` passes both before and after the new optional `last_retro_run` field (backward-compat: absence == null == never run).

## Risks / rollback

- **Risk:** Clock drift / DST transition week fires retro twice or zero times. **Mitigation:** The `last_retro_run >= <today>T09:00` guard holds on DST forward-shift (retro fires once, correctly); on DST backward-shift an extra fire is theoretically possible but overwrites the same file, so the user-visible outcome is identical. Documented in "Non-goals."
- **Risk:** Operator's timezone changes mid-session (e.g., laptop crosses timezones in suspend). **Mitigation:** documented in "Non-goals"; retros may fire slightly early/late on such days; output is still correct.
- **Risk:** Manual + scheduled race. **Mitigation:** `/loop` yields to foreground; manual `retro` writes `last_retro_run`; scheduled check reads it; no double-run.
- **Rollback:** Remove the step 1.5 paragraph from CLAUDE.md and leave `last_retro_run` as a harmless (optional, additive) field on `state/autopickup.json`. No migration needed.

## Implementation notes

(to fill on PR land)

- CLAUDE.md edit is confined to the "Scheduled autopickup → Tick procedure" section (adds step 1.5). No other section touched.
- `state/schemas/autopickup.schema.json` gets an optional `last_retro_run` property (`type: ["string", "null"]`, format `date-time`). Still `additionalProperties: true` so older states continue to validate.
- `state/autopickup.json.example` gains `"last_retro_run": null` so operators copying the template get the full shape.
- Self-test case `scheduled-retro-trigger` appended to `self-test/golden-cases.example.json`. Current executor can't mock the clock, so the case is SKIP'd with `_skip_reason` — it still documents expected behavior for the next executor pass.
