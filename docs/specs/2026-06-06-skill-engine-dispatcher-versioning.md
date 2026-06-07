---
status: accepted
date: 2026-06-06
---

# Skill engine: `using-hydra-skills` dispatcher + skill version frontmatter

**Ticket:** [#241](https://github.com/tonychang04/hydra/issues/241) — `[P2] Skill engine: using-hydra-skills dispatcher + version frontmatter (superpowers-grade)`
**Tier:** T2
**Date:** 2026-06-06

## Problem

Hydra's memory→skill promotion pipeline works (`scripts/promote-citations.sh`, `memory/memory-lifecycle.md`), but the skill *layer* is not yet a professional "skill engine" comparable to Anthropic's superpowers plugin. Two concrete gaps from the 2026-06-06 survey:

1. **No dispatcher / discovery.** Workers read `.claude/skills/*` implicitly as Step-0 reference material. There is no `using-superpowers`-style dispatcher skill that says "before acting, if there is even a 1% chance a Hydra skill applies, read it." Without it, a worker can skim past a directly relevant skill (e.g. `apply-label-via-rest`, `worker-emit-memory-citations`) and re-derive — or worse, mis-derive — the procedure. (cf. `superpowers/using-superpowers/SKILL.md`.)

2. **No versioning / provenance.** `.claude/skills/*/SKILL.md` carry no `version:` frontmatter and no per-skill provenance. Auto-promoted skills carry no marker of *where they came from* or *which revision they are*, so a worker cannot tell a stale skill from a current one, and an operator reviewing a promotion PR cannot see at a glance that the body was machine-scaffolded. (`.claude/skills/README.md` skill-shape section; `scripts/promote-citations.sh` `build_skill_body`.)

## Goals

- Add a `using-hydra-skills` dispatcher skill modeled on superpowers' dispatcher, adapted to Hydra's worker context (Step-0 reference-read model, not the runtime `Skill` tool).
- Reference the dispatcher from the Step-0 sections of the worker agent definitions (`.claude/agents/worker-*.md`) — **not** from `CLAUDE.md`.
- Add `version:` (semver) frontmatter + a `## Promoted from memory` provenance section to the promoted-skill template in `scripts/promote-citations.sh`'s `build_skill_body`.
- Backfill every existing `.claude/skills/*/SKILL.md` with `version: 1.0.0`.
- Document the updated skill-shape contract (version field + provenance section) in `.claude/skills/README.md`.

## Non-goals

- No changes to `CLAUDE.md`, `scripts/autopickup-tick.sh`, or `docs/specs/2026-06-06-autopickup-tick-orchestrator.md` — a sibling worker (#239) owns those.
- No per-skill changelog files (the `version:` field + provenance section are enough for v1; a CHANGELOG per skill is YAGNI until skills actually iterate).
- No automatic version bumping on promotion re-runs (the citation-block splice path already preserves operator edits; bumping semver mechanically is out of scope and would fight operator edits).
- No new CI gate asserting every skill has a `version:` (could be a follow-up; v1 documents the contract, backfills, and the test harness greps for it).

## Proposed approach

### 1. Dispatcher skill `.claude/skills/using-hydra-skills/SKILL.md`

Mirror superpowers' `using-superpowers` frontmatter (`name`, `description`) and dispatcher tone, adapted:

- Hydra workers do **not** load these via the `Skill` tool — they read them as Step-0 context (per `.claude/skills/README.md`). So the dispatcher instructs: *enumerate the skill directory, match your task against each skill's `description`, and READ (open) any skill with ≥1% chance of applying before acting.*
- Carry the new `version: 1.0.0` frontmatter (it is itself a skill, so it must obey the contract it documents).
- Keep under ~150 lines per the authoring checklist.

**Alternative considered:** make the dispatcher a Main-Agent skill under repo-root `skills/`. Rejected — the audience is *workers* reading repo-local `.claude/skills/*`, which is exactly the `.claude/skills/` directory per the README's audience split.

**Relation to `author-repo-skill`:** that skill teaches how to *author* a new skill; the dispatcher teaches how to *discover and use* existing skills. Disjoint purposes; both reference each other.

### 2. Reference from worker agent Step-0 sections

Edit the Step-0 skill-read line in each worker agent that has one (`worker-implementation`, `worker-codex-implementation`, `worker-review`, `worker-conflict-resolver`, `worker-auditor`) to point at `using-hydra-skills` as the dispatcher entrypoint. The line already says "read `.claude/skills/*`"; we add the dispatcher pointer so the read is directed, not incidental.

### 3. `version:` + provenance in `build_skill_body`

In `scripts/promote-citations.sh`:
- Add `version: 1.0.0` to the emitted frontmatter (every freshly-promoted skill starts at 1.0.0).
- Add a `## Promoted from memory` section carrying the source file, quote, citation count, and promotion date — distinct from the existing `## Citations` block (which is the machine-spliced, idempotently-rewritten cohort list). Provenance is *why this skill exists*; Citations is *the live citation tally*.

The existing idempotent-update path (splice citations block only) is unchanged: re-promotion of an existing skill still rewrites only the markered Citations block and leaves frontmatter + provenance intact (matching the README guarantee that operator edits outside the markers are preserved).

### 4. Backfill existing skills

Add `version: 1.0.0` to the frontmatter of all existing `.claude/skills/*/SKILL.md` (after `name:`, before `description:`), the dispatcher included.

### 5. README contract update

Document in `.claude/skills/README.md`:
- `version:` (semver) is a required frontmatter field; new hand-authored skills start at `1.0.0`.
- Promoted skills carry a `## Promoted from memory` provenance section.
- The dispatcher (`using-hydra-skills`) is the entrypoint workers read first.

## Test plan

- **`scripts/test-promote-citations.sh`** — the existing regression harness (8 dry-run tests) must stay green. Add a focused test that runs `build_skill_body` (by sourcing the function with `--dry-run`-safe guards, or by invoking the generator directly) and asserts the output contains `version: 1.0.0` and `## Promoted from memory`.
- **Frontmatter validity** — grep every `.claude/skills/*/SKILL.md` for `^version:` and assert all carry it (added as a test case).
- **Manual**: confirm the dispatcher skill has valid `name` + `description` + `version` frontmatter and is < 150 lines.

## Risks / rollback

- **Risk:** editing `build_skill_body` breaks the heredoc / existing tests. Mitigation: run `scripts/test-promote-citations.sh` before and after.
- **Risk:** touching files the sibling worker (#239) owns. Mitigation: hard-avoid `CLAUDE.md`, `scripts/autopickup-tick.sh`, `docs/specs/2026-06-06-autopickup-tick-orchestrator.md`. File set here is disjoint.
- **Rollback:** revert the PR. No state migration, no runtime coupling — skills are read-only context and the promote-citations change only affects *future* promotions' frontmatter.

## Files touched

- Create: `.claude/skills/using-hydra-skills/SKILL.md`
- Create: `docs/specs/2026-06-06-skill-engine-dispatcher-versioning.md` (this file)
- Modify: `scripts/promote-citations.sh` (`build_skill_body`)
- Modify: `scripts/test-promote-citations.sh` (add version+provenance + backfill assertions)
- Modify: `.claude/skills/README.md`
- Modify: `.claude/skills/*/SKILL.md` (backfill `version: 1.0.0`, all existing)
- Modify: `.claude/agents/worker-{implementation,codex-implementation,review,conflict-resolver,auditor}.md` (Step-0 dispatcher pointer)
