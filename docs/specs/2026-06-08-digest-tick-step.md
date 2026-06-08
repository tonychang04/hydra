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
- Gate: `digest_due = (date(last_digest_run) != today) AND (now_hm >=
  digest_time)`. The daily date-gate mirrors `audit_due`; the added time-of-day
  gate (default `09:00` local) matches the digest spec's "configured time"
  promise and the Monday-retro `>= 09:00` precedent.
- Add the additive, optional `last_digest_run` and `digest_time` fields to
  `state/schemas/autopickup.schema.json` (`additionalProperties: true` keeps it
  forward-compatible; absence is tolerated).
- Expose `digest_due` in the tick's `--json` (`digest` object + `actions`
  roll-up) and human report (a "Digest" stanza + an actions-footer hint when
  due).

## Non-goals

- **Not** running the composer or sending anything. The tick stays report-only;
  Commander runs `scripts/build-daily-digest.sh`, routes per the configured
  channel, and stamps `last_digest_run` — exactly as it actuates `audit_due`.
- **Not** the channel-routing / composer work — that already shipped under #144.
  This ticket is the missing *scheduler leg* only.
- **Not** moving idempotency state to `state/digests.json`. The original #144
  spec proposed `last_digest_run` on `state/digests.json`; this ticket
  deliberately puts it on `state/autopickup.json` so the digest rides the same
  tick idempotency machinery as retro/promotion/audit (one scheduler pattern,
  one state file the tick already reads). See "Reconciliation with #144" below.
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
digest_time   = autopickup.json:.digest_time // "09:00"

last_digest_run  = autopickup.json:.last_digest_run // ""
last_digest_date = ${last_digest_run%%T*}

digest_due = true
if   last_digest_date == digest_today                  -> due=false, reason="already ran today"
elif now_hm < digest_time                              -> due=false, reason="before configured time HH:MM"
else                                                    -> due=true,  marker="digest-due"
```

Emit `digest_json = {today, last_digest_run, digest_time, now_hm, digest_due,
digest_marker, digest_reason, run_hint}` where `run_hint` tells Commander:
"run scripts/build-daily-digest.sh, route per the configured channel, then
stamp last_digest_run". Wire `digest_due` into `actions_json`
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

### Schema (`state/schemas/autopickup.schema.json`)

Add two optional properties (NOT in `required`):

- `last_digest_run`: `["string","null"]` — ISO-8601 local timestamp (or bare
  date) of the last digest emit, or null/absent if never run. Drives the daily
  date-gate. Commander stamps it after running the composer.
- `digest_time`: `string`, pattern `^([01][0-9]|2[0-3]):[0-5][0-9]$`, default
  documented as `09:00` — the configured local emit time. Absent ⇒ tick uses
  `09:00`.

### Reconciliation with #144

The #144 spec text (lines 34-36, 82-95) put `last_digest_run` on
`state/digests.json`. The tick orchestrator that shipped after #144 (#228/#239)
established `state/autopickup.json` as the single home for all tick scheduler
state (`last_retro_run`, `last_promotion_run`, `last_audit_run`). Putting
`last_digest_run` there too — rather than on a second file the tick would have
to additionally read — keeps **one scheduler pattern, one state file**. This
spec records that decision; the #144 spec's `state/digests.json` remains the
home for the **channel config** (`enabled`, `channel`, `time`, `destination`),
while the **idempotency stamp** lives on `autopickup.json`. The
`autopickup.json:digest_time` added here is the tick-side mirror of
`digests.json:time` — the tick reads `digest_time` (always present-or-defaulted
on the file it already loads) rather than cross-reading `digests.json`, keeping
the tick's file dependencies unchanged.

### Alternatives considered

- **A: Tick reads `state/digests.json` directly for `enabled`/`time`.**
  Rejected — adds a new file dependency to the tick and couples it to the #144
  channel-config schema. The tick already reads `autopickup.json`; mirroring
  `digest_time` there is cheaper and matches how retro/audit work. Commander
  still consults `digests.json:enabled` at actuation time before running the
  composer (the tick reporting "due" is necessary, not sufficient — same as the
  retro "due-write-first" marker that Commander still gates on).
- **B: Daily date-gate only, no time-of-day gate (exact `audit_due` copy).**
  Rejected — the digest spec explicitly promises "a configured time (default
  09:00)". The audit step has no time component; the digest does. The added
  `now_hm >= digest_time` gate is the one deliberate divergence from 4d.
- **C (picked):** Report-only `digest_due` step on `autopickup.json`, daily
  date-gate + configurable time-of-day gate, schema fields additive, composer
  + stamping stay Commander's job.

## Test plan

New offline smoke fixture `self-test/fixtures/autopickup-tick-digest/run-smoke.sh`
(mirrors `autopickup-tick-audit/run-smoke.sh`), registered in
`self-test/golden-cases.example.json`. Asserts:

1. **Never run** (`last_digest_run = null`), now after `digest_time` →
   `digest.digest_due == true`, `digest_marker == "digest-due"`,
   `actions.digest_due == true`.
2. **Once/day idempotency**: `last_digest_run == today` → `digest_due == false`,
   reason `already ran today`, marker empty.
3. **New day**: `last_digest_run` = yesterday → `digest_due == true`.
4. **Before configured time**: never-run but `now_hm` < `digest_time` →
   `digest_due == false`, reason mentions the configured time, marker empty.
5. **Human stanza** renders a "Digest" section.
6. **Mutation proof**: a `bash -n` clean check plus the guard's own
   red-green — deleting the time-gate clause in a `mktemp` copy flips
   assertion 4 to fail (proving the test actually constrains the gate).

Plus the existing `--help` / unknown-flag (exit 2) / `bash -n` cases continue
to pass, and `scripts/validate-state-all.sh` passes with the new schema fields
present on a real `state/autopickup.json`.

## Risks / rollback

- **Risk:** tick reports the digest due every tick (over-firing).
  **Mitigation:** the `last_digest_run` daily date-gate — identical to
  `audit_due`'s proven once/day guard.
- **Risk:** schema change rejects existing `autopickup.json` files.
  **Mitigation:** both new fields are optional (not in `required`) and
  `additionalProperties` is already `true`; existing files validate unchanged.
- **Risk:** time-gate string comparison breaks on un-padded hours (e.g. `9:00`).
  **Mitigation:** the tick zero-pads `now_hm` from `date +%H:%M` (always two
  digits) and the schema pattern forces `digest_time` to `HH:MM`, so the
  lexical compare is sound.
- **Rollback:** the step is report-only and additive. Reverting the tick block
  removes the marker; the schema fields are optional and harmless if left.
  Commander simply stops seeing a "digest due" line.

## Implementation notes

Files touched (all owned by this ticket per the coordinate-with hint):

- `scripts/autopickup-tick.sh` — new section 4f + `--minute` seam + JSON/human
  wiring + actions roll-up entry.
- `state/schemas/autopickup.schema.json` — `last_digest_run` + `digest_time`.
- `self-test/fixtures/autopickup-tick-digest/` — smoke fixture (state/, repos/,
  gh-mock/, run-smoke.sh).
- `self-test/golden-cases.example.json` — register the new smoke case.
- This spec.

**CLAUDE.md follow-up (NOT in this PR):** the "Scheduled autopickup" paragraph
should gain a one-line pointer that the tick now emits a `digest_due` marker
(parallel to the audit/retro pointers). A CLAUDE.md PR is in flight; this is
noted in the PR body for that PR to fold in.
