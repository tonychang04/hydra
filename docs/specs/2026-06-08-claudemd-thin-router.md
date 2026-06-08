---
title: CLAUDE.md thin-router collapse + size-guard band re-tune
ticket: 297
date: 2026-06-08
status: accepted
supersedes_bands_in: docs/specs/2026-05-20-claudemd-size-graduated-bands.md
---

# CLAUDE.md thin-router collapse + size-guard band re-tune

## Problem

CLAUDE.md is loaded into every Commander session's context — every inlined
paragraph is a token tax paid forever. The file kept bouncing near the 18000-char
guard ceiling because it still carried operating-procedure **prose** (Operating
loop, Worker timeout watchdog, Session greeting, Commander review gate, Escalate
to supervisor, Scheduled autopickup, Memory hygiene, Weekly retro, Auto-dispatch
test-discovery). Each of those procedures is **already** documented in full in a
`docs/specs/*.md` file, so the inline prose is pure duplication: ~7000 of ~15400
chars. A thin router — like gstack's CLAUDE.md — should hold only routing tables,
hard rails, a file-structure map, and one-line pointers to the specs that own the
"why" + full procedure.

A secondary issue: the size-guard NOTICE/WARN bands were tuned as a percentage of
the 18000 ceiling (NOTICE 85% → 15300, WARN 95% → 17100). Once the file is trimmed
to ~9-10k, those floors sit ~5000 chars above the lean reality, so routing creep
could nearly double the file before NOTICE ever fires. The bands need to track the
new lean size so creep is flagged early.

## Goals

- Collapse the nine procedure-prose sections into a single concise
  `## Operating procedures (full detail in specs)` index — one line each:
  `**<name>** — <≤1 clause what-it-does>. Spec: <existing pointer(s)>`.
- Keep inline ONLY routing/rails: identity + one-job (load-bearing lines),
  the repository-structure file-map, the worker-types table, the commands table
  (terse `You do` column), the Safety-rules block **verbatim**, and the
  Applying-labels REST-not-GraphQL rule + snippet.
- Re-tune `scripts/check-claude-md-size.sh` default bands so NOTICE fires
  ~10000-11000 chars while keeping the hard ceiling at 18000.
- Land CLAUDE.md ≤ ~10000 chars, comfortably NOTICE-free under the new bands.

## Non-goals

- No behavior change to any Commander procedure — this is a prose relocation.
  Every routing destination, hard rail, and `docs/specs/*` pointer slug is
  preserved; only duplicated prose paragraphs are removed.
- No change to the guard's *exit-code contract* (OK/NOTICE/WARN → exit 0,
  FAIL → exit 1, usage/unreadable → exit 2) and no change to the 18000 ceiling.
- No new script flags; band tuning is via the existing `notice_pct` / `warn_pct`
  defaults (still env-overridable via `HYDRA_CLAUDEMD_NOTICE_PCT` / `_WARN_PCT`).

## Proposed approach

### 1. CLAUDE.md collapse

Replace these nine `## <section>` prose blocks with one `## Operating procedures
(full detail in specs)` index, one bullet per procedure, each naming the SAME spec
slug(s) the prose already cited (no slug invented, none dropped):

- Operating loop, Worker timeout watchdog, Commander review gate, Escalate to
  supervisor, Scheduled autopickup, Memory hygiene, Weekly retro, Session greeting,
  Auto-dispatch test-discovery.

Pointers that were ONLY reachable through the deleted prose (e.g. the PR-Shepherd,
tick-stall-robustness, rescue-variant, anti-stall, daily-digest, memory-preloading,
skill-seed-list slugs) are carried into the corresponding index bullet so the
slug-preservation invariant holds.

**KEEP inline, unchanged in substance:**
- `## Your identity` + `## Your one job` (already terse).
- `## Repository structure / where things live` (the file-map — the router's core).
- `## Worker types` table (all 6 rows).
- `## Commands you understand` table (all rows; `You do` already terse).
- `## Safety rules (hard)` — **byte-identical**, every rail.
- `## Applying labels` — REST-not-GraphQL rule + the exact `gh api … /labels`
  snippet + the `commander-live-state` marker line.

### 2. Size-guard band re-tune

Change the default band percentages in `scripts/check-claude-md-size.sh`:

- `notice_pct` default 85 → **57** ⇒ notice_floor = 18000 * 57/100 = **10260**.
- `warn_pct`   default 95 → **89** ⇒ warn_floor   = 18000 * 89/100 = **16020**.
- Ceiling (`max_chars`) unchanged at **18000** (the hard rail).

Rationale: NOTICE now fires just above the lean target (~10k), giving an early
"trim a section to a spec" nudge while leaving generous headroom (≈10260→18000)
before the file is anywhere near the gate. WARN stays a late-stage "next addition
breaches the gate" warning. Both remain env-overridable; the ordering invariant
`notice_pct <= warn_pct <= 100` still holds (57 ≤ 89 ≤ 100).

### Alternatives considered

- **Lower the ceiling to ~12000 instead of re-tuning bands.** Rejected: the
  ticket says keep the hard ceiling; lowering it risks tripping FAIL on a
  legitimate future routing addition with no early-warning runway, and changing
  the guard's authoritative default ceiling is a broader contract change than a
  band tune.
- **Tune via env vars in `validate-state-all.sh` rather than script defaults.**
  Rejected: the defaults ARE the policy; baking the lean bands into the script
  default means every caller (preflight, greeting, CI, pre-commit) inherits them
  without each having to export envs.

## Test plan

- `scripts/check-claude-md-size.sh` on the trimmed CLAUDE.md → exit 0, **OK band**
  (no NOTICE/WARN), proving size < new notice_floor (10260).
- `wc -c CLAUDE.md` ≤ ~10000.
- Slug-preservation diff: `grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+'` over
  old vs new (minus bare dates) shows **zero dropped** slugs (44 preserved).
- Command-table row count unchanged (25); worker-types row count unchanged (6).
- `## Safety rules (hard)` block diff empty (byte-identical).
- `bash .github/workflows/scripts/syntax-check.sh` → exit 0.
- `scripts/validate-state-all.sh` → exit 0 (and its size-check leg now reports
  OK, not NOTICE/WARN).
- `bash scripts/test-check-claude-md-size.sh` → exit 0 (the self-test uses
  synthetic `--max 1000` / `--max 18000` fixtures and asserts the *default*
  85/95 percentages in Tests 8-11; those assertions move to the new 57/89
  defaults).

## Risks / rollback

- **Risk:** a self-test fixture hard-codes the old 85/95 default floors and goes
  red after the re-tune. Mitigation: Tests 8-11 in `test-check-claude-md-size.sh`
  are updated to the new defaults (fixtures re-sized so 57%/89% land in the
  intended band) in the same PR; the env-override tests (10/11) still prove the
  knobs work.
- **Risk:** an accidental prose deletion drops a rail or pointer. Mitigation: the
  slug-count + row-count + Safety-block-diff checks above are run pre-PR and pasted
  into the PR body as evidence.
- **Rollback:** revert the PR — CLAUDE.md prose and the old 85/95 band defaults
  return; no state migration, no data, no script API change.
