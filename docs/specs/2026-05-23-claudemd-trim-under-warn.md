---
status: implemented
date: 2026-05-23
author: hydra worker (ticket #231)
---

# Trim CLAUDE.md back under the WARN band (97% → 89%) — prose → existing specs

## Problem

After the self-driving-autopickup-tick capstone (#229) merged, `CLAUDE.md` sat at
**17489 / 18000 chars (97%, WARN band)** — ~511 chars (one routing row) from the
hard 18000 ceiling. The ceiling is a **hard preflight gate**: at 18000 every
Commander spawn blocks (`scripts/check-claude-md-size.sh` inside
`scripts/validate-state-all.sh`). Commander needs runway, not a wall.

A prior attempt (PR #232, closed) branched from a **stale local main** that
predated #229 and trimmed against the wrong ~93% baseline, so it did not actually
relieve the post-#229 pressure. This ticket re-does the trim from **current**
`origin/main`.

The bloat came from expanded *prose* in sections that already point to specs —
exactly what the CLAUDE.md scope rule forbids (`memory/feedback_claudemd_bloat.md`,
spec `docs/specs/2026-05-20-claudemd-size-graduated-bands.md`): CLAUDE.md is loaded
into every Commander session, so every inlined sentence is a token tax paid on
every spawn, forever.

## Goals

- `CLAUDE.md` back into the **NOTICE band**, target **< 90% (~16200)**, with
  `check-claude-md-size.sh` exit 0.
- **Zero information lost** — every sentence trimmed from CLAUDE.md already lives
  (verbatim or fuller) in the spec the section points to. Verified before trimming.
- **Hard rails byte-identical** — the "Safety rules (hard)" section, the "Applying
  labels" REST rule, the Worker-types table, and the Commands table are NOT touched.
- Every `docs/...` pointer remaining in CLAUDE.md resolves to a real file.
- `scripts/validate-state-all.sh` exit 0.

## Non-goals

- Raising the 18000 ceiling. The gate trip is the signal to move prose out, not to
  raise the limit (per the bloat rule).
- Restructuring routing tables or changing any Commander procedure semantics. This
  is a pure prose-density reduction; behavior is unchanged.

## Proposed approach

Collapse the expanded prose in seven prose-heavy sections that already carry spec
pointers, leaving a tight routing summary + the pointer. Sections trimmed and where
the removed detail already lives:

| CLAUDE.md section | Prose removed → preserved in |
|---|---|
| Scheduled autopickup (#229 self-driving tick) | full tick contract, merge-surface auto-vs-human, T3/safety-rail never-auto-merge → `docs/specs/2026-05-24-self-driving-autopickup-tick.md` |
| Worker timeout watchdog | verdict→action table, completion-probe (#219), anti-stall rules → `2026-04-16-worker-timeout-watchdog.md`, `2026-05-23-auto-rescue-on-completion.md`, `2026-05-24-worker-anti-stall-discipline.md` |
| Memory hygiene | env-var default + per-state classifiers detail → `memory/memory-lifecycle.md`, `2026-04-17-memory-preloading.md` |
| Weekly retro | wording tightened; idempotency/auto-file detail → `2026-04-16-retro-workflow.md`, `2026-04-17-retro-auto-file.md` |
| Session greeting (3 health one-liners) | per-line example strings → the three cited specs |
| Operating loop (preflight / pick / spawn / track) | inline spec parentheticals → `2026-04-17-{assignee-override,linear-ticket-trigger,active-schema-drift}.md` (size-guard + state-schemas specs still cited elsewhere in CLAUDE.md) |
| Escalate / PR Shepherd / Validate-before-trust | rate-limit/scope numbers + classifier enum + ajv detail → their specs |

Alternatives considered:

- **Move a whole section out to a new spec.** Rejected — the sections are already
  routing-shaped; the win is removing duplicated prose, not relocating routing.
- **Raise the ceiling to 20000.** Rejected — explicitly against the bloat rule;
  trades a one-time fix for permanent token tax.

## Test plan

- `scripts/check-claude-md-size.sh` → NOTICE band, < 90%, exit 0.
- `scripts/validate-state-all.sh` → exit 0.
- `git diff origin/main -- CLAUDE.md` shows the "Safety rules (hard)" and "Applying
  labels" sections and the two tables are absent from the diff (byte-identical).
- Every `docs/...md` pointer grep'd from CLAUDE.md resolves to an existing file.

## Risks / rollback

- **Risk:** over-trimming drops a routing fact a future Commander needs. Mitigation:
  each removed sentence was confirmed present in the target spec before deletion; only
  prose duplication and example strings were removed, never a script name, label,
  command row, or gate.
- **Rollback:** single-file revert of the `CLAUDE.md` commit; the prose is
  recoverable from git history and from the specs it points to.
