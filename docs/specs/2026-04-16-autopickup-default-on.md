---
status: implemented
date: 2026-04-16
author: hydra design
ticket: tonychang04/hydra#17
supersedes: none
extends: docs/specs/2026-04-16-scheduled-autopickup.md
---

# Autopickup default-on (opt-out)

## Problem

The scheduled autopickup feature (spec `2026-04-16-scheduled-autopickup.md`, PR #10) landed as opt-in: the operator has to type `autopickup every N min` every session. That's friction against the stated vision — "Commander is an auto-machine that clears tickets. Humans are the exception, not the default."

Every session where the operator forgets to arm autopickup is a session where Hydra sits idle waiting for manual `pick up N` commands. The default should do the right thing.

## Goals

- Launching `./hydra` enters autopickup mode automatically, using the existing `interval_min` from `state/autopickup.json` (default 30).
- Opt-out path that is explicit, per-session, and discoverable: `./hydra --no-autopickup`.
- Backward-compat for operators whose `state/autopickup.json` predates this change (no field → behave as default-on).
- Zero change to the tick procedure, preflight gate, rate-limit auto-disable, or merge policy. Default-on is purely a session-start flip of `enabled`.

## Non-goals

- Not removing the `autopickup every N min` / `autopickup off` commands. They still work; default-on just means most sessions never need them.
- Not adding a daemon or persisting autopickup across crashes. Session-start checks `state/autopickup.json` in the current repo; if the commander session dies, the next session re-enables.
- Not changing `interval_min` defaults, clamps, or budget interaction. Those are settled in the base spec.

## Proposed approach

Three tiny pieces of state and one prompt change:

1. **`state/autopickup.json` gains `auto_enable_on_session_start: true`.** Defaults `true`. Operators who specifically want opt-in behavior set it to `false` and live with the previous workflow.
2. **`setup.sh` seeds `state/autopickup.json` on first run** with `{enabled: false, interval_min: 30, auto_enable_on_session_start: true, ...}`. Existing autopickup files are left untouched (idempotent setup).
3. **`./hydra` launcher accepts `--no-autopickup`**, which exports `HYDRA_NO_AUTOPICKUP=1` before `exec claude`. Environment-level override, scoped to the single session.
4. **Commander's session-start greeting** (`CLAUDE.md` → "Session greeting") runs a default-on check:
   - Read `state/autopickup.json`. Missing → skip (nothing to auto-enable yet).
   - `enabled` already `true` → leave it alone.
   - Else if `auto_enable_on_session_start` (default `true` if missing) AND `HYDRA_NO_AUTOPICKUP` unset → flip `enabled: true`, reset `consecutive_rate_limit_hits: 0`, and enter autopickup mode using the existing activation procedure with `N = interval_min`.
   - Include autopickup status in the greeting line.

The tick procedure itself is unchanged. Default-on is a cheap session-start hook.

### Alternatives considered

- **A: Remove opt-out entirely.** Rejected — debugging / read-only sessions sometimes need a silent commander. `HYDRA_NO_AUTOPICKUP=1 ./hydra` and `--no-autopickup` are cheap insurance.
- **B: Put the toggle in `budget.json`.** Rejected — `budget.json` is about caps, not behavior flags, and autopickup state already has its own file. One setting, one home.
- **C: Auto-enable on the first operator command of the session instead of on greeting.** Rejected — that just reproduces opt-in with extra steps. Session start is the right moment.

## Test plan

1. **Fresh install.** Delete `state/autopickup.json`, run `./setup.sh`. Verify `state/autopickup.json` exists with `auto_enable_on_session_start: true` and `interval_min: 30`.
2. **Default launch.** `./hydra`. Greeting should include `Autopickup: on (every 30 min)` and note the auto-enable. `state/autopickup.json:enabled` should flip to `true`.
3. **Opt-out launch.** `./hydra --no-autopickup`. `HYDRA_NO_AUTOPICKUP` should be `1` in the commander env; greeting should show `Autopickup: off`; `state/autopickup.json:enabled` stays `false`.
4. **Backward compat.** Hand-write a `state/autopickup.json` with the old 5-field schema (no `auto_enable_on_session_start`). Launch `./hydra`. Commander should treat the missing field as `true` and auto-enable.
5. **Operator override.** Set `auto_enable_on_session_start: false` in `state/autopickup.json`. Launch `./hydra`. Commander should stay idle at greeting. `autopickup every 30 min` should still work.
6. **Smoke test in self-test harness.** `self-test/golden-cases.example.json` case `autopickup-default-on-smoke` exercises item 1 and the env-var path of item 3 via shell.

## Risks / rollback

- **Risk:** Operators who relied on implicit opt-in are surprised when `./hydra` starts autopickup. **Mitigation:** The autopickup tick is quiet and gated on the full preflight — no runaway behavior. Greeting explicitly announces the mode and shows the opt-out command. The 2-strike rate-limit auto-disable still applies.
- **Risk:** A stale `state/autopickup.json` from a long-abandoned session auto-enables unwanted pickups. **Mitigation:** The tick procedure checks `max_concurrent_workers`, `daily_ticket_cap`, PAUSE, and rate-limit health before every spawn. Worst case: nothing spawns and nothing happens.
- **Risk:** Integration with `/loop` semantics. **Mitigation:** The default-on check ends by invoking the same activation procedure as `autopickup every N min`. No new `/loop` mechanics.
- **Rollback:** Flip the default. Change the `state/autopickup.json.example` field to `false` and revert the `setup.sh` seed. The greeting check is harmless with default-off. Full rollback: revert the PR.

## Implementation notes

Files touched in the closing PR for #17:

- `state/autopickup.json.example` — new field `auto_enable_on_session_start: true`; updated `_description` to cross-reference the default-on spec.
- `setup.sh` — added `state/autopickup.json` to the runtime state seed loop with the default schema; taught the generated `./hydra` launcher to parse `--no-autopickup` and export `HYDRA_NO_AUTOPICKUP=1` before `exec claude`. Unknown flags pass through to `claude`.
- `CLAUDE.md` — extended "Scheduled autopickup" state schema block with the new field + backward-compat note; rewrote "Session greeting" to run the default-on check and include autopickup status.
- `docs/specs/2026-04-16-scheduled-autopickup.md` — appended an `## Extension 2026-04-16 — default-on behavior (#17)` section pointing at this spec.
- `self-test/golden-cases.example.json` — new `autopickup-default-on-smoke` script-kind case covering the setup.sh seed + env-var override.

We did NOT touch: `.claude/settings.local.json*`, `policy.md`, `budget.json`, worker subagents. Default-on is purely commander-side session bootstrap.
