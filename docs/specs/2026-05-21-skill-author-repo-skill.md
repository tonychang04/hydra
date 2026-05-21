---
status: draft
date: 2026-05-21
author: hydra worker (ticket #162)
---

# Seed skill: `author-repo-skill` (meta)

**Ticket:** [#162](https://github.com/tonychang04/hydra/issues/162)
**Implements seed rank #7** from `docs/specs/2026-04-17-skill-seed-list.md` (row #7 of the Proposed seed list — the LAST seed, picked up only after a corpus exists).

## Problem

`.claude/skills/` now holds a real corpus (the five named seeds plus
`apply-label-via-rest` and `worker-resume-from-rescue`). New entries arrive two
ways: (1) hand-authored, when a worker ticket asks for one; (2) auto-scaffolded
by the #145 promotion pipeline (`scripts/promote-citations.sh`) from a learning
that crossed the 3×3 citation threshold. In both cases the author has to
re-derive *what a good Hydra skill looks like*: the seven-section shape, the
~150-line ceiling, the sibling-file split, the "is this even worth a skill?"
rubric, and how a raw promotion scaffold gets sharpened into a landable skill.

The shape rules live in `.claude/skills/README.md` and the seed-list spec, but
they are scattered (shape here, checklist there, promotion mechanics in
`memory/memory-lifecycle.md`) and carry no worked examples of acceptance vs
rejection. That re-derivation drifts: skills that duplicate a gstack global get
authored anyway, too-narrow one-offs get promoted, and the seven-section order
slips. The seed-list spec ranks this meta-skill #7 / last precisely because it
is the force-multiplier that only pays off once there is a corpus to
pattern-match against — and now there is.

`.claude/skills/README.md` stays authoritative for the shape and the
authoring checklist (the ticket forbids editing it; Commander reconciles the
seed index). This skill is its distilled, worked-example form: it pins the
*procedure* and adds the accept/reject rubric + worked examples + the
promotion-from-memory shaping flow, then links back to the README as source of
truth. When this skill and the README disagree, the README wins and this skill
is the bug — same authoritative-source contract `commander-classify-tier` keeps
with `policy.md`.

## Goals

- A new `.claude/skills/author-repo-skill/SKILL.md` that follows the exact shape
  it documents (meta: it is a worked example of itself).
- Carry the canonical template, the authoring checklist, and a **review rubric**
  (accept-worthy vs noise) with explicit rejection criteria.
- At least two worked examples: (a) a well-scoped skill that promotes cleanly;
  (b) a too-broad skill that should be rejected with a rewrite suggestion.
- A Verification section with a worked example (offline-checkable).
- Document how #145's promotion-from-memory pipeline feeds new skills and how to
  shape the resulting scaffold.
- SKILL.md under ~150 lines.

## Non-goals

- Editing `.claude/skills/README.md` (the seed index) — Commander reconciles it.
- Touching CLAUDE.md, agent defs, `scripts/promote-citations.sh`, or other
  workers' files.
- Re-stating gstack's general `superpowers:writing-skills` skill — that covers
  authoring skills *in general*; this is Hydra-repo-specific shape + rubric.
- An automated skill-linter in `self-test/` (no harness rung exists yet; verify
  against the skill's own examples + the README, as the other seeds do).

## Proposed approach

Pattern-match against the five named seeds + `.claude/skills/README.md`.
Distill their common skeleton:

1. YAML frontmatter: `name:` (matches dir), `description:` (one paragraph,
   trigger phrases, ends `(Hydra)`).
2. Six H2 sections in fixed order: **Overview → When to Use → Process / How-To →
   Examples → Verification → Related** — the README template's five core sections
   plus the `## Related` section the existing seed corpus all carry by convention
   (Examples holds the worked cases; Process holds the checklist + rubric).
3. ~150-line ceiling; sibling files (`examples.md`) for overflow.
4. OMIT the gstack telemetry preamble (README §"Skill shape" says so).

Content blocks unique to this meta-skill: (a) the canonical template verbatim;
(b) the authoring checklist (from README §"Authoring checklist"); (c) the
review rubric — accept criteria + three rejection criteria (duplicates a global,
too narrow, too broad/untestable); (d) the promotion-from-memory shaping flow,
grounded in `commander-skill-promotion` + `memory/memory-lifecycle.md` and the
#180 learning that `--dry-run` is only an eligibility preview.

**Alternative considered — point at the README and add nothing.** Rejected: the
README has no accept/reject rubric and no worked examples, which are exactly
acceptance criteria #2 and #3. A pointer-only file would not be a usable skill.

**Alternative considered — split rubric into a sibling `examples.md`** (as
`commander-classify-tier` does). Rejected for v1: the content fits under ~150
lines inline, and a single self-contained file is easier to read for a
meta-skill whose whole point is to be exemplary. Revisit if it grows.

## Test plan

- **Shape:** seven canonical sections in order; `name:` matches the directory;
  `description:` ends in `(Hydra)`; `wc -l SKILL.md` ≤ ~150.
- **Acceptance criteria coverage:** the file documents the README shape (AC#1);
  has ≥2 worked examples — one clean-promote, one reject-with-rewrite (AC#2);
  states the three rejection criteria — duplicates a global, too narrow, too
  broad/untestable (AC#3); is ≤150 lines (AC#4).
- **Non-contradiction:** grep `memory/learnings-hydra.md` + `memory/escalation-faq.md`
  for skill/promotion content; reconcile the `.claude/skills/*` vs `skills:`
  frontmatter distinction (learnings #150) and the `--dry-run` caveat (#180).
- **Spec frontmatter:** `bash .github/workflows/scripts/syntax-check.sh` prints
  `syntax-check: OK` (offline; per learnings #201 every spec needs the 3-field
  block).

## Risks / rollback

- **Risk:** the skill drifts from the README it distills. *Mitigation:* the skill
  declares the README authoritative and links to it; the Related section names it.
- **Risk:** the meta-skill duplicates gstack's `superpowers:writing-skills`.
  *Mitigation:* the skill explicitly scopes itself to Hydra-repo shape + rubric
  and names the global as the general counterpart (the same "duplicates a global"
  trap it teaches authors to avoid).
- **Rollback:** the skill is a single new directory plus this spec. Reverting the
  PR removes both with no behavioral coupling — nothing imports or executes the
  skill (it is read implicitly as Step-0 context, not loaded as a tool).
