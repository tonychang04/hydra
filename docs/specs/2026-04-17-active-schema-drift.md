---
status: proposed
date: 2026-04-17
author: hydra worker (ticket #82)
---

# active.json schema drift fix — add worktree + branch, align enums

## Problem

PR #69 (ticket #45, worker timeout watchdog) landed a `scripts/rescue-worker.sh --probe <worktree> <branch> <ticket>` call but Commander has no canonical source for `<worktree>` and `<branch>` per worker. It reconstructs them by convention (the worktree path format + the `hydra/commander/<n>` branch naming). The reviewer on PR #69 flagged this as fragile:

- If the worktree path or branch naming convention changes, the watchdog breaks silently.
- Workers that fall back to `commander/hydra-<n>` (when `hydra/commander/<n>` is taken) force the watchdog to guess between two naming patterns.
- There is no truthy mapping from `agentId` → `(worktree, branch)`.

PR #68 (ticket #30) also flagged schema drift concern C1: `state/schemas/active.schema.json`'s `subagent_type` enum does not include `worker-conflict-resolver` (shipped in PR #58), and the `status` enum uses underscored/terse forms (`paused`, `done`) while CLAUDE.md and worker protocol use `paused-on-question` and adds a `rescued` state (per the watchdog).

Both concerns were explicitly marked as follow-up tickets at review time. This ticket implements the follow-up.

## Goals

1. Extend `state/schemas/active.schema.json` with two **optional** string fields:
   - `worktree` — absolute path to the worker's worktree (e.g. `/Users/gary/projects/insforge-repo/hydra/.claude/worktrees/agent-abf32617`)
   - `branch` — branch the worker is committing to (e.g. `hydra/commander/51` or `commander/hydra-51` when the preferred pattern is taken)
2. Fix `subagent_type` enum drift: add `worker-conflict-resolver`. Final set: `["worker-implementation", "worker-review", "worker-test-discovery", "worker-conflict-resolver"]` — matches `.claude/agents/` on disk.
3. Fix `status` enum drift. Final set: `["running", "paused_on_question", "paused-on-question", "complete", "failed", "rescued"]`. Both hyphenated and underscored forms of `paused-on-question` are accepted for one release cycle (see "Deprecation" below). Adds `rescued` for workers recovered via the PR #69 watchdog procedure.
4. Update CLAUDE.md Operating loop step 6 to include the new fields in the Track signature: `{id, ticket, repo, tier, started_at, subagent_type, worktree, branch, status}`.

## Non-goals

- Do not change any field already in the schema beyond the two enum updates above. `tier`, `id`, `ticket`, `repo`, `started_at` stay exactly as they are.
- Do not mark `worktree` or `branch` as required. Entries from prior sessions that have neither field must still validate — otherwise `scripts/validate-state-all.sh` would start failing preflight against the live `state/active.json` the moment this PR lands.
- Do not remove the underscored `paused_on_question` yet. See Deprecation.
- Do not modify `scripts/rescue-worker.sh` or any watchdog logic — this ticket only adds the canonical fields the watchdog needs. Actually wiring the watchdog to read them is a follow-up.
- Do not edit `infra/*`, `bin/*`, or `scripts/*` (except to verify via `scripts/validate-state.sh`).

## Proposed approach

### 1. Schema edits (`state/schemas/active.schema.json`)

Two additive changes to the worker item's `properties` block, both optional:

```json
"worktree": {
  "type": "string",
  "description": "Absolute path to the worker's worktree. Optional for back-compat with in-flight entries from before this field was added (2026-04-17, ticket #82).",
  "minLength": 1
},
"branch": {
  "type": "string",
  "description": "Branch the worker is committing to (e.g. 'hydra/commander/82' or the 'commander/hydra-82' fallback). Optional for back-compat.",
  "minLength": 1
}
```

The `required` array stays `["id", "ticket", "repo", "tier", "started_at", "subagent_type", "status"]` — same as today. No migration needed for existing entries.

Enum updates on two existing fields:

```json
"subagent_type": {
  "enum": ["worker-implementation", "worker-review", "worker-test-discovery", "worker-conflict-resolver"]
},
"status": {
  "enum": ["running", "paused_on_question", "paused-on-question", "complete", "failed", "rescued"]
}
```

Description on the schema object is updated to cite both the new optional fields and the deprecation.

### 2. CLAUDE.md edit

The single line edit in "Operating loop" step 6:

```
6. **Track** in `state/active.json` with `{id, ticket, repo, tier, started_at, subagent_type, worktree, branch, status}`.
```

No other CLAUDE.md section changes in this ticket. (Ticket #81 is editing the separate "Safety guarantees" list — additive, no conflict.)

### 3. Deprecation: underscored `paused_on_question`

CLAUDE.md and the three-tier decision protocol consistently use `paused-on-question` (hyphenated). But the current live enum already accepts `paused` (terse) and the watchdog spec uses `paused-on-question`. To avoid breaking any writer mid-flight, this PR adds BOTH spellings. A follow-up ticket (not this one) will:

1. Grep the codebase for any remaining writer of `paused_on_question`.
2. Migrate them to the hyphenated form.
3. Drop the underscored entry from the enum.

The spec commit of this PR notes the deprecation; the schema `description` points at this spec so future agents see the deprecation timer.

### Alternatives considered

- **A: Require `worktree` and `branch` on all new entries immediately.** Cleaner long-term, but breaks every existing `state/active.json` entry written before this PR. Preflight would start refusing to spawn on the in-flight session that shipped this change. Rejected.
- **B: Use only the hyphenated `paused-on-question` and treat the underscored form as a bug.** Correct per CLAUDE.md. But there may be in-flight writers using either form, and this is the kind of ambiguity the "accept both for one release" pattern exists for. Rejected for the back-compat cycle.
- **C (picked):** additive schema fields, both enum spellings, CLAUDE.md cross-ref update.

## Test plan

1. `jq empty state/schemas/active.schema.json` — JSON validity.
2. `scripts/validate-state.sh state/active.json --schema state/schemas/active.schema.json` — the live state file (which has no `worktree`/`branch` fields and uses `status: "running"`) validates cleanly against the new schema. This is the critical back-compat check.
3. `scripts/validate-state.sh self-test/fixtures/state-schemas/valid/active.json --schema state/schemas/active.schema.json` — the valid fixture still validates.
4. `scripts/validate-state.sh self-test/fixtures/state-schemas/invalid/active.json --schema state/schemas/active.schema.json` — still fails (missing required `workers`), exit 1.
5. `scripts/validate-state-all.sh` — bulk runner against real `state/` still exits 0.
6. `./self-test/run.sh --case state-schemas` — golden case still green (bash+jq path; ajv not installed in default env).
7. `bash .github/workflows/scripts/syntax-check.sh` — the repo-wide syntax job still passes (covers the spec, the schema, and CLAUDE.md via spec-presence).

## Risks / rollback

- **Risk:** Downstream consumers that read `active.json` assume `subagent_type` ∈ the old 3-item enum. Mitigation: the only in-tree reader is the self-test runner (reads the fixture, not the live file) and commander itself (reads from memory / directly writes). Both evolve in lockstep with CLAUDE.md.
- **Risk:** The dual enum spelling (`paused_on_question` and `paused-on-question`) leaks into memory citations. Mitigation: memory compaction pass `compact memory` normalizes on read; the deprecation ticket will do a one-time sweep.
- **Rollback:** revert the three changed files (`state/schemas/active.schema.json`, `CLAUDE.md`, this spec). No other files change. Zero data migration.

## Implementation notes

(Filled in after PR lands.)
