---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 20
tier: T2
---

# Per-repo merge_policy override

**Ticket:** [#20 — Per-repo T1 auto-merge policy](https://github.com/tonychang04/hydra/issues/20)

## Problem

Commander's merge gate is global today: `policy.md` says T1 is auto-merge-eligible, T2 requires human confirmation, T3 is refused. Trust, however, isn't uniform across an operator's repo set:

- A personal side-project repo can safely auto-merge anything up to T2.
- A team production repo wants human-merge for T2 even when auto-merge works fine elsewhere.
- Hydra itself (this repo, self-hosted) wants human-merge for everything — framework changes are high-impact and irreversible on a live commander.

`state/repos.json` already has an optional `merge_policy` field, but it's a single string enum (`auto-t1 | human-all | refuse-all`) that conflates tiers and can't express "T1 auto, T2 human" on one repo. The ticket asks for per-tier granularity.

## Goals

- Per-tier override lives in `state/repos.json:repos[].merge_policy` as an optional object `{T1, T2}`.
- Values per tier: `"auto"` (merge on CI green), `"auto_if_review_clean"` (merge if `worker-review` returns zero blockers), `"human"` (surface for operator).
- Absent `merge_policy`, or absent per-tier key, falls through to `policy.md` defaults (back-compat).
- Commander's `merge #N` command looks up the effective policy before acting.
- A deterministic CLI (`scripts/merge-policy-lookup.sh <owner>/<name> <tier>`) exposes the lookup so Commander, self-tests, and future MCP tools share one source of truth.
- Hydra's own repo example shows `{T1: human, T2: human}` — framework changes always gated.

## Non-goals

- **T3 override.** T3 is always refused; schema tolerates `T3: "never"` as self-documentation but the lookup hardcodes `never` for T3 regardless of override (the operator's scope note: "T3 override is out of scope"). This preserves the hard safety rail.
- **CLI flag to toggle at runtime.** Policy edits go through the file, as with every other `state/repos.json` field.
- **Rewriting `hydra-mcp-server.py:_handler_merge_pr`.** That handler is a Phase-1 stub today; when the real merge dispatch lands in a follow-up ticket, it will call `merge-policy-lookup.sh`. Out of scope for this ticket — but the contract is the shape the follow-up will consume.

## Proposed approach

### Schema (`state/schemas/repos.schema.json`)

The existing `merge_policy` field is currently typed as `string enum` with three values. No caller relies on those strings (grep confirms: only the schema itself mentions them). Evolve the field to `oneOf`:

- **Shape A** (new, preferred): object `{T1, T2}` where each value is `"auto" | "auto_if_review_clean" | "human"`.
- **Shape B** (deprecated, still accepted): the original `string enum`. Minimal-mode validators tolerate either shape because bash+jq only checks top-level required keys.

This keeps any hand-rolled `state/repos.json` that used the old string form working without a migration.

### Lookup CLI (`scripts/merge-policy-lookup.sh`)

```
merge-policy-lookup.sh <owner>/<name> <tier> [--repos-file state/repos.json]
```

Prints the effective policy (`auto | auto_if_review_clean | human | never`) on stdout, exit 0. Exit 1 on invalid input, exit 2 on usage error.

Resolution order:

1. **T3 → always `never`**, regardless of override (hard safety rail).
2. Look up `repos[]` entry by `owner/name`. If not found, exit 1 with a clear message.
3. If `merge_policy` is an object and the tier key is present, return that value.
4. If `merge_policy` is the legacy string: map `auto-t1` → `auto` for T1 / `human` for T2; `human-all` → `human` for any tier; `refuse-all` → `never`.
5. Otherwise, fall through to `policy.md` defaults: T1 → `auto`, T2 → `human` (the pre-ticket global default).

### CLAUDE.md

Under "Safety rules (hard)", add:

> - Per-repo merge overrides live in `state/repos.json:repos[].merge_policy: {T1, T2}`. Before any `merge #N` decision, run `scripts/merge-policy-lookup.sh <owner>/<name> <tier>` and obey the returned policy. T3 is hardcoded `never` — no override.

### Example config (`state/repos.example.json`)

The Hydra self-hosted entry already has a `_comment` flag; extend it with:

```json
"merge_policy": { "T1": "human", "T2": "human" }
```

Add a second commented example on a "your-org/your-repo" entry showing `{T1: "auto", T2: "auto_if_review_clean"}` — the sweet spot for team repos the ticket calls out.

### Self-test (`repo-merge-policy-override`)

Script-kind case covering:

- Lookup returns `human` for a T1 fixture with `{T1: "human"}` (Hydra self-hosted shape).
- Lookup returns `auto_if_review_clean` for T2 with `{T2: "auto_if_review_clean"}`.
- Lookup returns `auto` (T1) / `human` (T2) when `merge_policy` is absent (back-compat default).
- Lookup returns `never` for T3 regardless of override.
- Lookup maps legacy `auto-t1` → `auto`/T1, `human`/T2.
- Lookup exits 1 on unknown repo.
- Schema validator passes both object-shaped and legacy string-shaped repos fixtures.

Fixtures live at `self-test/fixtures/merge-policy/repos-*.json` (one per test shape).

## Test plan

1. `./self-test/run.sh --case repo-merge-policy-override` — new case, all steps green.
2. `./self-test/run.sh` — whole suite, no regressions (particularly the `state-schemas` case, which validates the repos schema under both shapes).
3. `bash -n scripts/merge-policy-lookup.sh` — syntax check.
4. Manual spot-check: run the lookup against the worktree's own `state/repos.example.json` and confirm the Hydra entry returns `human` for both T1 and T2.

## Risks / rollback

- **Risk:** if Commander itself (prompt agent) forgets to consult the lookup, the feature is inert. Mitigation: CLAUDE.md explicitly names the script under "Safety rules (hard)" so it's read at session start.
- **Risk:** a typo in an operator's `state/repos.json` (e.g. `"T2": "auto_if_reivew_clean"`) silently falls through to the default. Mitigation: strict-mode `validate-state.sh --strict` (ajv-cli) catches this via the schema enum; the self-test exercises both paths.
- **Rollback:** revert the PR. Schema change is additive; removing the new shape doesn't break any existing `state/repos.json` that uses the legacy string. The Hydra self-hosted entry in `state/repos.example.json` is a template only — no live behavior change from reverting.
