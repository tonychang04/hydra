---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 150
tier: T2
---

# Skill seed list: bootstrap `.claude/skills/` for Hydra

**Ticket:** [#150](https://github.com/tonychang04/hydra/issues/150)

## Purpose

This document is the AUDIT OUTPUT the ticket asks for. It answers:

1. Which global skills at `~/.claude/skills/*` already satisfy a Hydra worker or Commander use case? (Don't re-invent.)
2. Which Hydra-specific patterns have no global analogue? (Seed candidates.)
3. What seed skills do we want in `.claude/skills/` on day one, and in what order should they be authored?

Think of this file as the backlog for the seed-library effort. Each "proposed seed" section is both a justification and a pre-written ticket body — when the follow-up issue for that seed is filed, its body links back here.

## Survey: global skills (`~/.claude/skills/*`) we plan to reuse as-is

Workers on Hydra tickets operate inside `~/.claude/skills/` scope already (the gstack globals are loaded at the host level). We should NOT author Hydra-local variants of anything this list covers. The Hydra seed skills below are explicitly the COMPLEMENT of this set.

| Global skill | What it does | Why Hydra workers use it as-is |
|---|---|---|
| `investigate` | Four-phase root-cause debugging (investigate → analyze → hypothesize → implement). Iron Law: no fixes without root cause. | Already called out in `.claude/agents/worker-implementation.md` ("borrowed from gstack/investigate"). No Hydra-local customization needed. |
| `review` | Pre-landing PR review: SQL safety, LLM trust boundaries, conditional side effects. | `worker-review` already invokes it. Output format is stable. |
| `codex` | OpenAI Codex CLI wrapper (review / challenge / consult). | `worker-review` already invokes `/codex review`. |
| `document-release` | Post-ship doc sync: reads project docs, cross-refs diff, polishes CHANGELOG. | Applies cleanly to Hydra's own repos and downstream InsForge-family repos. |
| `ship` | Detect base branch, run tests, bump VERSION, commit, push, create PR. | Worker-implementation's PR-creation flow maps to this. Already implicit in `worker-implementation.md` flow. |
| `retro` | Weekly engineering retrospective with persistent history. | Commander's `retro` command maps directly to this. CLAUDE.md already references. |
| `health` | Composite code-quality dashboard. | Useful for pre-merge smoke checks on T2 PRs. No Hydra-specific variant needed. |
| `qa` / `qa-only` | Web QA via headless browser. | Applies to InsForge dashboard PRs. Worker-implementation already routes UI paths to `/qa`. |
| `design-review` / `plan-design-review` | Visual QA + plan-mode design review. | Same — UI paths only. |
| `careful` / `freeze` / `guard` | Safety guardrails. | Useful for destructive commands in worker scripts. No Hydra variant. |
| `checkpoint` | Save/resume working state. | Useful for long-running workers near the 18-min stream-idle ceiling. |
| `learn` | Manage project learnings. | Overlaps conceptually with Hydra memory hygiene but has different plumbing. Reuse selectively; don't mirror. |

**Verdict:** ~13 of ~30 gstack globals map directly. The rest (insforge-*, setup-deploy, pair-agent, canary, benchmark, devex-review, …) either don't apply or need the user's scenario, not a worker's. No Hydra clones for any of these.

## Hydra-specific patterns with no global analogue

Patterns that recur in Hydra's own agents (`worker-*.md`), Commander rails (`CLAUDE.md`), and operator memory (`memory/*.md`) but do NOT appear in any gstack global:

1. **Emitting `MEMORY_CITED:` markers in worker reports** — format, placement, which quote to pick, how it feeds `scripts/parse-citations.sh`. No gstack analogue; this is Hydra's bespoke citation protocol.
2. **Risk-tier classification from a ticket body** — `policy.md`'s T1/T2/T3 rules. Commander does this pre-spawn today by reading `policy.md` inline every time.
3. **PR scoping for `worker-review`** — how a review-worker decides what to look at, what to ignore, how to combine `/review` + `/codex review` + conditional `/cso` outputs.
4. **Resuming a branch after `--rescue`** — what `scripts/rescue-worker.sh` leaves behind, how a fresh worker should continue without re-doing committed work or stepping on rebase state. Currently lives in `docs/specs/2026-04-16-worker-timeout-watchdog.md` only.
5. **Applying labels to PRs via REST** — the `gh pr edit --add-label` GraphQL deprecation footgun. Documented in CLAUDE.md, but workers re-discover it every time they try to label.
6. **Writing a README for a downstream InsForge-family repo** — gstack's `document-release` polishes EXISTING docs. There's no "write the first README" skill for a bare repo. InsForge downstream repos often arrive bare; this is a recurring task.
7. **Authoring a new `.claude/skills/*` skill in this repo** — meta-skill. Teaches the shape + review criteria + promotion-from-memory flow. Small but high-leverage once #145 lands.

## Proposed seed list (7 skills, ordered by leverage ÷ cost)

| # | Skill | Purpose | Lands in | Why this rank |
|---|---|---|---|---|
| 1 | `worker-emit-memory-citations` | The `MEMORY_CITED:` marker format + which quotes to pick + self-check against `scripts/parse-citations.sh`. | **THIS PR** (example seed) | Smallest, most-cited-across-workers, drives the promotion pipeline. Smallest skill authorable with an objective correctness check. |
| 2 | `commander-classify-tier` | Classify a ticket body T1/T2/T3 per `policy.md`. Inputs: ticket title + body + labels. Output: tier + one-sentence rationale + `policy.md` clause that triggered. | Follow-up ticket | Commander does this on every spawn; surfacing the logic as a skill makes it testable and memoizable. |
| 3 | `worker-resume-from-rescue` | Systematic approach to resuming a branch after `scripts/rescue-worker.sh --rescue`. Covers: detect rescue commits, identify what's left, avoid re-running partial work, stash-vs-amend etiquette. | Follow-up ticket | High-stakes (eats worker-minutes if done wrong), low-volume (only on rescue). Deserves a codified procedure, not re-derivation. |
| 4 | `classify-pr-for-review` | How `worker-review` scopes what to look at in a diff — which files matter, which are noise (lockfile, generated), when to trigger `/cso`. | Follow-up ticket | Reduces review-worker variance. Currently lives as prose in `.claude/agents/worker-review.md`; extracting gives it test cases and examples. |
| 5 | `apply-label-via-rest` | One-liner skill: always use REST, never `gh pr edit --add-label`, with copy-pasteable curl/gh invocations. | Follow-up ticket | Trivial in SKILL.md terms, but the footgun keeps happening. Cheap win. |
| 6 | `write-hydra-readme` | README patterns for fresh InsForge-family repos (not Hydra itself). Covers what sections are load-bearing, what the downstream repo's audience needs first. | Follow-up ticket | Closes the `document-release` gap (polish existing ≠ write new). Applies repeatedly across downstream repos. |
| 7 | `author-repo-skill` | Meta-skill: how to author a new `.claude/skills/*` in THIS repo. Template, review rubric, promotion-from-memory rules. | Follow-up ticket | Force-multiplier once the seed library is nontrivial. Lands AFTER at least 2-3 seeds exist — otherwise there's no corpus to pattern-match against. Ranked last so #145's promotion pipeline or #1-6 seeds can inform its contents. |

**Total: 7 seeds.** Sits in the 5-10 range the ticket asked for.

### Explicit rejections (things we considered and dropped)

- **`commander-preflight-check`** — a skill describing the preflight sequence (PAUSE / validate-state / active < cap / daily cap / quota-health). Rejected: already encoded as a runnable script (`scripts/validate-state-all.sh`) + CLAUDE.md prose. Adding a skill layer is redundant.
- **`spawn-worker`** — how Commander picks a subagent type and an isolation mode. Rejected: this is Commander's core loop, not a reusable procedure. Lives in `CLAUDE.md` where routing-table changes are reviewable.
- **`hydra-operator-voice`** — a skill describing how Commander should talk to the operator. Rejected: style lives in `memory/user_operator.md`; a skill would duplicate it.
- **`file-followup-ticket`** — already covered by the MCP tool `hydra.file_ticket` spec (`docs/specs/2026-04-17-main-agent-filing.md`). No skill needed.

## Skill shape (adopted from superpowers, gstack preamble omitted)

```markdown
---
name: <kebab-name>
description: |
  One paragraph. Be precise about triggers — Claude's skill loader matches
  against this. Include phrase patterns ("when a worker reports ...",
  "before emitting ..."). (Hydra)
---

# <Skill Title>

## Overview
One paragraph: what the skill teaches and why a worker needs it.

## When to Use
Bullet list of explicit trigger conditions.

## Process / How-To
Numbered steps. Each step is an atomic action.

## Examples
- Good example (with expected output if relevant)
- Common failure (what the skill prevents)

## Verification
How the author confirmed the skill works. Often: "pass through a canonical
script and assert output", or "compare before/after a pressure test".
```

The gstack telemetry preamble is intentionally absent — Hydra workers run in isolated worktrees, have no telemetry surface, and the preamble would add noise.

## Author order

1. **`worker-emit-memory-citations`** lands with PR #150 (this ticket).
2. Once #150 merges, Commander files 6 follow-up tickets (2-7 above) via `gh issue create --label commander-ready --assignee tonychang04`, one per remaining seed. Autopickup drains them.
3. **Rank-2 ticket (`commander-classify-tier`) is picked up FIRST of the follow-ups** because it unlocks faster Commander spawn decisions — reviewing this before other seeds lets Commander classify follow-up tickets themselves more accurately.
4. Rank-7 (`author-repo-skill`) is picked up LAST — only after ≥2 other seeds have landed so there's a corpus to reference.

## Integration with #145 (skill promotion)

`#145` is the promotion pipeline (memory citations → skill PR). Today it has nowhere to promote into. Once `.claude/skills/` exists (this PR), #145 can:

1. Detect a memory entry with `count >= 3` across 3+ tickets.
2. Open a PR adding `.claude/skills/<name>/SKILL.md` following the shape above.
3. Label `commander-skill-promotion`.
4. Operator reviews → merge → memory entry is annotated with `→ promoted to .claude/skills/<name>.md in PR #N`.

The seeds in this list are SEED (pre-promotion). Future skills will arrive via #145's promotion path, not by hand-authoring.

## Follow-up tickets (to be filed by PR #150 at merge time)

One GitHub issue per seed #2-7. Each will reference this spec's row for justification. See the bottom of PR #150's description for the filed-issue list once the PR is opened.
