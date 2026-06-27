---
status: draft
date: 2026-06-26
author: hydra worker (ticket #316)
---

# Lower the autopickup default interval (30 → 15) below the stall-watchdog threshold

## Problem

`scripts/autopickup-tick.sh` warns when the scheduled-autopickup interval is too
coarse to catch a stalling worker before it times out:

```
scripts/autopickup-tick.sh:333
if (( interval_min >= 18 )); then
  interval_warn=true
  interval_warn_text="interval_min=${interval_min} will miss the ~18min stream-idle ceiling; set <15"
fi
```

But the documented and initialized DEFAULT interval was **30** — at/above that
same 18-minute threshold. So a fresh operator who takes the default gets a loop
whose very first tick emits `interval_warn=true` ("interval_min=30 will miss the
~18min stream-idle ceiling; set <15"). The default fights the watchdog it ships
alongside: at 30, a tick can only notice a stalled worker long after it is
unrecoverable. This was observed live — the running config sat at 30 and the
tick emitted `interval_warn=true` every run until it was hand-lowered to 15.

The default was defined in many places (CLAUDE.md routing line, two specs, the
state template, the setup initializer, two display fallbacks, and the MCP
status fallbacks); they all said 30 and could silently drift from the 18-minute
threshold again.

## Goals / non-goals

**Goals:**

- Lower the documented + initialized default from 30 to **15** (the value the
  warn text recommends with `set <15`), everywhere the default is defined.
- A default-config tick must NOT emit `interval_warn` (`.preflight.interval_warn
  == false`).
- Add a drift-guard test that reads BOTH the default and the watchdog threshold
  from source and asserts `default < threshold`, so the two can never silently
  drift apart again.
- Keep the accepted range `[5, 120]` unchanged; keep `state/autopickup.json`
  schema-valid.

**Non-goals:**

- Changing the `>= 18` watchdog threshold itself. 18 is correct — the default
  is what was wrong.
- Changing runtime live state (`state/autopickup.json` is gitignored and already
  at 15 in the running config). This spec is about the DEFAULT that fresh
  installs / fallbacks stamp.
- Changing the clamp range, budget interaction, or activation procedure.

## Proposed approach

Mechanically replace the default `30` with `15` at every site that defines the
autopickup default, leaving the warn-threshold logic untouched:

- `CLAUDE.md` — the `autopickup every N min` routing row (`default 30` → `default 15`).
- `docs/specs/2026-04-16-scheduled-autopickup.md` — `default 30` prose + the
  `interval_min: 30` seed example.
- `docs/specs/2026-04-16-autopickup-default-on.md` — the three `default 30` /
  `interval_min: 30` mentions.
- `state/autopickup.json.example` — the committed template `interval_min`.
- `scripts/hydra-setup.sh` — the non-interactive default + the interactive
  prompt default (`[30]`).
- `scripts/hydra-watch.sh`, `scripts/hydra-status.sh` — the `.interval_min // 30`
  display fallbacks.
- `scripts/hydra-mcp-server.py` — the `interval_min` read-fallbacks in the
  status payload.

Then add `scripts/test-autopickup-interval-default.sh`: it extracts the warn
threshold from `autopickup-tick.sh` (the integer in `interval_min >= N`) and the
default from `state/autopickup.json.example`, and asserts the default is an
integer in `[5, 120]` AND strictly below the threshold. Register it as a
`script`-kind golden case so CI runs it.

### Alternatives considered

- **Alternative A — change the warn threshold to >= 31 instead of the default.**
  Rejected: the 18-minute number is grounded in the real stream-idle ceiling
  (`learnings-hydra.md` #45). Raising it to accommodate a coarse default
  re-introduces the exact failure the watchdog exists to prevent.
- **Alternative B — a static "default must be 15" assertion.** Rejected as too
  brittle: it would red on any deliberate future re-tune. The invariant that
  actually matters is `default < threshold`; reading both from source captures
  it without pinning an exact value.

## Test plan

- Run `scripts/autopickup-tick.sh --json` against a fixture with `interval_min:
  15` → `.preflight.interval_warn == false`. Against `interval_min: 30` →
  `interval_warn == true` (before/after evidence).
- `scripts/test-autopickup-interval-default.sh` passes (default 15 < threshold 18).
- `self-test/run.sh --kind=script --case autopickup-interval-default` passes.
- `scripts/validate-state-all.sh` exits 0; `state/autopickup.json` remains
  schema-valid (15 ∈ [5, 120]).
- `scripts/check-claude-md-size.sh` stays in-band (one-token edit).
- `bash .github/workflows/scripts/syntax-check.sh` prints `syntax-check: OK`.

## Risks / rollback

- **Risk:** a missed default site keeps emitting 30. Mitigated by a repo-wide
  grep for `interval_min.*30` / `default 30` and the drift-guard test.
- **Rollback:** revert the PR. No state migration; the change only affects the
  value fresh installs/fallbacks stamp. Existing `state/autopickup.json` files
  are untouched (setup is idempotent on existing files).
