---
status: accepted
date: 2026-06-07
---

# Scheduled daily self-audit step in the autopickup tick

**Ticket:** #240 ([P1] Schedule the auditor: daily Hydra self-audit feeds drift
tickets into the queue)

**Depends on:** #239 / #244 (autopickup-tick orchestrator — provides the numbered
step-function structure + the `*_due` report-only contract this rides next to).

## Problem

The "auto-write-ticket" pillar is half-built. `worker-auditor`
(`docs/specs/2026-04-17-worker-auditor-subagent.md`) can file up to 3
`commander-auto-filed` drift tickets, but it is **operator-invoked only** (the
`audit` command). The auditor spec's non-goal explicitly deferred scheduling,
and #179 only added a CLAUDE.md *prose* claim ("step 1.7 of the Monday tick")
with **no runnable detection in `scripts/autopickup-tick.sh`** — so the tick
never actually tells Commander an audit is due. For a machine whose directional
goal is "less dependent on the human," self-audit must be automatic and visible
in the same report Commander already acts on every tick.

Concretely, after #239 the tick emits `scheduled.retro_due`,
`scheduled.promotion_due`, and `hygiene.hygiene_due` — but nothing for the
auditor. Commander has no mechanical signal to spawn `worker-auditor`.

## Goals

1. Add a self-contained **audit step** to `scripts/autopickup-tick.sh` that, at
   most once per day (idempotent via `state/autopickup.json:last_audit_run`,
   mirroring `last_retro_run` / `last_promotion_run`), emits an `audit_due`
   marker recommending Commander spawn `worker-auditor` against the hydra repo.
2. Surface it as an additive `audit` key in the `--json` tick report and an
   `actions.audit_due` roll-up boolean — the same additive-only shape the
   existing `scheduled` / `hygiene` keys use.
3. Carry **dedupe guidance** in the report so Commander (and the spawned
   auditor) respect the existing rails: the auditor caps at ≤3 issues/run and
   dedupes by title against open `commander-auto-filed` issues. The tick does
   NOT itself enumerate issues — it reports the cap + dedupe rule as a
   `dedupe_hint` so the actuation stays in Commander/auditor where the
   `gh issue list` write/read budget lives.
4. **Report-only**: the audit step never spawns `worker-auditor`, never files
   issues, never stamps `last_audit_run`. It emits `audit_due: true/false`;
   Commander actuates (spawns the auditor) and stamps `last_audit_run` when it
   does — the exact same split as retro (`retro_due` → Commander writes +
   stamps) and promotion (`promotion_due` → Commander promotes + stamps).
5. Update the worker-auditor spec's "no scheduled invocation" non-goal and the
   `worker-auditor.md` "Scheduled invocation" section to point at this spec and
   reflect the **daily** (not Monday-only) cadence.

## Non-goals

- **No new state field.** `state/autopickup.json:last_audit_run` already exists
  (added by #179 for the never-implemented Monday hook) and is already in
  `state/schemas/autopickup.schema.json` + `state/autopickup.json.example`. This
  ticket reuses it; the only schema touch is widening its description to say
  "daily" rather than "Monday window". No `required`-list change, no migration.
- **No spawning / filing / merging from the script.** Same report-don't-mutate
  rule as the rest of `autopickup-tick.sh`.
- **No change to the auditor's detection rules** (`scripts/audit-detect.sh`) or
  its ≤3 cap / dedupe logic. The step only *recommends* a run.
- **No re-implementation of `promote-citations.sh --check-due`-style tooling.**
  The audit due-gate is a small inline date compare (there is no separate
  `audit-check-due` script and #240 does not add one — the gate is trivial and
  symmetric with the retro idempotency code already in the tick).

## Proposed approach

### Cadence: daily, not Monday-only

The ticket is explicit: `audit_due: true` **once/day**, false otherwise. This
supersedes #179's aspirational Monday-only prose. Daily is the stronger autonomy
posture and is symmetric with the once/day skill-promotion gate the tick already
delegates to. The dedupe rail (≤3/run + open-issue title dedupe) means a daily
cadence cannot flood the tracker: worst case the auditor files 3 issues, all
deduped against what is already open, and on a clean repo `audit-detect.sh`
returns `[]` so nothing is filed at all.

### Where the logic lives — section 4d

`autopickup-tick.sh` is organized as numbered sections (1 preflight … 4b
scheduled … 4c hygiene … 5 actions roll-up … 6 output). The audit step slots in
as **section 4d**, after hygiene and before the actions roll-up, mirroring 4b/4c
exactly:

- reads only `state/autopickup.json:last_audit_run` + the resolved "today"
  (already computed for the scheduled block via `--today` / live clock),
- produces one compact JSON object `audit_json`,
- emits nothing irreversible.

### Due-gate (idempotent, daily)

```
audit_due = (last_audit_run's date != today)
```

`last_audit_run` is stored by Commander as a local ISO-8601 timestamp (e.g.
`2026-06-07T09:03:00`); the gate compares only its date portion against today
(`--today <YYYY-MM-DD>` override for tests, else `date +%F`). Null / missing /
malformed `last_audit_run` ⇒ never run ⇒ due. This is the same date-string
compare the promotion gate uses, kept inline for symmetry.

When due, `audit_marker = "audit-due"` and `dedupe_hint` carries the rail text:
`worker-auditor caps at <=3 issues/run; dedupe by title vs open
commander-auto-filed issues`. When not due, `audit_marker = ""` and
`audit_reason` explains (`"already ran today"`).

### JSON report additions

One additive top-level key (`audit`) plus one additive `actions` field
(`audit_due`). Existing keys unchanged — additive only, per the script's
stability contract:

```json
{
  "audit": {
    "today": "2026-06-07",
    "last_audit_run": null,
    "audit_due": true,
    "audit_marker": "audit-due",
    "audit_reason": "",
    "dedupe_hint": "worker-auditor caps at <=3 issues/run; dedupe by title vs open commander-auto-filed issues"
  }
}
```

Human report gains an "Audit (daily self-audit)" stanza and an Actions
roll-up footnote when due:
`↳ Audit DUE — Commander: spawn worker-auditor on the hydra repo (<=3 issues,
dedupe vs open commander-auto-filed), then stamp last_audit_run.`

### Schema + state

No new field. `state/schemas/autopickup.schema.json:last_audit_run` description
is widened from "Monday autopickup tick, step 1.7 … once per Monday window" to
"daily autopickup tick … at most once per day". `additionalProperties` is
already `true`; the field stays optional. `state/autopickup.json.example`
already carries `"last_audit_run": null` — unchanged.

## Test plan

A new fixture `self-test/fixtures/autopickup-tick-audit/` with a `run-smoke.sh`
driven fully offline, asserting the acceptance criteria:

1. **Audit-due fires when never run** — `last_audit_run: null`, `--today
   2026-06-07` ⇒ `.audit.audit_due == true`, `.audit.audit_marker ==
   "audit-due"`, `.audit.dedupe_hint` mentions the `<=3` cap and
   `commander-auto-filed`. `.actions.audit_due == true`.
2. **Same-day idempotency** — `last_audit_run: 2026-06-07T09:00:00`, `--today
   2026-06-07` ⇒ `.audit.audit_due == false`,
   `.audit.audit_reason == "already ran today"`, `.actions.audit_due == false`.
   This is the "once/day then false same-day" proof the ticket requires.
3. **New day re-fires** — `last_audit_run: 2026-06-06T09:00:00`, `--today
   2026-06-07` ⇒ `.audit.audit_due == true` (a stamp from yesterday does not
   suppress today).
4. **Human-mode renders** — the "Audit" stanza appears in the non-JSON report.

The existing `self-test/fixtures/autopickup-tick/run-smoke.sh` and
`autopickup-tick-scheduled/run-smoke.sh` continue to pass unchanged (additive
JSON key + new `--today`-reusing gate with a safe default). A golden `kind:
script` case `autopickup-tick-audit-smoke` is appended (unique name; existing
entries unreordered) so CI runs it.

Run: `bash self-test/fixtures/autopickup-tick-audit/run-smoke.sh`;
`bash self-test/fixtures/autopickup-tick/run-smoke.sh`;
`bash self-test/fixtures/autopickup-tick-scheduled/run-smoke.sh`;
`bash scripts/validate-state-all.sh`; `bash scripts/preflight-syntax.sh`.

## Risks / rollback

- **Risk:** daily cadence floods the issue tracker. → Mitigated by the unchanged
  ≤3/run cap + open-issue title dedupe owned by `worker-auditor`; on a clean repo
  `audit-detect.sh` returns `[]`. The tick only *recommends*; it files nothing.
- **Risk:** the tick accidentally stamps `last_audit_run` and double-suppresses or
  the auditor double-files. → Mitigated by report-don't-mutate: the step has zero
  side effects; only Commander stamps `last_audit_run`, and only after it spawns
  the auditor.
- **Risk:** drift between this daily cadence and the auditor's own
  "Monday-only" prose. → Mitigated by updating `worker-auditor.md` +
  `2026-04-17-worker-auditor-subagent.md` in the same PR.
- **Rollback:** additive (new section 4d, new JSON key, one widened schema
  description, one new fixture, one appended golden case). Reverting the commit
  restores the #239 behavior with no migration.
