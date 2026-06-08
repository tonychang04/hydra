---
status: draft
date: 2026-06-01
author: hydra worker (issue #97)
---

# Auto-fallback to Codex when Claude rate-limits / tokens exhausted

**Ticket:** [#97](https://github.com/tonychang04/hydra/issues/97)
**Tier:** T2 — Commander spawn-path routing + preflight change (safety-adjacent gate).
**Depends on:** [#96](https://github.com/tonychang04/hydra/issues/96) (dual-backend primitive — CLOSED/merged). #96 shipped `worker-codex-implementation`, `scripts/hydra-codex-exec.sh`, and the additive `preferred_backend` field on `state/repos.json`. This ticket lands the **router** that #96's CLAUDE.md row called "Dormant until router #97 lands."

## Problem

Today, when Claude Code hits a rate-limit or session-token cap, Hydra's Preflight rule freezes new spawns:

> `CLAUDE.md` → Operating loop, step 2: *"No recent rate-limit error in `state/quota-health.json` (auto-pause 1 hr if flagged)."*

So the operator wakes up to nothing shipped — even though #96 gave us a second, independently-quota'd backend (Codex). The right behavior, once #96 landed: **when Claude is rate-limited, route NEW spawns to the Codex backend instead of freezing.** The machine keeps shipping.

This is purely a *routing* change. The code-gen primitive (`hydra-codex-exec.sh`), the subagent (`worker-codex-implementation`), and the schema field (`preferred_backend`) all already exist and are unchanged here.

## Goals

1. A deterministic, testable **router**: given a repo's `preferred_backend` and the current `state/quota-health.json`, decide which subagent type Commander spawns (`worker-implementation` vs `worker-codex-implementation`). One source of truth, mirroring the existing `scripts/merge-policy-lookup.sh` pattern (a small lookup script Commander calls inside its loop).
2. **Auto-switch on rate-limit**: when a rate-limit is detected, flip `state/quota-health.json:active_backend = "codex"` with a bounded TTL (default 1 hr). New spawns route to Codex until the TTL expires.
3. **Auto-recovery**: when the TTL expires, the router falls back to the repo's `preferred_backend` (claude by default). No permanent silent switch.
4. **Explicit operator control**: an on/off switch (`fallback_on_rate_limit`, default `true`) and manual overrides (`backend claude` / `backend codex` / `backend auto` / `backend status`).
5. **Additive, back-compat schema**: a new `state/schemas/quota-health.schema.json` whose new fields are all optional, so an absent or partial `quota-health.json` (today's reality — the file is written on-demand) still validates and the router degrades safely to "claude".

## Non-goals

- **Predictive / pre-emptive fallback** (forecasting quota before it's hit). Reactive only — we switch *after* a rate-limit signal. `preferred_backend: "auto"` is still treated as `"claude"` for routing until a future predictive ticket.
- **Multi-account Claude switching** (same-provider account rotation). The fallback here is cross-provider (Claude → Codex).
- **Price-based backend selection.** Quota-driven only for v1.
- **Changing `hydra-codex-exec.sh` or `worker-codex-implementation`.** #96 owns those; untouched.
- **Weakening other preflight checks.** The PAUSE file, schema validation, concurrency cap, and daily ticket cap all stay. Only the *rate-limit branch* of preflight changes meaning: "freeze" → "route to codex (if enabled)".

## Proposed approach

### State shape (`state/quota-health.json`)

The file already existed conceptually (CLAUDE.md preflight reads it) but had no schema and no committed example. This ticket formalizes it. New/extended fields (all optional, additive):

```jsonc
{
  // existing-style fields the rate-limit guard already wrote:
  "last_rate_limit_at": "2026-06-01T09:12:00Z",   // ISO8601; when the last RL fired
  "rate_limit_class": "claude-rate-limit",         // one of the classes below

  // new routing fields (this ticket):
  "active_backend": "codex",                       // "claude" | "codex" — what the router currently serves
  "fallback_reason": "claude-rate-limit",          // why we switched (audit/operator visibility)
  "fallback_expires_at": "2026-06-01T10:12:00Z",   // ISO8601 TTL; router auto-recovers after this
  "fallback_on_rate_limit": true,                  // operator on/off switch; default true
  "manual_override": "auto"                         // "claude" | "codex" | "auto" | absent
}
```

`rate_limit_class` / `fallback_reason` classify the trigger as one of:
`"claude-rate-limit"`, `"anthropic-api-429"`, `"session-token-exhausted"`. Only these classes trip the fallback. A schema-validation failure, lockfile drift, or a network blip is NOT a rate-limit and MUST NOT switch the backend (review focus (a)).

**Default-safe:** every new field is optional. An absent file, or a file with none of these fields, routes to `claude`. `active_backend` only diverts to codex while a non-expired `fallback_expires_at` is present AND `fallback_on_rate_limit` is true.

### The router: `scripts/select-worker-backend.sh`

Pure, side-effect-free decision function. Reads `quota-health.json`, takes the repo's preferred backend, prints the subagent type to stdout. Commander calls it in Operating-loop step 5 to pick `subagent_type`.

```
scripts/select-worker-backend.sh --repo-backend <claude|codex|auto> [--quota-health <path>] [--now <iso8601>]
  → stdout: "worker-implementation" | "worker-codex-implementation"
  → also prints a one-line reason to stderr (for the operator chat line)
  exit 0 always on a valid decision; exit 2 on usage error.
```

`--now` is injectable so the self-test can assert TTL expiry deterministically (defaults to `date -u`).

**Decision precedence** (first match wins):

1. **Manual override of a concrete backend.** `manual_override == "codex"` → codex; `manual_override == "claude"` → claude. The operator's explicit `backend codex`/`backend claude` wins over everything, including an active auto-fallback, until they say `backend auto` (review focus (b): manual override respects operator choice). `manual_override == "auto"` or absent falls through.
2. **Fallback disabled.** `fallback_on_rate_limit == false` → repo's `preferred_backend` (claude default). The auto-switch never fires; this is the explicit off-switch.
3. **Active, non-expired fallback.** `active_backend == "codex"` AND `fallback_expires_at` exists AND `now < fallback_expires_at` → codex.
4. **Default.** Repo's `preferred_backend`: `"codex"` → codex; `"claude"`/`"auto"`/absent → claude. (`auto` = "let routing decide", and reactive routing already happened in steps 1–3, so it lands on claude here.)

Step 3's TTL check IS the auto-recovery: once `now >= fallback_expires_at`, the active fallback is ignored and we drop to step 4 (claude). The router does not mutate state — recovery is a read-time decision. (A separate writer, below, can optionally clean the stale field, but correctness doesn't depend on it.)

### Flipping the switch: `scripts/set-backend-fallback.sh`

The writer side. Two responsibilities, both thin:

- `--trigger <class> [--ttl-hours N]` — called when a rate-limit is detected. Sets `active_backend=codex`, `fallback_reason=<class>`, `fallback_expires_at=now+N` (default 1), `last_rate_limit_at=now`, `rate_limit_class=<class>`. No-op (idempotent) if `fallback_on_rate_limit=false`. Refuses to trigger on a class not in the allow-list (exit 2) — this is the guard against non-rate-limit errors switching the backend.
- `--set <claude|codex|auto>` — the `backend <x>` commands. `claude`/`codex` set `manual_override` to that value; `auto` clears `manual_override` (re-enables auto-fallback) AND clears any active fallback fields so the next read starts clean.
- `--status` — prints active backend + reason + TTL remaining (the `backend status` command). Read-only.

Writes go through a temp-file + `mv` (atomic), creating `state/quota-health.json` from `{}` if absent. Never logs token/quota *values*, only the class string.

### Commander Preflight + spawn wiring (CLAUDE.md)

- Operating loop step 2's rate-limit bullet changes meaning: a recent rate-limit no longer auto-pauses for an hour *if* `fallback_on_rate_limit` is true — instead Commander calls `set-backend-fallback.sh --trigger <class>` and keeps spawning, routed to codex. If `fallback_on_rate_limit` is false, the legacy 1-hr freeze still applies (back-compat for operators who opt out).
- Operating loop step 5 calls `select-worker-backend.sh` to choose `subagent_type` per spawn.
- Four new commands in the commands table: `backend claude` / `backend codex` / `backend auto` / `backend status` → `set-backend-fallback.sh`.
- One operator chat line on first fallback fire: `⚠ Claude rate-limit detected — switching to Codex backend for 1hr. Re-enable Claude with 'backend claude' or wait for auto-recovery.`

To respect the CLAUDE.md size guard (currently ~89%, NOTICE band), the procedure lives in THIS spec; CLAUDE.md gets only one-line pointers + the four command rows.

### policy.md

Gains a short "Backend fallback on rate-limit" subsection documenting `fallback_on_rate_limit` default `true` and the TTL auto-recovery rule, pointing here for the full procedure.

### Un-fallback probe doesn't burn quota (review focus (c))

Auto-recovery is a *read-time TTL expiry*, not a "retry Claude to see if it works" probe. We never spend a Claude spawn just to test recovery. When the TTL lapses, the very next real ticket spawns on Claude; if Claude is still rate-limited, that spawn's failure re-triggers the fallback through the normal `--trigger` path. Zero speculative quota burn.

## Test plan

1. `bash -n scripts/select-worker-backend.sh` and `bash -n scripts/set-backend-fallback.sh` — syntax clean.
2. New script-kind self-test `codex-fallback-trigger` (`self-test/fixtures/codex-fallback/run.sh`) asserting the router's full decision table against fixture `quota-health.json` files:
   - active codex fallback, TTL in future → `worker-codex-implementation`.
   - same fixture, `--now` past `fallback_expires_at` → `worker-implementation` (TTL-expiry recovery).
   - `fallback_on_rate_limit=false` with active codex fallback → `worker-implementation` (off-switch wins).
   - `manual_override=codex` with no fallback → `worker-codex-implementation`.
   - `manual_override=claude` with active codex fallback → `worker-implementation` (operator override beats auto).
   - absent quota-health file → `worker-implementation` (default-safe).
   - repo `preferred_backend=codex`, no fallback → `worker-codex-implementation`.
   - writer: `--trigger claude-rate-limit` sets codex+TTL; `--trigger lockfile-drift` refuses (exit 2, no switch); `--set auto` clears override+fallback.
3. `scripts/validate-state-all.sh` — green, including the new schema (skips the absent live `quota-health.json`; the committed example validates if validated).
4. Wire the new case into `self-test/golden-cases.example.json`.
5. `scripts/check-claude-md-size.sh --quiet` — stays under ceiling.

## Risks and rollback

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| A non-rate-limit error switches the backend | Med | `--trigger` allow-lists the three rate-limit classes; anything else exits 2 without writing. Self-test asserts `lockfile-drift` is refused. |
| Manual override silently lost on auto-fallback | Low | Router precedence step 1 puts `manual_override` above the active fallback. Self-test asserts `manual_override=claude` beats `active_backend=codex`. |
| Permanent silent switch to codex | Low | Fallback is TTL-bounded (default 1hr) and recovers read-side at expiry; `backend auto` and `fallback_on_rate_limit=false` both clear/disable it. |
| Recovery probe burns Claude quota | Low | Recovery is read-time TTL expiry, not an active retry. No speculative spawn. |
| Codex also unavailable when we fall back to it | Med (operator's ChatGPT-account blocker, #96) | `hydra-codex-exec.sh` exits 4 (codex-unavailable); `worker-codex-implementation` labels `commander-stuck` with a clear reason. Not a regression — same behavior as a manually-set codex repo today. |
| Schema breaks an old quota-health.json | Low | Every field optional/additive; `validate-state.sh` in preflight catches issues; rollback = delete the schema. |

**Rollback:** revert the PR. The two scripts are new (no callers if CLAUDE.md is also reverted), the schema is additive, the CLAUDE.md edits are additive routing rows. Zero data migration.

## References

- Ticket [#96](https://github.com/tonychang04/hydra/issues/96) + `docs/specs/2026-04-17-codex-worker-backend.md` — the primitive this routes on.
- `scripts/hydra-codex-exec.sh` — exit-4 codex-unavailable contract the fallback target relies on.
- `.claude/agents/worker-codex-implementation.md` — the subagent the router selects.
- `scripts/merge-policy-lookup.sh` — pattern this router mirrors (small lookup script Commander calls in its loop).
- `state/schemas/repos.schema.json` — `preferred_backend` enum the router reads.
- `scripts/validate-state-all.sh` / `docs/specs/2026-04-16-state-schemas.md` — schema-validation framework.
