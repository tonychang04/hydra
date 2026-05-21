---
name: author-repo-skill
description: |
  Author a NEW Hydra repo-local skill under .claude/skills/<name>/SKILL.md. Use
  when a worker ticket asks to "add a skill", "seed a skill", or "promote this
  learning to a skill", or when steering #145's promotion pipeline as it
  scaffolds a SKILL.md from a cited learning. Teaches the canonical section
  template, the authoring checklist (~150-line ceiling, sibling-file split), the
  accept/reject review rubric (narrow action, testable example, no duplication of
  a gstack global), and how promotion-from-memory shapes a draft. .claude/skills/README.md
  is authoritative for the shape; this skill is its worked-example form. Skip for
  general (non-Hydra) skill authoring — that's gstack superpowers:writing-skills. (Hydra)
---

# Author a new Hydra repo-local skill

## Overview

`.claude/skills/*` are **worker-subagent skills** — reference procedures every
Hydra worker reads implicitly in Step 0 as repo context (the same way it reads
`CLAUDE.md`). They are NOT loaded as runtime tools, and they are NOT the
`skills:` YAML list in a `worker-*.md` agent frontmatter (that list is the plugin
loader for `superpowers:*` IDs — keep the two strictly separate, or repo-local
names fail lookup and are silently skipped). New skills arrive two ways:
hand-authored from a ticket, or auto-scaffolded by the #145 promotion pipeline
from a learning that crossed the 3×3 citation threshold. Either way the author
must hit the same shape, ceiling, and quality bar — this skill pins them so the
corpus doesn't drift.

`.claude/skills/README.md` is **authoritative** for the shape and authoring
checklist; this skill distills the procedure and adds the accept/reject rubric +
worked examples + promotion shaping. On disagreement, the README wins.

## When to Use

- A worker ticket asks to author/seed a `.claude/skills/*` skill in Hydra.
- You are steering #145's promotion pipeline and want to shape the scaffolded draft.
- You're reviewing a `commander-skill-promotion` PR and need the accept/reject rubric.

Skip when:
- Authoring a skill for a downstream InsForge repo → it goes in THAT repo's
  `.claude/skills/`, not Hydra's.
- Authoring a general-purpose developer-loop skill → reuse a gstack global; never
  re-author here (see rejection criterion 1).
- You want general skill-authoring craft → that's gstack `superpowers:writing-skills`.

## Process / How-To

### Canonical template (OMIT gstack's telemetry preamble)

Frontmatter: `name:` (MUST match the directory) + a one-paragraph `description:`
the loader matches against — include trigger phrases ("when a worker reports …")
and end it with `(Hydra)`. Then `# <Title>` and SIX H2 sections in this order:

- **Overview** — what it teaches + why; name the authoritative source it distills
  (policy.md, the README) and say that wins on conflict.
- **When to Use** — explicit triggers + a "Skip when" list.
- **Process / How-To** — numbered atomic steps the worker can execute.
- **Examples** — ≥1 good example (with output if relevant) + 1 common failure.
- **Verification** — how you confirmed it (offline: parser round-trip, grep, wc -l).
- **Related** — source-of-truth files, the spec, sibling skills.

The README §"Skill shape" carries the full annotated form — this is the skeleton.

### Authoring checklist (from README §"Authoring checklist")

1. **Name:** `kebab-case`, names the *action* (`worker-emit-memory-citations`,
   not `citations`). Directory and frontmatter `name:` must match.
2. Create `.claude/skills/<name>/SKILL.md` in the template shape above.
3. **Apply the review rubric below** — author only if it passes accept criteria.
4. **Verify it works:** procedural skill → write the "common failure" example and
   confirm the steps prevent it; format skill → round-trip the example through its
   canonical script (`worker-emit-memory-citations` runs `parse-citations.sh`).
5. **~150-line ceiling.** Over it → split: move reference material to a sibling
   (`examples.md`) and link it (see `commander-classify-tier`).
6. **Grep before PR:** `grep -ni skill memory/learnings-hydra.md memory/escalation-faq.md`
   — link or reconcile anything that duplicates/contradicts the new skill.
7. Write a dated spec `docs/specs/YYYY-MM-DD-<slug>.md` with the 3-field
   frontmatter (`status:` / `date:` / `author:`) or the `syntax` CI job reds.
   `git add -f` the new skill (global `~/.gitignore` matches `.claude/`).

### Review rubric — accept vs noise

**ACCEPT when ALL hold:** (a) it encodes a **narrow, repeatable action** specific
to Hydra's plumbing (memory citations, tier classification, rescue flow, PR-label
footgun); (b) it has a **testable worked example** (someone can run it and see the
pass); (c) it does **not duplicate** a gstack global or another repo-local skill.

**REJECT when ANY hold:**
1. **Duplicates a global.** Survey `~/.claude/skills/*` first — debug, review,
   ship, retro, QA, doc polish, security audit already exist there. A general
   developer-loop skill belongs in gstack; re-authoring it here is noise.
2. **Too narrow to be reusable.** A one-off that fires for a single ticket and
   never again isn't a skill — it's a comment. Needs a recurring trigger.
3. **Too broad to be testable.** "How to write good code" has no atomic Process
   and no worked example you can verify. If you can't write the Verification
   section, the scope is wrong — narrow it until you can.

### Promotion-from-memory shaping (#145 pipeline)

When `scripts/promote-citations.sh` scaffolds a SKILL.md from a learning that hit
3×3 citations, the draft is raw learning text — sharpen it before it lands:
distill the cited quote into a crisp Overview + Process, add the missing **When
to Use** / **Verification** sections, and run it through the rubric (often the
fix is narrowing scope). Note: `--dry-run` is only an *eligibility + target-repo*
preview — it does NOT re-read the learning or prove the scaffold, so verify the
cited quote still exists (`grep -F "<quote>" memory/learnings-<repo>.md`) and the
shape yourself. Promotion PRs are never auto-merged; they are scaffolds to refine.

## Examples

### Good — well-scoped skill that promotes cleanly

Learning "Labels on PRs always use the REST API; `gh pr edit --add-label` fails
with a Projects-classic deprecation," cited across 3+ tickets. Passes the rubric:
narrow action (apply a PR label), testable example (`gh api …/labels` succeeds
where `gh pr edit` errors), no global covers it. → author
`apply-label-via-rest/SKILL.md` (a real seed): Process gives the exact
`gh api --method POST …/labels` command, Examples shows the failing vs working
call, Verification runs it against a test PR. Lands as-is.

### Bad — too broad, reject with a rewrite suggestion

Proposed `handle-git-stuff`: "how to use git in a worktree — commits, rebases,
conflicts, pushes." → **REJECT (criterion 3, too broad; also criterion 1):** no
atomic Process, no single verifiable example, and it straddles gstack
`ship`/`finishing-a-development-branch`. **Rewrite:** narrow to the one recurring
Hydra footgun — the cwd-reset worktree hazard — as `worker-git-C-worktree`:
Process = "use `git -C "$WT"` for every op; assert branch before commit,"
Verification = `scripts/assert-worktree-branch.sh` exits 1 on mismatch. Now
narrow, testable, non-duplicative.

## Verification

This skill is a worked example of itself:

- **Shape:** six canonical sections in order (Overview → When to Use → Process →
  Examples → Verification → Related); `name:` matches the directory;
  `description:` ends in `(Hydra)`. Confirm: `grep -nE '^## ' SKILL.md`.
- **Ceiling:** `wc -l .claude/skills/author-repo-skill/SKILL.md` ≤ ~150.
- **Rubric self-application:** passes its own ACCEPT bar — narrow action (author a
  Hydra skill), testable example (the two worked cases), no global duplicate
  (gstack `superpowers:writing-skills` is general craft; this is Hydra shape +
  rubric, named in Related as the counterpart).
- **Non-contradiction:** the `.claude/skills/*`-vs-`skills:`-frontmatter line and
  the `--dry-run`-is-only-a-preview caveat match `memory/learnings-hydra.md`
  (#150, #180); nothing overrides the README or `memory-lifecycle.md`.

## Related

- `.claude/skills/README.md` — **authoritative** shape + authoring checklist; this
  skill distills it. On conflict, the README wins.
- `docs/specs/2026-04-17-skill-seed-list.md` (seed rank #7 justification) and
  `docs/specs/2026-05-21-skill-author-repo-skill.md` (this skill's spec).
- `commander-skill-promotion` + `scripts/promote-citations.sh` + `memory/memory-lifecycle.md`
  — the #145 promotion pipeline this skill shapes; 3×3 threshold lives there.
- `worker-emit-memory-citations`, `commander-classify-tier`, `classify-pr-for-review`,
  `write-hydra-readme` — sibling seeds; pattern-match against them for shape.
- gstack `superpowers:writing-skills` — general skill-authoring craft (the
  counterpart; this skill is the Hydra shape + rubric, not a re-author).
