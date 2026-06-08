---
status: draft
date: 2026-06-07
author: hydra worker (ticket #275)
---

# Seed skill: `respond-to-review` — verify-before-implementing review feedback

## Problem

Hydra's review gate (`worker-review` → `worker-validator`) re-spawns
`worker-implementation` with review feedback when it finds blockers (CLAUDE.md
§ "Commander review gate", max 2 cycles). The re-spawned worker has two failure
modes when it processes that feedback:

1. **Blind implementation** — it treats each finding as an order and implements
   it verbatim, without checking whether the suggestion is technically correct
   *for this codebase*, whether it breaks existing tests, or whether the current
   implementation exists for a legacy reason that still holds. This is the exact
   "changes land in weird ways without project context" failure the operator
   flagged (`memory/feedback_context_and_testing_weakness.md`).
2. **Reflexive over-defense** — it argues against valid findings without first
   verifying them against the codebase, burning a review cycle on social
   friction instead of a fix.

There is no Step-0 skill teaching the worker the disciplined middle path:
restate → verify-against-codebase → respond (impl plan *or* reasoned pushback
with evidence). superpowers ships `receiving-code-review` for the Main Agent,
but it is a runtime `Skill`-tool skill with gstack-/CLAUDE.md-specific framing
("your human partner", "Strange things are afoot at the Circle K"), not a Hydra
Step-0 context read adapted to the review-gate re-spawn loop.

## Goals

- Add `.claude/skills/respond-to-review/SKILL.md`: a Step-0 worker skill that
  fires when a worker is re-spawned with review feedback, teaching a per-finding
  protocol — (1) restate the technical requirement, (2) verify it against THIS
  codebase (breaks tests? legacy reason still holds? reviewer has full context?),
  (3) respond with an implementation plan OR reasoned pushback backed by evidence.
- Mirror the existing Hydra skill format exactly (`name`/`version`/`description`
  frontmatter, six H2 sections, <=150 lines, `description` ends `(Hydra)`).
- Make it discoverable so a re-spawned worker matches and reads it in Step 0.

## Non-goals

- Editing `worker-implementation.md`, `CLAUDE.md`, `README.md`, or
  `worker-review.md` — those are owned by other workers (per the ticket's
  COORDINATE-WITH). Any Step-0 wiring those files need is noted in the PR body.
- Re-authoring superpowers `receiving-code-review` wholesale. We adapt its
  3-gate response pattern to Hydra's review-gate loop and drop the
  gstack-/CLAUDE.md-specific framing.
- Changing the review gate itself or `scripts/revalidate-contract.sh`.

## Proposed approach

Author one hand-authored seed skill, following `author-repo-skill/SKILL.md` and
`.claude/skills/README.md` (authoritative for shape). The skill distills
superpowers `receiving-code-review` into Hydra's vocabulary:

- "your human partner" / "external reviewer" → "the Hydra review gate
  (`worker-review` / `worker-validator`)", an *automated* reviewer the worker
  should treat skeptically-but-carefully (verify, don't blind-implement, don't
  reflexively defend).
- The 3-gate response pattern becomes a numbered per-finding Process the worker
  runs against the review feedback in its re-spawn prompt.
- Examples cover the two failure modes (blind-implement, over-defend) plus the
  correct verify-then-respond path, grounded in a Hydra-shaped finding.

**Discoverability.** Hydra skills have no manifest file — the directory IS the
source of truth and the dispatcher (`using-hydra-skills/SKILL.md`) explicitly
tells workers to enumerate `.claude/skills/*` and match each `description`
("read the live `description`s, not this stale list"). So the new skill is
discoverable the moment its directory exists. The dispatcher carries a
*convenience* roster (its "Current Hydra skills" list) that is explicitly marked
stale; per the ticket's COORDINATE-WITH ("you may add ONE line to the skill
enumeration if there's a manifest"), we add one roster line there so the
convenience pointer stays current. We do NOT touch the four files other workers
own.

### Alternatives considered

- **Edit `worker-implementation.md`'s Step-0 list to point at the new skill.**
  Rejected: that file is owned by another worker (COORDINATE-WITH). The
  dispatcher's enumerate-and-match mechanism already makes the skill
  discoverable without it; any further wiring is noted in the PR body.
- **Create a manifest file.** Rejected: there is no manifest pattern in Hydra;
  the directory is authoritative by design. Adding one would be a new mechanism,
  out of scope.

## Test plan

Offline, no network (matches sibling seeds' Verification sections):

- **Shape:** `grep -nE '^## ' SKILL.md` → six sections in canonical order;
  frontmatter `name:` matches the directory; `version: 1.0.0`; `description`
  ends `(Hydra)`.
- **Ceiling:** `wc -l SKILL.md` <= ~150.
- **Discoverability:** `grep -rl respond-to-review .claude/skills/` returns the
  new file AND the dispatcher roster line — a re-spawned worker enumerating the
  directory would surface it.
- **No duplication/contradiction:** `grep -ni 'respond-to-review\|review feedback'
  memory/learnings-hydra.md memory/escalation-faq.md` — link or reconcile hits.

## Risks / rollback

Low risk: additive, a single new skill directory plus one convenience-roster
line. No code paths change. Rollback = delete the directory and revert the
one-line roster edit. The only judgment call is editing the dispatcher's roster
list; it is explicitly a stale convenience pointer (not a load-bearing manifest),
and the ticket's COORDINATE-WITH permits one enumeration line.
