---
status: accepted
date: 2026-06-06
---

# Autopickup tick orchestrator — scheduled-checks + memory-hygiene steps

**Ticket:** #239 ([P1/keystone] Runnable autopickup tick orchestrator — wire the
`/loop` steps into real code)

**Status:** implemented

## Problem

CLAUDE.md describes a per-tick `/loop` procedure (preflight → Monday retro →
daily digest → rescue-probe → pick → spawn) and the "Scheduled autopickup"
section explicitly claims the tick runs "Monday-retro / daily-digest /
once-a-day skill-promotion checks". Ticket #228 shipped
`scripts/autopickup-tick.sh` covering preflight + pr-shepherd reconcile +
completion-rescue scan + policy-aware merge surfacing — but the **scheduled
checks the CLAUDE.md prose promises were never implemented in the script**.

Evidence (2026-06-06 self-survey, confirmed against the merged tree):

- `scripts/retro-file-proposed-edits.sh` — fully implemented, **never invoked**
  by any runnable procedure. The tick is the natural caller and didn't call it.
- Monday ≥09:00 local retro trigger — documented (CLAUDE.md, `docs/specs/
  2026-04-17-scheduled-retro.md`) but **zero runnable detection**.
- Memory-hygiene "every 10 tickets" counter — documented (CLAUDE.md "Memory
  hygiene") but **no state field and no detection** existed.
- `scripts/promote-citations.sh --check-due` — a once/day gate built *for* the
  tick (#145) but the tick never called it.

Net: the tick was a partial orchestrator. The autonomy-critical scheduled work
still depended on Commander remembering to run scripts by hand every interval —
which, per the dogfood retro, is exactly the manual orchestration that rots.

## Goals

1. Extend `scripts/autopickup-tick.sh` with two new, clearly-delineated step
   functions so the tick is the single runnable entry point for the whole
   deterministic part of `/loop`:
   - **scheduled-checks** — Monday ≥09:00-local retro-due detection (idempotent
     via `state/autopickup.json:last_retro_run`), invoking
     `retro-file-proposed-edits.sh <week>` when the matching retro file exists;
     and once/day skill-promotion due detection via
     `promote-citations.sh --check-due`.
   - **memory-hygiene** — a tickets-since-last-hygiene counter; when it reaches
     the threshold (10), the tick emits a `compact memory` recommendation and a
     `promote-citations.sh` invocation hint.
2. Surface both as additive keys in the `--json` tick report (`scheduled`,
   `hygiene`) so Commander acts on them.
3. Keep actuation OUT of the script: the tick **reports** that a retro is due
   and files the proposed-edits issues from an *already-written* retro file, but
   it never writes the retro itself, never spawns workers, never merges, never
   calls the LLM. Writing the retro markdown and stamping `last_retro_run` stays
   Commander's job (consistent with the `--check-due` contract for promotion).
4. New state needs a schema: add `tickets_at_last_hygiene` to
   `state/schemas/autopickup.schema.json`. (`last_retro_run` and
   `last_promotion_run` already exist.)
5. `scripts/validate-state-all.sh` still passes; CLAUDE.md size does not grow
   (one routing pointer offset by trimming a verbose section to its spec).

## Non-goals

- Re-implementing any chained script (`validate-state-all`, `pr-shepherd`,
  `rescue-worker`, `merge-policy-lookup`, `retro-file-proposed-edits`,
  `promote-citations`). The tick orchestrates; it does not duplicate logic.
- Writing the weekly retro markdown (that is Commander's `retro` procedure /
  `docs/specs/2026-04-16-retro-workflow.md`).
- Spawning workers, running the review gate, or merging — all stay in
  Commander's hands.
- Worker-auditor scheduling (#240) and harness robustness (#242) — these are
  follow-up tickets that slot in as additional step functions; this spec leaves
  the step boundaries clean for them.

## Proposed approach

### Where the new logic lives

`autopickup-tick.sh` already organizes the tick as numbered sections (1
preflight … 6 output). The new work adds two sections **before output**, each a
self-contained block that:

- reads only `state/autopickup.json` (+ `budget-used.json` for the hygiene
  ticket count) and the existing chained scripts,
- produces one compact JSON object (`scheduled_json`, `hygiene_json`),
- emits nothing irreversible.

This mirrors the existing section structure exactly, so #240/#242 add their own
numbered block + JSON object + report stanza the same way.

### Step: scheduled-checks

**Retro-due detection (Monday ≥09:00 local, idempotent):**

- Compute "now" as local weekday + hour. Test seam: `--weekday <1-7>`
  (1=Mon..7=Sun, ISO) and `--hour <0-23>` override the wall clock.
- `retro_due = (weekday == 1 && hour >= 9 && last_retro_run is not in the
  current ISO week)`. The current ISO week tag is `YYYY-WW` (date `+%G-%V`);
  `--week <tag>` overrides for tests.
- When `retro_due` is true AND the retro file `memory/retros/<week>.md` already
  exists, the tick invokes `retro-file-proposed-edits.sh <week>` (best-effort;
  a failure is reported, never fatal) and records its summary line counts.
  When `retro_due` is true but the retro file does NOT yet exist, the tick
  emits `retro_marker = "retro-due-write-first"` — Commander must write the
  retro before the proposed-edits can be filed. This keeps retro *authoring*
  (LLM work) in Commander while the *filing* (deterministic) is automated.
- The tick never stamps `last_retro_run`; Commander stamps it when it writes
  the retro (same split as `--check-due` / `last_promotion_run`).

**Skill-promotion-due detection (once/day):** delegate entirely to
`promote-citations.sh --check-due` (exit 0 = due, exit 10 = already ran today).
The tick reports `promotion_due` boolean + a `promote-citations.sh` hint when
due. It does not run promotion or stamp `last_promotion_run` (Commander does,
once it actually promotes — preserving the existing #145 contract).

### Step: memory-hygiene counter

- The lifetime ticket count lives in `state/budget-used.json`
  (`tickets_completed_today`) — but that resets daily, so it is the wrong
  cumulative source. Instead the tick tracks a **monotonic baseline** in
  `state/autopickup.json:tickets_at_last_hygiene` against a cumulative ticket
  total. The cumulative total is supplied by `--tickets-total <n>` (Commander
  passes its running count; default falls back to
  `budget-used.json:tickets_completed_today` for a best-effort signal when the
  flag is absent).
- `hygiene_due = (tickets_total - tickets_at_last_hygiene) >= 10`. Threshold is
  `--hygiene-threshold <n>` (default 10) for tests.
- When due, the tick emits `hygiene_marker = "compact-memory"` and a
  `promote-citations.sh` hint. It does NOT reset the baseline — resetting is
  Commander's job after it runs the compaction (same report-don't-mutate
  discipline as everything else in this script).

### JSON report additions

Two additive top-level keys (existing keys unchanged — additive only, per the
script's stability contract):

```json
{
  "scheduled": {
    "weekday": 1, "hour": 9, "week": "2026-23",
    "retro_due": true, "retro_marker": "retro-filed",
    "retro_file_present": true, "retro_file_result": "FILED: 2 ...",
    "promotion_due": false
  },
  "hygiene": {
    "tickets_total": 12, "tickets_at_last_hygiene": 0,
    "tickets_since": 12, "threshold": 10,
    "hygiene_due": true, "hygiene_marker": "compact-memory"
  }
}
```

### State + schema

`state/schemas/autopickup.schema.json` gains:

```json
"tickets_at_last_hygiene": {
  "type": "integer", "minimum": 0,
  "description": "Cumulative ticket count at the last memory-hygiene compaction.
    The autopickup tick computes tickets_since = tickets_total - this; when it
    reaches 10 the tick emits a compact-memory marker. Commander resets this to
    the current total after running compaction. Null/missing = 0 (never run)."
}
```

The example state file gains the field. The schema's `additionalProperties` is
already `true`, so pre-existing state files without the field still validate;
the field is optional (not added to `required`) for backward compat.

## Test plan

New fixture under `self-test/fixtures/autopickup-tick-scheduled/` with a
`run-smoke.sh` driven fully offline. It asserts:

1. **Monday retro-due detection** — `--weekday 1 --hour 9` with a stale
   `last_retro_run` ⇒ `scheduled.retro_due == true`; with a retro file present
   the tick invokes `retro-file-proposed-edits.sh` (stubbed via the script's
   `--retro-mock`/env) and reports a filed result; on Tuesday
   (`--weekday 2`) ⇒ `retro_due == false`.
2. **Idempotency** — `last_retro_run` already in the current week ⇒
   `retro_due == false` even on Monday 09:00.
3. **Hygiene trip at 10** — `--tickets-total 10 --hygiene-threshold 10` with
   baseline 0 ⇒ `hygiene.hygiene_due == true`,
   `hygiene_marker == "compact-memory"`; `--tickets-total 9` ⇒ false.
4. **Rescue-probe invoked for a stale fixture worker** — reuse the
   `--rescue-mock` seam: an active worker whose mock verdict is `rescue-commits`
   ⇒ appears in `.rescue[]` with `action == "needs-rescue"`. Proves the tick
   actually drives the rescue probe per active worker.
5. **Promotion-due** — `promote-citations.sh --check-due` integration:
   `last_promotion_run` = today ⇒ `promotion_due == false`; null ⇒ true.

The existing `self-test/fixtures/autopickup-tick/run-smoke.sh` continues to pass
unchanged (the additions are additive JSON keys + new flags with safe
defaults).

Run: `bash self-test/fixtures/autopickup-tick/run-smoke.sh` and
`bash self-test/fixtures/autopickup-tick-scheduled/run-smoke.sh`;
`bash scripts/validate-state-all.sh`; `bash scripts/check-claude-md-size.sh`.

## Risks / rollback

- **Risk:** an offline test relying on the real wall clock would be flaky. →
  Mitigated by the `--weekday`/`--hour`/`--week`/`--today`/`--tickets-total`/
  `--hygiene-threshold`/`--retro-mock` seams so the smoke test is deterministic.
- **Risk:** the tick accidentally mutating state (stamping run timestamps) would
  break the Commander-owns-actuation contract and could double-file issues. →
  Mitigated by the report-don't-mutate rule: the only side effect is the
  best-effort `retro-file-proposed-edits.sh` call, which is itself idempotent
  (skips duplicate titles).
- **Rollback:** the additions are additive (new sections, new flags, new JSON
  keys, one optional schema field). Reverting the commit restores the #228
  behavior with no migration.
