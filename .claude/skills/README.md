# Hydra repo-local worker skills

This directory holds **worker-subagent skills** — reference procedures that every Hydra worker (`worker-implementation`, `worker-review`, `worker-test-discovery`, `worker-conflict-resolver`, `worker-auditor`, `worker-codex-implementation`) reads implicitly as part of Step 0:

> `3. .claude/skills/* in the worktree (if present) — repo-specific skills`

Workers do NOT load these as runtime tools. They read them as repo context, the same way they read `CLAUDE.md` and `AGENTS.md`.

**Not to be confused with** `skills/` at the repo root, which holds **Main-Agent skills** (installed into `~/.claude/skills/` by the operator). See `../../skills/README.md` for that audience.

## How skills land here

Two paths:

### 1. Hand-authored seeds (rare, one-time bootstrap)

Ticket [#150](https://github.com/tonychang04/hydra/issues/150) seeds this directory with 5-10 skills covering patterns that are specific to Hydra and have no analogue in `~/.claude/skills/*` (the gstack globals). The seed list and justifications are in:

- `docs/specs/2026-04-17-skill-seed-list.md`

After the seed set lands, hand-authoring new skills should be rare. Most new entries arrive via path 2.

### 2. Promotion from memory (the normal path)

`memory/memory-lifecycle.md` defines a promotion loop: when a memory entry in `memory/learnings-<repo>.md` is cited 3+ times across 3+ distinct tickets (via `MEMORY_CITED:` markers), Commander opens a PR adding a skill here and labels it `commander-skill-promotion`. Issue [#145](https://github.com/tonychang04/hydra/issues/145) tracks the pipeline itself.

A promoted skill is the distilled form of a learning that has proven load-bearing across workers. Once it's here, the memory entry is annotated with `→ promoted to .claude/skills/<name>.md in PR #N on YYYY-MM-DD`.

## Composition with global (`~/.claude/skills/*`) skills

Workers have access to both sets. The priority when a pattern could live in either:

| If the pattern is… | It belongs in… |
|---|---|
| General-purpose developer loop (debug, review, ship, retro, QA) | `~/.claude/skills/*` — reuse gstack. Never re-author here. |
| Specific to Hydra's plumbing (memory citations, tier classification, rescue flow, PR labeling footgun) | `.claude/skills/<name>/` here. |
| Specific to a downstream InsForge-family repo (ONLY when working inside that repo) | `.claude/skills/*` inside THAT repo, not this one. |

See the seed-list spec for the specific reusability-survey that drove the seed set.

## Skill shape

Adopted from the Anthropic/Claude Code skill format used by superpowers:

```markdown
---
name: <kebab-name>
description: |
  One paragraph. Claude's skill loader matches against this, so be precise
  about triggers. Include phrase patterns ("when a worker reports ...",
  "before emitting ..."). (Hydra)
---

# <Skill Title>

## Overview
One paragraph: what the skill teaches and why a worker needs it.

## When to Use
Bullet list of explicit trigger conditions.

## Process / How-To
Numbered steps. Each step is an atomic action the worker can execute.

## Examples
- Good example (with expected output if relevant)
- Common failure (what the skill prevents)

## Verification
How the author confirmed the skill works. Often: "pass through a canonical
script and assert output", or "compare before/after a pressure test".
```

Gstack adds a bash preamble for telemetry / update-check. We intentionally OMIT it: Hydra workers run in isolated worktrees with no telemetry surface, and the preamble would add noise to every skill read.

## Authoring checklist (for new skills)

1. Pick a name: `kebab-case`, specific, describes the action (`worker-emit-memory-citations`, not `citations`).
2. Create `.claude/skills/<name>/SKILL.md` matching the shape above.
3. Verify the skill is correct:
   - For procedural skills: write the "common failure" example and confirm the skill's steps prevent it.
   - For format skills (like `worker-emit-memory-citations`): run the canonical parser against the skill's own example. If `jq '.citations | length' > 0` passes, the example is valid.
4. Keep under ~150 lines per SKILL.md. If longer, split into multiple skills or move reference material into sibling files (e.g. `examples.md`, `verify.sh`).
5. Before opening a PR, grep `memory/learnings-hydra.md` and `memory/escalation-faq.md` for content that duplicates or contradicts the new skill. Link or reconcile.

## Promotion from memory (mechanical)

When `#145` promotes a memory entry:

1. The promotion worker reads `memory/learnings-<repo>.md` and `state/memory-citations.json`.
2. For each entry with `count >= 3` across 3+ tickets, it drafts a `SKILL.md` using the shape above. The learning's distilled form becomes the Overview + Process.
3. PR is labeled `commander-skill-promotion`.
4. On merge, the memory entry is annotated (not deleted).

See `memory/memory-lifecycle.md` for the authoritative rules.

## Seed contents at bootstrap (ticket #150)

Only one seed lands with #150: `worker-emit-memory-citations/`. The other six are follow-up tickets filed by PR #150. See the seed-list spec for the full plan.
