---
status: accepted
date: 2026-06-07
ticket: https://github.com/tonychang04/hydra/issues/273
area: observability / cost + quota visibility
size: S
authors: [worker-implementation]
supersedes: []
extends: []
---

# Cost + quota visibility: `quota-watch.sh` + `quota-health.json` + operator one-liner

Ticket: [#273](https://github.com/tonychang04/hydra/issues/273) — P1/observability, Tier 1.

## Problem

P1/observability is Hydra's weakest pillar (memory: `project_north_star`). Hydra
already has per-ticket cost plumbing (`scripts/cost-rollup.sh`,
`scripts/cost-per-pr.sh`, `scripts/trace-cost.sh`) and daily counters
(`state/budget-used.json`), but there is **no single operator-facing rollup** that
answers "how is the fleet doing right now?" — tickets today, wall-clock,
rate-limit hits, est. cost per ticket, and consecutive-rate-limit state.

Worse, `state/quota-health.json` is referenced in three places — `CLAUDE.md`
preflight ("No recent rate-limit error in `state/quota-health.json`"),
`docs/linear-tool-contract.md`, and the `quota_health` block of
`state/schemas/hydra-status-output.schema.json` — but the file **and its schema
never existed**. The reference is doc fiction (the recurring "scripts without a
spine" pattern, memory: `project_hydra_self_improvement_2026_06`). This ticket
gives it a real, validated home.

## Goals

1. A report-only `scripts/quota-watch.sh --json` that summarizes, from existing
   state, without side effects:
   - `tickets_completed_today`, `tickets_failed_today`, `wall_clock_min_today`
     (from `state/budget-used.json`),
   - `rate_limit_hits_today` and `consecutive_rate_limit_hits`
     (from `state/budget-used.json` + `state/autopickup.json`),
   - `cost_per_merged_pr` and `total_cost_usd` (delegated to the existing
     `scripts/cost-per-pr.sh --json`; NOT reimplemented),
   - a derived `est_cost_per_ticket` (total cost over tickets completed today),
   - a single `operator_line` health string.
2. Create `state/quota-health.json` + `state/schemas/quota-health.schema.json`,
   the durable home for the rate-limit/quota signal the docs already reference.
   Keep `validate-state-all.sh` green under ajv strict.
3. Emit a one-line operator health string consumable by the session greeting and
   the autopickup tick. Do NOT edit `CLAUDE.md` — note the wiring point in the PR
   body (a separate worker owns `CLAUDE.md`).

## Non-goals

- **No soft quotas / throttling / auto-pause logic** (memory: `v1_ship_principle`
  — hard cost-control + visibility only; the file is read-only telemetry, not a
  gate). The existing 2-strike auto-disable lives on `state/autopickup.json` and
  is untouched.
- No new cost math. `quota-watch.sh` is an aggregator over `cost-per-pr.sh` and
  the state files — it adds no token/pricing computation of its own.
- No `CLAUDE.md` / `worker-*.md` / `README.md` / `.claude/skills/` edits (other
  workers own those; COORDINATE-WITH contract).
- No writes to `state/budget-used.json` or `state/autopickup.json`
  (`quota-watch.sh` is read-only over them).

## Proposed approach

### `scripts/quota-watch.sh` (new, report-only)

Pure bash + jq, offline-capable, mirrors the style of `cost-per-pr.sh` /
`autopickup-tick.sh` (same flag parsing, same `--json` vs human dual output,
same `set -euo pipefail`, same exit-code contract). Reads:

- `state/budget-used.json` → today's counters (missing file ⇒ zeros).
- `state/autopickup.json` → `consecutive_rate_limit_hits` (missing ⇒ 0).
- `scripts/cost-per-pr.sh --json` → `total_cost_usd`, `cost_per_merged_pr`,
  `tickets_counted` (delegated; `--merged-prs <file>` and `--logs-dir` flags
  pass through for offline/deterministic runs).

Derives `est_cost_per_ticket = total_cost_usd / tickets_completed_today`
(null when 0 tickets). Composes `operator_line`, e.g.:

```
Quota: 6 done / 0 failed today · 240 min wall-clock · 0 rate-limit hits (0 consecutive) · $0.42/ticket est · $0.50/merged-PR
```

Flags: `--json`, `--logs-dir <dir>`, `--merged-prs <file>`, `--state-dir <dir>`,
`--budget-file <f>`, `--autopickup-file <f>`, `--operator-line` (print ONLY the
one-liner — the form the greeting/tick consumes), `--write` (refresh the durable
`state/quota-health.json`), `-h/--help`. Exit `0` success, `2` usage/jq-missing.
A failure inside `cost-per-pr.sh` degrades gracefully: cost fields become `null`
and the script still exits 0 (visibility must not be gated on `gh`/online cost
lookups).

The default invocation is **pure stdout, no side effects**; only `--write`
touches `state/quota-health.json` — keeps the "report-only by default" contract
while giving Commander a way to refresh the durable file.

### `state/quota-health.json` + schema

Shape aligns with the existing `quota_health` block in
`hydra-status-output.schema.json` (`github_rate_limit_ok`, `linear_rate_limit_ok`)
and extends it with the rollup fields, all optional except a small required core.
Draft-07, `additionalProperties: true` (additive-friendly, matching the other
Hydra state schemas). A committed `state/quota-health.json` seed makes
`validate-state-all.sh` exercise the new schema (the runner skips schemas whose
state file is absent).

## Test plan

A `self-test/`-style bash test (`self-test/quota-watch.test.sh`) with offline
fixtures (temp `--state-dir`, `--logs-dir`, `--merged-prs` file) asserts:

1. `quota-watch.sh --json` emits valid JSON with all documented keys.
2. Counts/wall-clock/rate-limit fields match the fixture `budget-used.json`.
3. `est_cost_per_ticket` = total cost ÷ tickets, and is `null` when 0 tickets.
4. `--operator-line` prints exactly one non-empty line, no JSON.
5. Missing state files degrade to zeros / nulls, exit 0 (no crash).
6. `--write` produces a `quota-health.json` that passes the new schema.
7. `validate-state-all.sh` (ajv strict) passes with the committed seed.

Verify-first via `validation-contract.md` (commands + captured exit codes).

## Risks / rollback

- **Risk:** schema drift breaks preflight (`validate-state-all.sh` is preflight
  item #2). Mitigation: ajv-strict in the contract gate before finalize; schema
  is additive (`additionalProperties: true`).
- **Risk:** `cost-per-pr.sh` calls `gh` online and stalls. Mitigation:
  `quota-watch.sh` degrades cost to null on any failure and never blocks; callers
  wanting determinism pass `--merged-prs`.
- **Rollback:** delete `scripts/quota-watch.sh`, `state/quota-health.json`,
  `state/schemas/quota-health.schema.json`, and the test. No other file is
  mutated, so removal is clean (the `quota_health` schema block in
  `hydra-status-output.schema.json` predates this ticket and stays).
