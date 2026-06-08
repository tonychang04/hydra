---
status: proposed
date: 2026-06-08
author: hydra worker
ticket: 260
tier: T2
---

# State validation: schema/docs reconciliation + a migration path

**Ticket:** [#260](https://github.com/tonychang04/hydra/issues/260) · **Tier:** T2
(edits the safety-rail file `state/schemas/repos.schema.json`, expect human merge)

## Problem (why now)

Making ajv-strict validation authoritative (#249/#251) was correct in itself, but it
instantly **blocked the autopickup preflight** by rejecting the operator's real
(gitignored) local state that the weak bash+jq fallback had been silently passing:

1. **`state/repos.json`** — all 11 repo entries lacked `ticket_trigger`, which
   `state/schemas/repos.schema.json` marks **required**. But CLAUDE.md (operating
   loop step 3) and `docs/specs/2026-04-17-assignee-override.md` document
   `ticket_trigger` as **defaulting to `assignee`**. Every consumer in the codebase
   already reads it as `(.ticket_trigger // "assignee")` / `r.get("ticket_trigger",
   "assignee")` — the field has always been *de facto optional*. So the schema
   (required) contradicts both the docs and the running code.
2. **`state/memory-citations.json`** — a citation's `tickets` array held a numeric
   `191` where the schema requires strings.

Commander hand-repaired the live state to unblock the loop (added explicit
`ticket_trigger: "assignee"`, coerced ticket numbers to strings) — zero behavior
change — but the underlying defects remained: schema-vs-docs contradiction, and
**no remediation story** when a schema tightening rejects pre-existing valid-by-docs
state. Strict validation that can hard-block preflight with no recourse is a
foot-gun the next schema change re-triggers.

## Goals

- Reconcile `ticket_trigger`: make it **optional** in the schema (it already defaults
  to `assignee` in docs + every consumer). A `repos.json` relying on the default
  validates clean. Zero behavior change.
- Add a **migration/repair path** — `scripts/validate-state.sh --migrate` — that
  backfills documented defaults and coerces known-safe types, so a future schema
  tightening always has a one-command remediation instead of a hard block.
- Provide a RED→GREEN fixture proving the migrate path repairs the two real drift
  classes from this incident (missing `ticket_trigger`, numeric `tickets[]`).
- Keep all OTHER required fields on `repos[]` entries (`owner`, `name`,
  `local_path`, `enabled`) intact — only `ticket_trigger` becomes optional.

## Non-goals

- Reworking how triggers are chosen at runtime (already correct via `// "assignee"`).
- A standalone `scripts/repair-state.sh` — the repair belongs next to validation, as
  a `--migrate` flag on the existing validator, so "validate fails → re-run with
  `--migrate`" is one tool, one mental model.
- Auto-migrating in preflight. `--migrate` is an explicit, operator-invoked
  remediation that WRITES state; preflight stays read-only. (It prints the fix
  command on failure; the operator runs it.)
- Bot-token / authorship work (separate tickets per the assignee-override spec).

## Proposed approach

### Part 1 — `ticket_trigger` optional (schema reconciliation)

Remove `"ticket_trigger"` from the `required` array on the `repos[]` items in
`state/schemas/repos.schema.json`. The `properties.ticket_trigger` definition
(type+enum) stays — when present it must still be one of `assignee|label|linear`.
Absent = the documented `assignee` default, applied by the consumers that already do
so (`scripts/hydra-mcp-server.py`, `scripts/hydra-status.sh`,
`scripts/hydra-list-repos.sh`, `scripts/hydra-add-repo.sh`). No code change is needed
for the default to take effect — this commit only stops the schema from rejecting the
already-supported, already-documented shape.

CLAUDE.md operating-loop step 3 gets a one-word clarification that `ticket_trigger`
is optional and defaults to `assignee` (offset by a trim near the size band, since
this worker owns CLAUDE.md for the batch).

### Part 2 — `scripts/validate-state.sh --migrate`

Add a `--migrate` flag. With it, the validator (before validating) applies a set of
**known-safe, schema-derived repairs** to the named state file, writes the repaired
file back atomically (temp file + `mv`), reports each repair it made, then validates
the result. Repairs implemented:

- **repos.json** — for each `repos[]` entry missing `ticket_trigger`, backfill the
  documented default. The default is sourced from the file's own
  `default_ticket_trigger` if present, else `"assignee"` (matching the consumers'
  `// $dt` / `// "assignee"` logic). This makes the migrate output reflect reality
  rather than blindly hardcoding.
- **memory-citations.json** — for each citation's `tickets[]`, coerce numeric
  elements to their string form (`191` → `"191"`). De-dup is not needed (the parser
  already de-dups); we only fix the type.

Design choices:
- **Idempotent.** Running `--migrate` twice produces a byte-identical file the second
  time (already-string tickets and already-present triggers are untouched).
- **Targeted, not generic.** We do NOT attempt to invent values for arbitrary missing
  required keys — only the two drift classes with a *documented* correct value get
  repaired. Anything else still fails validation loudly (with the existing message),
  so `--migrate` never papers over a genuinely malformed file.
- **`--migrate` is opt-in and writes.** Plain `validate-state.sh` stays read-only and
  unchanged. On a plain (non-migrate) validation failure caused by these drift
  classes, the message points at `--migrate` as the remediation.
- **No new deps.** Repairs are pure `jq` transforms, available on every install (the
  bash+jq fallback path's baseline). Works with or without ajv.

Alternatives considered:
- *Keep `ticket_trigger` required + backfill everywhere.* Rejected: the documented
  source of truth is the `assignee` default; making it required would contradict the
  spec + force every operator's hand-written repos.json to carry boilerplate.
- *Separate `scripts/repair-state.sh`.* Rejected: splits the "validate → repair"
  loop across two tools. A `--migrate` flag keeps it one tool.
- *Auto-migrate inside preflight.* Rejected: preflight must stay read-only;
  silently rewriting operator state on every tick is surprising and unsafe.

## Test plan

RED→GREEN fixture under `self-test/fixtures/state-schemas/migrate/`:
- `repos.before.json` — a repos entry MISSING `ticket_trigger` (valid-by-docs,
  rejected by strict schema).
- `citations.before.json` — a citation with a NUMERIC `tickets[]` element.

Self-test `state-schemas` golden case gains assertions:
1. **RED** — `validate-state.sh` (no `--migrate`) on `repos.before.json` FAILS under
   ajv-strict (missing required would have been the old failure; post-fix the schema
   no longer requires it, so the RED for repos is now "validates clean" — see #5).
   For citations, `validate-state.sh` on `citations.before.json` FAILS strict
   (numeric where string required).
2. **GREEN** — `validate-state.sh --migrate` on a *copy* repairs it, then the copy
   validates clean; assert the migrate output names the repair and the repaired file
   has string tickets / present trigger.
3. **Idempotent** — running `--migrate` twice yields a byte-identical file.
4. **No-op on already-valid** — `--migrate` on a valid fixture changes nothing and
   still validates.
5. **Reconciliation** — a repos.json with NO `ticket_trigger` anywhere now passes
   strict validation (the headline acceptance criterion).

Plus the full suite: `scripts/validate-state-all.sh` OK; `self-test/run.sh --kind
script` no NEW failures; `scripts/preflight-syntax.sh` OK; the ticket's own
`validation-contract.md` passes `scripts/validate-contract.sh`.

## Risks / rollback

- **Safety-rail file** (`repos.schema.json`, #248): the change is a *loosening*
  (removes a required constraint) — it can only make previously-rejected-but-valid
  state pass; it cannot newly-reject anything. Lowest-risk schema edit class. Human
  merge per T2 + safety-rail.
- **`--migrate` writes state.** Mitigated: opt-in flag, atomic write, idempotent,
  targeted repairs only, reports every change. Rollback is `git checkout` of the
  state file (operator's local state is gitignored; they keep their own backups —
  the flag never runs unless invoked).
- **Rollback of the whole change:** revert the PR. The schema returns to requiring
  `ticket_trigger` (re-introducing the original block) and `--migrate` disappears;
  no persisted artifacts to clean up.
