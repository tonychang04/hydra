---
status: approved
date: 2026-06-08
author: hydra worker (commander/266)
ticket: 266
supersedes-scheduler-of: 144
---

# Wire the daily digest into the autopickup tick (`digest_due` step)

## Problem

The daily status digest's **scheduler** is unwired. Spec
`docs/specs/2026-04-17-daily-digest.md` (ticket #144, status `approved`)
promises that "Commander emits a daily rollup at a configured time (default
`09:00` local), gated by a `last_digest_run` field … riding the existing
`/loop`-driven autopickup tick — same as scheduled retro." The composer
`scripts/build-daily-digest.sh` exists and is wired into the connector wizard,
but the **tick orchestrator** rewritten in `scripts/autopickup-tick.sh` (#239 →
#242) has retro / promotion / hygiene / audit / gc / interval steps and **no
digest step**. It never emits a `digest_due` marker nor reports that the digest
is due, so the digest can only fire via the connector wizard or a manual call —
its core "daily, automatic" promise is unimplemented in any runner.

Concretely:

- `grep -nE 'digest|last_digest_run' scripts/autopickup-tick.sh` → no matches.
- `state/schemas/autopickup.schema.json` has `last_retro_run`,
  `last_promotion_run`, `last_audit_run`, `tickets_at_last_hygiene` — but **no
  `last_digest_run`**, so even if Commander wanted to stamp it, the field would
  fail schema validation.
- `build-daily-digest.sh` is invoked only by `scripts/hydra-connect.sh` (the
  wizard) and self-test fixtures — no tick/loop caller.

This is a schedule-claim-without-scheduler gap, and it stalls the P1
(observability) pillar the digest spec exists to advance.

## Goals

- Add a **report-only** `digest_due` step to `scripts/autopickup-tick.sh`,
  mirroring the section-4d self-audit step (`audit_due`) exactly. The tick
  **reports** that the digest is due and emits a `digest-due` marker; it does
  **not** run `scripts/build-daily-digest.sh`, route a channel, or stamp
  `last_digest_run`. Actuation stays Commander's job — the same
  report-don't-mutate split as every other `*_due` step (retro, promotion,
  audit).
- Gate: `digest_due = enabled AND (date(last_digest_run) != today) AND (now_hm
  >= time)`, reading all three (`enabled` / `last_digest_run` / `time`) from the
  **canonical `state/digests.json`** (written by `./hydra connect digest`). The
  `enabled` gate keeps a fresh, un-subscribed clone inert; the daily date-gate
  mirrors `audit_due`; the time-of-day gate (default `09:00` local) matches the
  digest spec's "configured time" promise and the Monday-retro `>= 09:00`
  precedent.
- Read the scheduler state from `state/digests.json` — its CANONICAL home, which
  the pre-existing `state/schemas/digests.schema.json` already declares
  (`enabled` / `channel` / `time` / `destination` / `last_digest_run`) and whose
  description already says "Scheduled by the Scheduled autopickup tick". No new
  fields are added to `state/autopickup.json`; the tick reads `digests.json`
  directly (one canonical state file, no duplicated stamp). See "Reconciliation
  with #144" below.
- Expose `digest_due` in the tick's `--json` (`digest` object + `actions`
  roll-up) and human report (a "Digest" stanza + an actions-footer hint when
  due).

## Non-goals

- **Not** running the composer or sending anything. The tick stays report-only;
  Commander runs `scripts/build-daily-digest.sh`, routes per the configured
  channel, and stamps `last_digest_run` — exactly as it actuates `audit_due`.
- **Not** the channel-routing / composer work — that already shipped under #144.
  This ticket is the missing *scheduler leg* only.
- **Not** inventing a new idempotency-state home. The scheduler state
  (`enabled` / `time` / `last_digest_run`) lives on the **canonical
  `state/digests.json`** that `./hydra connect digest` already writes and
  `digests.schema.json` already declares. The tick reads that file directly
  rather than mirroring fields onto `state/autopickup.json` — one canonical
  state file, no duplicated stamp to keep in sync. See "Reconciliation with
  #144" below.
- **Not** a CLAUDE.md edit. A CLAUDE.md PR is in flight; the one-line routing
  pointer this step needs (the digest tick step, paralleling the audit step
  pointer) is noted in this spec and the PR body for that PR to fold in.

## Proposed approach

### New tick block — section 4f (`scripts/autopickup-tick.sh`)

Copy the shape of section 4d (`4d. SCHEDULED SELF-AUDIT`):

```
# Resolve "today" (date gate) and "now_hm" (time-of-day gate).
digest_today  = today_override   || date +%F
now_hm        = (hour_override || date +%H) : (minute_override || date +%M)   # "HH:MM"

# Read the scheduler state from the CANONICAL state/digests.json.
enabled         = digests.json:.enabled // false
digest_time     = digests.json:.time    // "09:00"   # fall back if absent/malformed
last_digest_run = digests.json:.last_digest_run // ""
last_digest_date = ${last_digest_run%%T*}

digest_due = true
if   enabled != true                                   -> due=false, reason="not enabled (run ./hydra connect digest)"
elif last_digest_date == digest_today                  -> due=false, reason="already ran today"
elif now_hm < digest_time                              -> due=false, reason="before configured time HH:MM"
else                                                    -> due=true,  marker="digest-due"
```

The ENABLED gate is the one deliberate addition over the `audit_due` shape: an
un-subscribed digest (no `digests.json`, or `enabled=false`) must never report
due, so a fresh clone stays inert. Emit `digest_json = {today, enabled,
last_digest_run, digest_time, now_hm, digest_due, digest_marker, digest_reason,
run_hint}` where `run_hint` tells Commander: "run scripts/build-daily-digest.sh,
route per the configured channel (state/digests.json), then stamp
last_digest_run on state/digests.json". Wire `digest_due` into `actions_json`
(`digest_due: ($digest.digest_due)`), the `--json` envelope (new top-level
`digest` key), and the human report (a "Digest" stanza + a footer hint when
due). String comparison of zero-padded `HH:MM` is lexicographically correct for
the time gate (`"08:59" < "09:00" < "13:00"`), the same trick the retro step
uses for ISO week tags.

### Test seams (offline, deterministic)

Reuse the existing `--today` and `--hour` seams; add `--minute <0-59>` for the
time-of-day gate so the smoke test can place "now" before/after `digest_time`
without depending on the wall clock. All three default to the live clock so a
bare invocation Just Works.

### Schema (`state/schemas/digests.schema.json` — already present)

No schema *additions* are needed: the canonical `state/schemas/digests.schema.json`
already declares the three fields the tick reads — `enabled` (boolean),
`time` (`^([01][0-9]|2[0-3]):[0-5][0-9]$`), and `last_digest_run`
(`["string","null"]`) — all in `required`, with descriptions that already name
the autopickup tick as the scheduler. The tick reads them as-is; the only
schema *change* in this ticket is **removing** the (now-vestigial)
`last_digest_run` / `digest_time` properties that an earlier draft had added to
`state/schemas/autopickup.schema.json` — the tick reads `digests.json`, not
those, so they were dead fields. A NOTE on `autopickup.schema.json`'s
`tickets_at_last_hygiene` points future readers at `digests.json` as the digest
scheduler home.

### Reconciliation with #144

The #144 spec text put `last_digest_run` on `state/digests.json`, and
`digests.schema.json` was created there with `enabled` / `channel` / `time` /
`destination` / `last_digest_run` all required — its description already reads
"Scheduled by the Scheduled autopickup tick (step 1.6)". This ticket honors that
canonical home: the tick reads `enabled` / `time` / `last_digest_run` straight
from `state/digests.json`. An earlier draft of this ticket mirrored the stamp
onto `state/autopickup.json` (to match `last_retro_run` / `last_audit_run`); that
was reverted because it duplicated state across two files (the wizard writes
`digests.json`, the tick would read a different `autopickup.json` copy) and
contradicted the schema #144 already shipped. One canonical file, no sync risk.

### Alternatives considered

- **A (picked): Tick reads `state/digests.json` directly for
  `enabled`/`time`/`last_digest_run`.** Adds one file read to the tick but uses
  the canonical, wizard-written file `digests.schema.json` already defines —
  no duplicated stamp, no risk of the tick reading a stale mirror. The tick's
  ENABLED gate also lets it short-circuit cleanly on an un-wired clone.
- **A′ (rejected): Mirror `last_digest_run` + `digest_time` onto
  `state/autopickup.json`** to match retro/audit. Rejected — it duplicates the
  stamp the wizard writes to `digests.json`, so the tick and the composer could
  drift; and it contradicts the already-shipped `digests.schema.json` that names
  the tick as its scheduler. The marginal "one scheduler file" tidiness isn't
  worth a two-file sync hazard.
- **B: Daily date-gate only, no time-of-day gate (exact `audit_due` copy).**
  Rejected — the digest spec explicitly promises "a configured time (default
  09:00)". The audit step has no time component; the digest does. The added
  `now_hm >= digest_time` gate is the one deliberate divergence from 4d.
- **C (picked):** Report-only `digest_due` step reading the canonical
  `state/digests.json` (enabled + daily date-gate + configurable time-of-day
  gate); composer + stamping stay Commander's job.

## Test plan

New offline smoke fixture `self-test/fixtures/autopickup-tick-digest/run-smoke.sh`
(mirrors `autopickup-tick-audit/run-smoke.sh`) drives the canonical
`state/digests.json` via a `run_with` helper, registered in
`self-test/golden-cases.example.json`. Asserts:

0. **Enabled gate**: `digests.json:.enabled == false` → `digest_due == false`,
   reason `not enabled`, marker empty (a fresh/un-wired clone is inert).
1. **Never run** (`last_digest_run = null`), enabled, now after `time` →
   `digest.digest_due == true`, `digest_marker == "digest-due"`,
   `actions.digest_due == true`.
2. **Once/day idempotency**: `last_digest_run == today` → `digest_due == false`,
   reason `already ran today`, marker empty.
3. **New day**: `last_digest_run` = yesterday → `digest_due == true`.
4. **Before configured time**: never-run but `now_hm` < `time` →
   `digest_due == false`, reason mentions the configured time, marker empty.
   (Plus a boundary case: exactly at `09:00` → due, `>=` inclusive.)
5. **Human stanza** renders a "Digest" section.
6. **Mutation proof**: the guard's own red-green — neutralizing the time-gate
   clause in a `mktemp` copy of the tick flips assertion 4 to (wrongly) due,
   proving the test actually constrains the gate.

The harness's temp state dir includes the fixture's `digests.json`, so the
tick's section-0 `validate-state-all --state-dir` runs it through `digests.schema.json`
(ajv strict) on every case — `state_valid == true` confirms the fixture is
schema-clean. Plus the existing `--help` / unknown-flag (exit 2) / `bash -n`
cases continue to pass.

## Risks / rollback

- **Risk:** tick reports the digest due every tick (over-firing).
  **Mitigation:** the `last_digest_run` daily date-gate — identical to
  `audit_due`'s proven once/day guard.
- **Risk:** a fresh clone with no `state/digests.json` reports the digest due.
  **Mitigation:** the ENABLED gate — a missing file or `enabled != true` yields
  `digest_due == false` (`enabled` defaults to `false` when absent).
- **Risk:** the tick reads a stale `digests.json` mirror that drifts from the
  wizard's copy. **Mitigation:** there is no mirror — the tick reads the same
  canonical `state/digests.json` the wizard writes; no second copy to sync.
- **Risk:** time-gate string comparison breaks on un-padded hours (e.g. `9:00`).
  **Mitigation:** the tick zero-pads `now_hm` from `date +%H:%M` (always two
  digits) and `digests.schema.json`'s pattern forces `time` to `HH:MM`, so the
  lexical compare is sound.
- **Rollback:** the step is report-only and additive. Reverting the tick block
  removes the marker; `digests.json` is read-only to the tick, so nothing else
  changes. Commander simply stops seeing a "digest due" line.

## Implementation notes

Files touched (all owned by this ticket per the coordinate-with hint):

- `scripts/autopickup-tick.sh` — new section 4f (reads `state/digests.json`:
  `enabled`/`time`/`last_digest_run`) + `--minute` seam + JSON/human wiring +
  actions roll-up entry.
- `state/schemas/autopickup.schema.json` — **removes** the vestigial
  `last_digest_run` / `digest_time` properties an earlier draft added (the tick
  reads `digests.json`, not these); adds a NOTE pointing to the canonical home.
  No change to `digests.schema.json` — it already declares the fields the tick
  reads.
- `self-test/fixtures/autopickup-tick-digest/` — smoke fixture (state/ incl.
  `digests.json`, repos/, gh-mock/, run-smoke.sh).
- `self-test/golden-cases.example.json` — register the new smoke case.
- This spec.

**CLAUDE.md follow-up (NOT in this PR):** the "Scheduled autopickup" paragraph
should gain a one-line pointer that the tick now emits a `digest_due` marker
(parallel to the audit/retro pointers). A CLAUDE.md PR is in flight; this is
noted in the PR body for that PR to fold in.
