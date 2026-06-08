---
name: using-hydra-skills
version: 1.0.0
description: |
  The Hydra worker skill dispatcher — read this FIRST in Step 0, before
  touching any code or emitting any QUESTION. Establishes the rule: before
  acting, enumerate `.claude/skills/*`, match your task against each skill's
  `description`, and READ any skill with even a 1% chance of applying. Use
  when starting ANY worker ticket (implementation, review, test-discovery,
  conflict-resolver, auditor, codex-implementation). Teaches how Hydra skills
  differ from gstack/superpowers runtime skills (these are Step-0 *context
  reads*, not `Skill`-tool invocations) and how to pick the right one. (Hydra)
---

# Using Hydra Skills

## Overview

Hydra ships a set of **repo-local worker skills** under `.claude/skills/*`.
Each one is a distilled, load-bearing procedure — usually either a hand-authored
seed (#150) or a memory entry that was cited 3+ times and promoted (#145). They
exist so a worker does not re-derive (or mis-derive) a procedure another worker
already paid for. This skill is the **dispatcher**: it tells you to actively
check for an applicable skill before you act, the same way superpowers'
`using-superpowers` does for the Main Agent.

**Hydra skills are NOT runtime `Skill`-tool invocations.** Unlike gstack /
superpowers skills (which you load with the `Skill` tool), repo-local Hydra
skills are read as **Step-0 context** — you open `.claude/skills/<name>/SKILL.md`
with the Read tool, the same way you read `CLAUDE.md` and `AGENTS.md`. See
`.claude/skills/README.md` for the audience split.

## The Rule

<EXTREMELY-IMPORTANT>
Before acting on your ticket, if there is even a **1% chance** a Hydra skill
applies to what you are about to do, READ it. If a skill applies, you do not
have a choice — follow it. This is not optional; it is how Hydra stays
consistent worker-to-worker.
</EXTREMELY-IMPORTANT>

If, after reading, the skill turns out not to fit your situation, you don't
have to use it — but you must have checked.

## When to Use

- At the very start of EVERY worker ticket, as part of Step 0, before code,
  before a `QUESTION:` block, before running tests.
- Whenever you are about to perform an action that smells like a recurring
  Hydra operation: applying a label, emitting memory citations, resolving a
  conflict, classifying a tier, reviewing a PR diff, resuming a rescued branch,
  authoring a new skill, writing a downstream repo's README.

## Process

1. **Enumerate the directory.** `ls .claude/skills/` — every subdirectory is a
   skill; `README.md` is the contract, not a skill.
2. **Read each candidate's `description`.** `head` the frontmatter of each
   `SKILL.md`, or scan the descriptions. The `description` field names the exact
   trigger conditions ("Use when …"). Match it against your task.
3. **Open any skill with ≥1% relevance.** Read the full `SKILL.md` with the Read
   tool. Do this BEFORE acting — a skill tells you HOW to do the thing, so
   reading it after you've already acted defeats the purpose.
4. **Follow it.** If the skill is rigid (it says "ALWAYS" / "NEVER"), obey
   exactly. If it's a flexible pattern, adapt it. The skill states which.
5. **Compose with global skills.** You also have gstack/superpowers skills via
   the `Skill` tool. Priority when a pattern could live in either: general
   developer loop (debug, review, ship, QA) → use the global skill; Hydra
   plumbing (citations, tiers, rescue, label footgun) → use the repo-local
   skill here. (`.claude/skills/README.md` § "Composition".)

## Current Hydra skills (read the live `description`s, not this stale list)

This roster is a convenience pointer only — the directory is the source of truth:

- `apply-label-via-rest` — every PR/issue label transition (REST, never `gh pr edit`)
- `worker-emit-memory-citations` — `MEMORY_CITED:` markers at end of a worker report
- `worker-resume-from-rescue` — picking up a `commander-rescued` branch
- `classify-pr-for-review` — scoping a diff before `/review`
- `respond-to-review` — processing review-gate findings on a re-spawn (verify before implementing)
- `commander-classify-tier` — T1/T2/T3 tiering per `policy.md`
- `commander-skill-promotion` — previewing/steering the promotion pipeline
- `author-repo-skill` — authoring a NEW repo-local skill
- `write-hydra-readme` — first README for a downstream InsForge-family repo

## Red Flags — STOP, you're rationalizing

| Thought | Reality |
|---|---|
| "This is a simple ticket, I don't need to check skills" | Simple tickets have skills too (labels, citations). Check. |
| "I'll just apply the label real quick" | `apply-label-via-rest` exists because the quick way is a footgun. |
| "I remember how citations work" | Skills evolve; the format is in `worker-emit-memory-citations`. Read it. |
| "Let me explore the code first" | The dispatcher read is part of Step 0, before exploration. |
| "No skill could possibly apply here" | Enumerate the directory before concluding that. |

## Verification

- This skill is itself discoverable: `ls .claude/skills/` shows `using-hydra-skills/`.
- Worker agent Step-0 sections point at it (grep `.claude/agents/worker-*.md`
  for `using-hydra-skills`).
- A worker who follows it will have opened `apply-label-via-rest` *before*
  applying any label — the canonical proof the dispatcher did its job.
