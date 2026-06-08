---
status: implemented
date: 2026-06-07
author: hydra worker (#270, closes #265)
relates-to: docs/specs/2026-05-20-claudemd-size-graduated-bands.md, docs/specs/2026-06-07-tick-stall-robustness.md
---

# CLAUDE.md = router + repo file-structure map; substance moves to specs

## Problem

`CLAUDE.md` is loaded into every Commander session's system prompt, so every
inlined char is a token tax paid on every spawn, forever. The
`scripts/check-claude-md-size.sh` guard exists precisely because prose creeps in.
As of 2026-06-07 `CLAUDE.md` sat at **17085 / 18000 chars (94%)** — inside the
NOTICE band (≥85%), roughly a routing row from WARN. The CLAUDE.md scope rule
(routing tables, hard rails, one-line spec pointers only — see
`memory/feedback_claudemd_bloat.md`) was being eroded by explanatory prose in the
heaviest H2 sections: `Commands you understand` (2741 chars), `Operating loop`
(1520), `Session greeting` (1295).

Two concrete gaps motivated this now:

1. **No "where things live" map.** A new reader (Commander on a fresh session, a
   worker, the supervisor agent) had no single top-of-file map of which
   authoritative thing lives in `policy.md` vs `state/` vs `docs/specs/` vs
   `memory/` vs `scripts/`. The information was scattered across the "State files"
   section and prose.

2. **Dangling tick recommendations (#265).** The autopickup tick orchestrator
   (`scripts/autopickup-tick.sh`) emits two operator-facing recommended actions
   that CLAUDE.md had no routing for:
   - `actions.gc_stale_worktrees > 0` → "run `scripts/gc-stale-worktrees.sh
     --apply` to reclaim" (script at `autopickup-tick.sh:964`).
   - `preflight.interval_warn == true` → "lower `interval_min` to < 15" (emitted
     at `autopickup-tick.sh:288-290, 966-967`).

   The spec that added those tick steps
   (`docs/specs/2026-06-07-tick-stall-robustness.md`, Goal #4) committed to a
   CLAUDE.md routing touch; only the flaky-tool exit-5 clause landed. Commander
   reading only CLAUDE.md could not route either recommendation.

## Goals

- Add a concise **"Repository structure / where things live"** section near the
  top of CLAUDE.md — one line each for `policy.md`, `budget.json`, `state/`,
  `docs/specs/`, `memory/`, `scripts/`, `.claude/agents/`, `.claude/skills/`,
  `self-test/`, `logs/`.
- Trim explanatory prose from the heaviest H2 sections into the specs they
  already point at, leaving a one-line routing pointer. **Zero routing
  information, hard rails, or spec pointers lost.**
- Fold in #265: add routing for `gc-stale-worktrees --apply` and the
  `interval-warn` response.
- Drop CLAUDE.md back into the **OK band** (≤ 85% = ≤ 15300 chars) so
  `scripts/check-claude-md-size.sh` exits with no NOTICE/WARN.

## Non-goals

- No behavior change to any script — pure docs/structure refactor.
- No change to the size-guard ceiling or band cut points (owned by
  `docs/specs/2026-05-20-claudemd-size-graduated-bands.md`).
- No edits to README, `.claude/agents/*`, `scripts/`, or `.claude/skills/`
  (owned by other workers this batch).

## Proposed approach

1. **New `## Repository structure / where things live` section** immediately
   after "Your one job", as a compact table (path → authoritative content). This
   absorbs and replaces the standalone "State files (read at session start)"
   prose list, which duplicated much of the same map — the map is the single
   source for "where things live" and the old list collapses into a one-line
   pointer that preserves the "validate before you trust" hard rail.

2. **Trim the heavy sections** by relocating already-explained procedure into the
   specs each section already cites, keeping a one-line routing pointer:
   - `Operating loop` — the verbose preflight/pick/spawn bullets compress to
     terse routing lines; the detailed contracts already live in the cited specs.
   - `Session greeting` — the verbatim greeting template and the three
     health-one-liner prose collapse to a pointer at
     `docs/specs/2026-04-16-autopickup-default-on.md` + the band/connector specs.
   - `Scheduled autopickup` / watchdog area absorbs the two #265 routing lines
     while a verbose already-spec-pointed line is trimmed to offset the addition
     (exactly the offset the tick-stall spec assumed).

   Every routing-table row in `Commands you understand`, every `Safety rules`
   hard rail, and the exact REST-API label block are preserved verbatim.

### Alternatives considered

- **Raise the ceiling** — rejected; the guard's whole point is to force prose
  into specs, not to grow the per-spawn token tax. The size-band spec explicitly
  lists "re-litigating the ceiling" as a non-goal.
- **Split CLAUDE.md into includes** — rejected; the harness loads a single
  CLAUDE.md, and a multi-file scheme adds indirection without reducing the loaded
  size. Specs already are the "include" mechanism.

## Test plan

- `scripts/check-claude-md-size.sh` exits 0 with an **OK** band line (no
  NOTICE/WARN) — captured in `validation-contract.md`.
- `scripts/validate-state-all.sh` still exits 0 (the size check is its last
  preflight item; OK band ⇒ pass).
- Manual diff audit: every `Commands you understand` row, every `Safety rules`
  bullet, the REST-API label block, and every `docs/specs/*` pointer present in
  the pre-change CLAUDE.md is present in the post-change CLAUDE.md (grep-based,
  recorded in the contract).
- New `Repository structure` section present; #265's two routing entries
  (`gc-stale-worktrees.sh --apply`, `interval-warn` → lower `interval_min`)
  present.

## Risks / rollback

- **Risk:** dropping a routing row or hard rail while trimming. Mitigated by the
  grep-based preservation audit in the validation contract before finalize.
- **Rollback:** revert the single-file CLAUDE.md change; no script or state
  touched, so revert is clean and behavior-neutral.
