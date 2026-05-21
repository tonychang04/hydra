---
status: proposed
date: 2026-05-21
author: hydra worker
ticket: 161
tier: T2
---

# Seed skill: `write-hydra-readme`

**Ticket:** [#161](https://github.com/tonychang04/hydra/issues/161)
**Implements seed rank #6** from `docs/specs/2026-04-17-skill-seed-list.md` (filed by PR #156 / issue #150).

## Problem

When a worker lands inside a **fresh or bare InsForge-family downstream repo** (CLI,
SDK, MCP server, a new microservice, etc.) it is sometimes asked to write the repo's
**first README**. There is no skill for this today.

The closest global skill, gstack's `document-release`, is the wrong tool: it *polishes
existing* docs (reads README/ARCHITECTURE/CHANGELOG, cross-refs the diff, syncs them).
It assumes a README already exists. A worker facing a bare repo has nothing to polish —
it must decide what sections are load-bearing, what order they go in, and what the
downstream repo's audience needs first. Workers re-derive this from scratch every time,
and the results drift (some skip Quick Start, some bury the install command, some forget
to link back to the InsForge family).

This is a recurring task because InsForge has ~8+ repos (`memory/reference_insforge_repo_coordination.md`)
and new ones arrive bare.

## Goals

- Author `.claude/skills/write-hydra-readme/SKILL.md` teaching a worker to write a
  first README for a downstream InsForge-family repo (NOT Hydra itself).
- Enumerate the load-bearing section inventory, the order, and *why* each section earns
  its place — grounded in the structure of real, stable downstream READMEs.
- Provide ≥2 worked examples referencing real downstream READMEs.
- Cross-link gstack's `document-release` as the "when the README already exists" counterpart.
- Keep `SKILL.md` under ~150 lines, matching the seed-skill shape in `.claude/skills/README.md`.

## Non-goals

- Authoring READMEs for Hydra itself (Hydra's README is human-maintained; `document-release`
  covers polishing it).
- A README *generator script*. This is a reference procedure a worker reads, not automation.
- Touching `.claude/skills/README.md` (the seed index — Commander reconciles it to avoid
  parallel-worker conflicts).
- Mintlify `.mdx` site docs (that's `doc-author`, a different audience/format).

## Proposed approach

A single `SKILL.md` matching the established seed shape (frontmatter `name` + multi-line
`description`; `## Overview`, `## When to Use`, `## Process / How-To`, `## Examples`,
`## Verification`, `## Related`). gstack telemetry preamble omitted per the repo convention.

**Section inventory** (the skill's core teaching), derived by surveying the headings of
five real downstream READMEs (`CLI`, `InsForge-sdk-js`, `insforge` OSS, `insforge-cloud`,
`insforge-mcp`). The common load-bearing spine, in order:

1. **One-liner** — H1 = package/repo name, then a single sentence saying what it is and
   who it's for. (Every surveyed README leads with this.)
2. **Quick Start** — the shortest path from zero to a working call. Copy-pasteable.
   (`CLI`, `SDK`, `insforge` OSS, `insforge-cloud`, `insforge-mcp` all have one near the top.)
3. **Install** — the canonical install command(s). May be folded into Quick Start for
   tiny repos.
4. **Usage** — the per-feature / per-command reference. Scales with surface area.
5. **Develop** — clone → install deps → test → build, for contributors.
6. **Links back to the InsForge family** — "Related Repositories" / docs URL / community.
   This is the InsForge-specific section `document-release` won't think to add.
7. **License**.

Plus guidance on audience-fit (end-user SDK vs internal control-plane backend vs CLI)
and what to verify before committing.

### Alternatives considered

- **Fold this into `document-release`** — rejected: that's a global gstack skill we don't
  own and shouldn't fork; the seed-list spec explicitly carved this out as the complement.
- **A README template file checked into the skill dir** — rejected for v1: the worked
  examples + section inventory carry the same information without implying a rigid
  one-size template (audiences differ enough that a fill-in-the-blanks template would
  mislead). Could add later if promotion data shows demand.

## Test plan

This is a documentation/reference skill, so "tests" = structural + content verification:

1. **Shape conformance:** `SKILL.md` has the frontmatter (`name`, `description`) and the
   five+ sections from the seed shape. Assert with grep.
2. **Line budget:** `wc -l` < ~150.
3. **Example fidelity:** every downstream README referenced in the Examples/Verification
   sections actually exists with the cited section, so the examples aren't fabricated.
4. **Cross-link present:** `document-release` named as the counterpart (AC #4).
5. **No duplication:** grep `memory/learnings-hydra.md` + `memory/escalation-faq.md` for
   README/doc content — confirmed none conflicts (the one faq hit is about test-discovery
   falling back to README, a different topic).

## Risks / rollback

- **Risk:** referenced downstream READMEs get restructured, making an example stale. Mitigated
  by citing *which* section (e.g. "CLI's `## Quick Start`") rather than line numbers, and by
  framing examples as patterns, not transcriptions.
- **Risk:** the skill drifts from the seed shape if the shape evolves. Low — the shape is
  pinned in `.claude/skills/README.md` and the other three seeds.
- **Rollback:** delete the `.claude/skills/write-hydra-readme/` directory. The skill is
  additive (workers read it as context); removing it reverts to re-derivation. No code
  depends on it.
