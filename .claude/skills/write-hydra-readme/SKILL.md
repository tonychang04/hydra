---
name: write-hydra-readme
description: |
  Write the FIRST README for a fresh or bare InsForge-family downstream repo
  (CLI, SDK, MCP server, a new service) — NOT Hydra itself. Use when a worker
  ticket asks to "add a README", "document this repo", or "the repo has no
  README", and there is nothing to polish yet. Teaches the load-bearing
  section inventory (One-liner → Quick Start → Install → Usage → Develop →
  Links-back → License), audience-fit (SDK vs control-plane vs CLI), and a
  pre-commit checklist. This is the
  COMPLEMENT of gstack's `document-release`, which polishes an EXISTING README;
  reach for that instead when a README already exists. (Hydra)
---

# Write the first README for a downstream InsForge repo

## Overview

InsForge is ~8+ repos (see `memory/reference_insforge_repo_coordination.md`), and new
ones arrive bare. When a worker is asked to write a repo's *first* README, gstack's
`document-release` does not help — it reads and polishes docs that already exist. A bare
repo has nothing to polish; you must decide what sections matter, in what order, for that
repo's specific audience. Without a procedure, workers re-derive this each time and the
results drift (Quick Start buried, install command missing, no link back to the family).

This skill pins the load-bearing section spine, grounded in the structure shared by real
stable downstream READMEs (`CLI`, `InsForge-sdk-js`, `insforge` OSS, `insforge-cloud`,
`insforge-mcp`), so a worker writes the first README the same way every time.

## When to Use

- The repo has no `README.md` (or a one-line stub) and the ticket asks to write one.
- A new InsForge-family repo — CLI, SDK, MCP server, edge-function library, a service.
- You are inside a downstream repo, NOT Hydra itself (Hydra's own README is human-maintained).

Skip when:

- A real README already exists and the ticket is to update/sync it → use gstack
  `document-release` (polish existing; cross-refs the diff, syncs CHANGELOG voice).
- The target is Mintlify site content (`docs/*.mdx`, `docs.json`) → that's `doc-author`,
  a different audience and format, not a README.

## Process / How-To

1. **Identify the audience first** — it dictates the Quick Start. Three common shapes:
   - **End-user SDK / CLI / MCP** (`InsForge-sdk-js`, `CLI`, `insforge-mcp`): Quick Start is
     `npm install` / `npx` then a minimal authenticated call. Lead with the happy path.
   - **Self-hosted product** (`insforge` OSS): Quick Start is cloud-link first, then Docker Compose for self-host. Show both paths.
   - **Control-plane / internal** (`insforge-cloud`, `insforge-cloud-backend`): Quick Start
     is clone → `.env` from `.env.example` → run dev server. Add an Architecture/Tech-Stack
     section; contributors, not consumers, are the audience.

2. **Write the section spine in this order.** Each section earns its place — don't pad:

   | # | Section | Load-bearing because |
   |---|---|---|
   | 1 | **One-liner** | H1 = package/repo name; one sentence on what it is + who it's for. The reader decides in 5 seconds whether this is their repo. |
   | 2 | **Quick Start** | Shortest path zero → working call. Copy-pasteable. The single most-read block. |
   | 3 | **Install** | The canonical install command(s). Fold into Quick Start for tiny repos. |
   | 4 | **Usage** | Per-feature / per-command reference. Scales with surface area (a CLI needs many; a one-function lib needs little). |
   | 5 | **Develop** | clone → install deps → test → build. For contributors, not consumers. |
   | 6 | **Links back to the InsForge family** | "Related Repositories" + docs URL + community. The InsForge-specific section `document-release` won't think to add. |
   | 7 | **License** | Short, last. |

3. **Make Quick Start copy-pasteable and real.** Use fenced bash/ts blocks. Prefer commands
   you can actually run in the repo (read `package.json` scripts, `bin/`, `.env.example`).
   Never invent a flag — grep the source for the real command surface.

4. **Right-size Usage to the surface area.** A CLI lists its commands as `### subsections`
   (see `CLI`'s `### Database`, `### Storage`, `### Functions`). A small SDK groups by
   capability (`### Database Operations`, `### File Storage`). Don't document commands that
   don't exist; don't omit the ones that do.

5. **Always add the "links back" section.** Downstream repos are a family — point to the
   docs site, sibling repos, and community. This is the section that makes a bare repo feel
   part of InsForge rather than orphaned.

6. **Pre-commit checklist:** every command in Quick Start was verified against the repo's
   real scripts/bin; every linked sibling repo exists; the H1 names the actual package;
   no `TODO`/placeholder left. Then commit (`git add README.md`) and open the draft PR.

## Examples

### Good — end-user CLI (pattern from `CLI/README.md`)

```markdown
# @insforge/cli
Command-line tool to manage your InsForge projects from the terminal.

## Quick Start
    npx @insforge/cli login      # browser OAuth
    npx @insforge/cli projects   # list your projects
    npx @insforge/cli link       # link this dir to a project

## Commands
### Database — `npx @insforge/cli db` ...
### Storage  — `npx @insforge/cli storage` ...

## Development
    npm install && npm test && npm run build

## Related
- [OSS](https://github.com/InsForge/InsForge) · [SDK](https://github.com/InsForge/InsForge-sdk-js) · [Docs](https://docs.insforge.dev)
```

Mirrors the real `CLI/README.md` spine: one-liner → Quick Start → per-command Usage →
Development → links. Quick Start leads with `login` because nothing else works first.

### Good — end-user SDK (pattern from `InsForge-sdk-js/README.md`)

That README leads with `# insforge-sdk-js` → `## Features` → `## Installation`
(`npm install @insforge/sdk`) → `## Quick Start` (Initialize → Authentication → Database →
Storage) → `## Development` → `## Related Projects`. For a new SDK, copy that order —
capability-grouped Usage, not command-grouped, because an SDK's surface is methods not subcommands.

### Bad — what this skill prevents

```markdown
# my-repo
TODO: add description

## Setup
Run the thing.
```

No audience cue, no copy-pasteable Quick Start, no real commands, no link back to the
family, placeholder text. The spine in step 2 prevents every one of these gaps.

## Verification

The section inventory was derived by surveying the headings (`grep -E '^#{1,3} '`) of five
real, stable downstream READMEs and taking their common spine: `CLI` (Quick Start +
per-command Usage + Development), `InsForge-sdk-js` (Features + Installation + Quick Start +
Development + Related Projects), `insforge` OSS (Quickstart cloud+Docker + Docs + License),
`insforge-cloud` (Quick Start + Architecture + Related Repositories), `insforge-mcp` (Quick
Start + Development + License). All five lead with a one-liner H1 + Quick Start near the top
and end with links + License — the spine in step 2. To confirm an authored README conforms:
`grep -E '^#{1,2} ' README.md` should show the one-liner H1 first and a Quick Start within
the first few sections.

## Related

- gstack `document-release` — the counterpart skill: polishes an **existing** README +
  ARCHITECTURE/CHANGELOG against the diff. Use it when a README already exists; use THIS
  skill to write the first one.
- gstack `doc-author` — for Mintlify `.mdx` site docs (`InsForge/insforge` `docs/`), not READMEs.
- `memory/reference_insforge_repo_coordination.md` — the repo map + audience per repo
  (drives the audience-fit decision in step 1).
- `.claude/skills/README.md` — the seed-skill shape this file follows.
