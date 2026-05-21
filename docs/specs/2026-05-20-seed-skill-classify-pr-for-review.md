---
status: proposed
date: 2026-05-20
author: hydra worker
ticket: 159
tier: T2
---

# Seed skill: `classify-pr-for-review`

**Ticket:** [#159](https://github.com/tonychang04/hydra/issues/159) — seed rank #4 from `docs/specs/2026-04-17-skill-seed-list.md`.

## Problem

`worker-review` decides what to look at in a PR diff every time it runs, but the
logic lives as inline prose in `.claude/agents/worker-review.md` ("Inputs
expected", flow steps 2-7, the security-adjacent definition repeated in two
places). Three problems follow:

1. **Variance.** Each review worker re-derives "which files matter, which are
   noise, when do I trigger `/cso`" from prose. Reviewers disagree on whether a
   lockfile churn or a generated snapshot deserves a comment.
2. **No worked examples.** The agent file says "true if diff touches `*auth*`,
   `*security*`, `*crypto*`, migrations" but never shows a diff that should vs
   should not trip the trigger. Edge cases (a test fixture named `auth_test.go`,
   a doc that merely mentions auth) get mis-classified.
3. **No testable artifact.** Prose can't be pressure-tested. A skill with a
   decision table + worked examples can.

The seed-list spec ranks this #4: "Reduces review-worker variance. Currently
lives as prose in `.claude/agents/worker-review.md`; extracting gives it test
cases and examples."

## Goals

- Author `.claude/skills/classify-pr-for-review/SKILL.md` codifying diff scoping
  for `worker-review`: include / exclude / security-trigger.
- Provide an explicit decision table: file-path glob → `include` / `exclude` /
  `security-trigger`.
- Provide a review-comment template matching the structure
  `.claude/agents/worker-review.md` already expects (Blockers / Concerns / Nits,
  `SECURITY:` prefix, Signed-off-by).
- Extract the duplicated prose from `.claude/agents/worker-review.md` and replace
  it with a one-line pointer (acceptance criterion #5).
- Keep SKILL.md under ~150 lines.

## Non-goals

- Do NOT change `worker-review`'s actual flow, tools, or hard rules — only
  extract the *scoping* prose into the skill and point at it.
- Do NOT re-author what gstack `/review`, `/codex`, or `/cso` already do. The
  skill orchestrates them; it does not reimplement them.
- Do NOT touch `CLAUDE.md` (Commander rails) — out of scope, and the
  coordinate-with hint forbids it.
- Do NOT modify `.claude/skills/README.md` — siblings #3/#5 added their dirs
  without touching it, and #157 is concurrently editing the skills tree;
  appending risks a needless merge conflict. The README already documents the
  generic skill shape; it is not a per-skill index.

## Proposed approach

Mirror the established seed shape exactly (read from `apply-label-via-rest`,
`worker-resume-from-rescue`, `worker-emit-memory-citations`): YAML frontmatter
with a multi-line `description: |` ending in `(Hydra)`, then `# Title`,
`## Overview`, `## When to Use`, `## Process / How-To`, `## Examples` (Good /
Bad worked cases), `## Verification`, `## Related`. Omit the gstack telemetry
preamble per `.claude/skills/README.md` § "Skill shape".

The skill's substance is **extracted from**, and must not contradict,
`.claude/agents/worker-review.md` flow steps 2-7 and the existing memory:

- Security-adjacent definition: `*auth*`, `*security*`, `*crypto*`, migrations
  (verbatim from worker-review.md line 26 and the worker-implementation hard
  rule at line 149).
- "Spotted a bug as a reviewer → flag, don't fix" → link
  `escalation-faq.md` "I'm a review worker but spotted a bug".
- Security blocker escalation → link `escalation-faq.md` "My review found a
  security issue" (REQUEST_CHANGES + `SECURITY:` + `commander-stuck`).
- `/cso` blocker is a supervisor-loop trigger → link `escalation-faq.md`
  "A `/cso` review finds a blocker".
- Pre-existing baseline lint and lockfile drift are noise to a reviewer the same
  way they're out-of-scope to an implementer → link the two `escalation-faq.md`
  entries.

Then edit `.claude/agents/worker-review.md`: collapse the scoping detail in steps
2-3 and the duplicated security-adjacent definition into a one-line pointer to
the skill, leaving the flow intact.

### Alternatives considered

- **Leave the prose in worker-review.md, add a thin skill that just links.**
  Rejected: acceptance criterion #5 explicitly requires extracting the
  duplicated prose and leaving a pointer; a thin skill duplicates rather than
  extracts.
- **Put the decision table in CLAUDE.md.** Rejected: CLAUDE.md scope rule
  (routing + rails only) and the coordinate-with hint both forbid it.

## Test plan

Skills are reference docs, not executable code, so "tests" = structural +
content verification (mirrors how `worker-emit-memory-citations` verifies):

1. **Shape check:** SKILL.md has the seven canonical sections in order; frontmatter
   `name:` matches the directory; `description:` ends in `(Hydra)`.
2. **Size gate:** `wc -l` under ~150.
3. **Decision-table completeness:** the table classifies every category named in
   the ticket scope (source, tests, specs; lockfiles, generated, snapshots,
   `dist/`; `*auth*`, `*crypto*`, migrations).
4. **Worked-example coverage (Memory Brief requirement):** at least one diff that
   SHOULD trigger `/cso` (auth/SQL/secrets), one that should NOT, and one
   files-to-ignore-as-noise example.
5. **Non-contradiction:** grep `escalation-faq.md` + `learnings-hydra.md`; every
   overlapping rule is linked, none contradicted.
6. **Pointer integrity:** `worker-review.md` still describes the full flow and now
   points at the skill; no flow step deleted.

## Risks / rollback

- **Risk:** drift between the skill and worker-review.md if one changes later.
  *Mitigation:* worker-review.md keeps a single pointer line; the skill is the
  single source of scoping truth, so there's one place to edit.
- **Risk:** merge conflict with #157 (concurrent skills-tree work).
  *Mitigation:* only create my own directory; do not touch README.md or shared
  files.
- **Rollback:** revert the PR. The skill is additive; the worker-review.md edit
  is a prose collapse with a pointer — reverting restores the original prose.
  No runtime behavior depends on the file (workers read it as context).
