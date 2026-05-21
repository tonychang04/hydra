---
status: proposed
date: 2026-05-20
author: hydra worker
ticket: 180
tier: T2
---

# `commander-skill-promotion` skill: operator preview/control over citation→skill promotion

**Ticket:** [#180](https://github.com/tonychang04/hydra/issues/180)

## Problem

Memory→skill promotion runs **silently**. `scripts/promote-citations.sh` fires
once per calendar day on the autopickup tick (CLAUDE.md § "Memory hygiene";
`docs/specs/2026-04-17-skill-promotion-automation.md`), scans
`state/memory-citations.json` for entries at the 3×3 threshold (`count >= 3`
AND ≥3 distinct tickets), and opens a draft PR for each. The operator has:

- **no visibility** into what is *trending* toward promotion (an entry at 2
  cites is invisible until the day it crosses 3 and a PR appears), and
- **no control** over the learning entry text before the auto-PR scaffolds a
  `SKILL.md` from it.

A promoted skill can therefore be a surprise. The pipeline is correct but
opaque. This is a P3 (auto-learn) gap: the loop works, but the human can't see
or steer it.

## Goals / non-goals

**Goals**

1. Add `.claude/skills/commander-skill-promotion/SKILL.md` — a worker/Commander-
   facing skill (read in Step 0, not a runtime tool) that documents how to
   *preview and control* promotion.
2. Surface two cohorts from real state files: **trending** (≥2 cites across 2+
   tickets, below threshold) and **promotion-ready** (3×3).
3. Document the preview-before-file step: run the existing script with
   `--dry-run`, inspect the plan, optionally tighten the learning entry, then
   run for real.
4. **Layer over** `scripts/promote-citations.sh` — call/reference it for both
   selection and filing. Do NOT reimplement promotion logic.
5. Verification section with a worked example against the committed
   `state/memory-citations.example.json` fixture (the real `.json` is
   gitignored runtime state).

**Non-goals**

- Reimplementing the selection query, slug logic, idempotence, or PR creation —
  that all lives in `promote-citations.sh` and stays there.
- Changing `promote-citations.sh` itself. This ticket adds a *skill* (docs);
  the script is unchanged.
- Editing `.claude/skills/README.md` (the seed index) — Commander reconciles
  the index after the sibling skill workers (#157, #159) land, to avoid merge
  conflicts.
- Editing `CLAUDE.md`. The "Memory hygiene" section already points at the
  pipeline; the skill is discovered via Step 0's `.claude/skills/*` read.
- Defining a *new* "trending" threshold in the schema or script. Trending is a
  read-only convenience cohort the skill computes via a jq one-liner over the
  same state file; it carries no side effects and no schema change.

## Proposed approach

A single `SKILL.md` under ~150 lines, following the repo skill shape in
`.claude/skills/README.md` (frontmatter → Overview → When to Use → Process →
Examples → Verification), omitting the gstack telemetry preamble.

The skill's Process is a thin operator workflow on top of the existing script:

1. **Preview the promotion-ready cohort** with `promote-citations.sh --dry-run`
   (the authoritative selector — never hand-roll the 3×3 filter).
2. **Preview the trending cohort** with a documented read-only jq one-liner over
   `state/memory-citations.json` (≥2 cites / ≥2 tickets, below threshold). This
   is the new visibility surface — it shows what is *about* to promote.
3. **Optionally tighten the source learning entry** in
   `memory/learnings-<repo>.md` before filing (the script copies the quote +
   context window into the SKILL.md scaffold, so editing the learning improves
   the draft).
4. **File** by running `promote-citations.sh` without `--dry-run` (the same
   script the autopickup tick calls), or wait for the daily tick.

The skill is read-only documentation about how to drive an existing script; it
introduces no new executable. The jq trending one-liner is the only "new" code,
and it has no side effects.

### Alternatives considered

**A. Add a `--trending` flag to `promote-citations.sh`.** Rejected for this
ticket — the ticket asks for a *skill* (preview/control documentation), and the
spec for the script (`2026-04-17-skill-promotion-automation.md`) deliberately
keeps the script's surface minimal (selection + filing). A `--trending` flag is
a reasonable follow-up but is script scope, not skill scope, and would expand a
file this ticket is told not to touch.

**B. Build a separate `preview-promotion.sh` script.** Rejected — that
duplicates the selection logic the Memory Brief explicitly warns against
("do NOT reimplement promotion logic; call/reference the script"). The dry-run
flag already exists for exactly this purpose.

**C. Document only the promotion-ready cohort (skip trending).** Rejected — the
ticket's core complaint is that an entry is *invisible until it crosses the
threshold*. Trending is the visibility half of the feature; dropping it would
miss the point.

## Test plan

The skill is documentation, so "tests" are reproducible commands whose output
is pinned in the Verification section:

1. **Promotion-ready preview** — `promote-citations.sh --dry-run` against
   `state/memory-citations.example.json` (via a temp `--state-dir`) emits
   exactly one `ELIGIBLE` line for `learnings-CLI.md#npm install strips peer
   markers` (count 4, tickets #50/#61/#63/#64). Verified during authoring.
2. **Trending preview** — the documented jq one-liner against the same fixture
   yields zero trending entries (the only sub-threshold entry,
   `pnpm lockfile conflicts with npm i`, has count 1 / 1 ticket, below the ≥2/≥2
   trending bar). The skill states this expected result so a reader can confirm
   the one-liner runs.
3. **No-match safety** — with an empty `repos.json`, the script logs a skip
   ("no single target repo … cross-cutting or unmatched") and exits 0 without
   side effects. Documented so operators don't mistake the skip for a failure.

## Risks / rollback

- **Risk:** the skill drifts from the script if `promote-citations.sh` changes
  its flags. **Mitigation:** the skill references the script by name and tells
  the reader to run `promote-citations.sh --help` for the authoritative flag
  set rather than duplicating the flag table.
- **Risk:** the worked example references the gitignored `.json` and breaks on a
  fresh checkout. **Mitigation:** the example targets the committed
  `state/memory-citations.example.json`, which always exists.
- **Rollback:** delete the skill directory. Promotion continues to run exactly
  as before (the script is untouched); the only loss is the preview workflow
  documentation.

## Implementation notes

(Fill in after the PR lands.)
