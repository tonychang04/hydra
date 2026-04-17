---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 150
tier: T2
---

# Ticket #150 — Skill audit + seed list: bootstrap `.claude/skills/` for Hydra

**Ticket:** [#150 — Skill audit + seed list](https://github.com/tonychang04/hydra/issues/150)

## Problem

Hydra's `.claude/skills/` directory does not exist. All expertise for Commander + worker subagents lives in:

- `CLAUDE.md` (routing tables, rails)
- `.claude/agents/worker-*.md` (per-worker prompts, already bloated)
- `memory/learnings-*.md`, `memory/escalation-faq.md` (operator-curated gotchas)

By contrast, `~/.claude/skills/gstack/*` has ~30 skills that cover the general developer loop (`document-release`, `investigate`, `review`, `ship`, `land-and-deploy`, `plan-*-review`, `retro`, `cso`, `health`, `careful`, `freeze`, etc.).

CLAUDE.md (`## Memory hygiene`) and `memory/memory-lifecycle.md` already promise a skill-promotion loop: _"When `count >= 3` AND `tickets.length >= 3 distinct`, commander flags it as promotion-ready"_. But:

1. The promotion pipeline is tracked as separate work (#145 — status per issue comment: missing).
2. There is no seed library to promote _into_. The directory itself doesn't exist.
3. Workers that need a pattern _today_ have no place to look. Worker Step 0 lists `.claude/skills/*` as a read target, but it's always empty.

**This ticket does not build the promotion pipeline.** It closes the gap between "Hydra promotes skills when X happens" (documented) and "Hydra has any skills today" (false). Promotion lands the library; the audit + seed bootstraps it so there's somewhere to land.

## Goals

1. **Audit what global skills already cover Hydra's use cases.** Reusables are not re-invented.
2. **Propose a 5-10 skill seed list** covering Hydra-specific patterns with no global analogue.
3. **Create `.claude/skills/`** with a README that explains authoring, the promotion loop (#145), and composition with `~/.claude/skills/*` globals.
4. **Author ONE seed skill as an example** — the smallest high-value one (`worker-emit-memory-citations`) — so the directory is not empty on merge and future authors have a template to copy.
5. **File follow-up tickets** for each remaining seed, each with `commander-ready` + assignee `tonychang04` so autopickup handles them.
6. **Add a ONE-LINE pointer** in CLAUDE.md's `## Memory hygiene` section to the seed-list spec.

## Non-goals

- **Building the promotion pipeline.** #145 is separate; this ticket intentionally seeds the library but does not automate growth into it.
- **Re-implementing gstack globals.** If `~/.claude/skills/<name>/SKILL.md` already solves a need, document it in the audit and skip.
- **Modifying worker agent prompts.** Workers already have `.claude/skills/* (if present)` in Step 0. No prompt changes needed — the dir just has to exist.
- **Authoring more than one seed skill in this PR.** Others are follow-up tickets; this keeps the PR reviewable and gets each seed a dedicated spec + review cycle.
- **Touching `skills/` at the repo root.** That's Main-Agent skills (different audience — the operator's primary assistant). See `skills/README.md` for the distinction. This ticket is exclusively about `.claude/skills/` (worker-subagent scope).

## Proposed approach

### Two deliverable specs

**This spec** (ticket-150-skill-audit) documents the implementation of ticket #150 itself — the PR scope, what lands, what follow-up tickets get filed.

**Seed-list spec** (`docs/specs/2026-04-17-skill-seed-list.md`) is the AUDIT OUTPUT — reusables survey, per-seed justification, proposed author order. This is the artifact the acceptance criteria call for; it lives on after #150 closes as the single source of truth for the seed effort.

### Skill shape

Follow the Anthropic/Claude Code skill format (same one superpowers and gstack use), minus gstack-specific preamble (analytics/telemetry bash):

```markdown
---
name: <kebab-name>
description: |
  One paragraph. Claude's skill loader matches worker prompts against this, so
  be precise about when the skill should activate. Include trigger phrases.
---

# <Skill Title>

## Overview
## When to Use
## Process / How-To
## Examples
```

Worker subagents discover these implicitly via Step 0 (`.claude/skills/* (if present)`). They are NOT on the `skills:` list in `.claude/agents/worker-*.md` — that list is reserved for `superpowers:*` plugin skills that the subagent runtime loads explicitly. Repo-local skills are read as repo context, not loaded as runtime tools.

### One seed skill in this PR: `worker-emit-memory-citations`

Chosen because it is:
- The smallest (< 100 lines of SKILL.md).
- Directly testable against `scripts/parse-citations.sh` — the canonical parser already exists.
- Highest-leverage: every worker on every ticket should emit citations, but the FORMAT is easy to get wrong (I nearly shipped a variant before checking `parse-citations.sh` myself on this ticket).
- Closes a real observability gap: citation counts drive the promotion pipeline (#145), which in turn grows the library this spec bootstraps.

### Follow-up tickets

Each additional seed from the seed-list spec gets one GitHub issue with:
- Title: `[P3/auto-learn] Seed skill: <name>`
- Body: link to the seed-list spec's section for that skill + acceptance criteria
- Labels: `commander-ready`
- Assignee: `tonychang04` (autopickup trigger)

Filed at the end of this PR so autopickup drains them naturally.

### Alternatives considered

- **Author all seeds in one PR.** Rejected: would blow past the T2 size budget (~ 100 lines per skill × 7 seeds = > 700 lines just for skill bodies, plus review overhead per skill). Per-skill PRs get per-skill review; easier to reject or rework one seed without blocking the rest.
- **Defer until #145 lands, then let promotion grow the library organically.** Rejected: chicken-and-egg. Promotion needs a directory to promote into and a shape to match. Seeding one skill + authoring the dir README unblocks #145 without pre-supposing its final mechanics.
- **Put worker-facing skills under `skills/`** (the existing Main-Agent skills dir). Rejected: worker Step 0 reads `.claude/skills/*`, not `skills/*`. The dir choice matters for discovery.

## Test plan

Because this ticket is a documentation + directory-creation task, the tests are structural and behavioral-by-reading, not runtime.

1. **Directory exists:** `test -d .claude/skills && test -f .claude/skills/README.md` passes.
2. **Seed skill passes its own documented verification:**
   - The skill declares a canonical output format. A fixture report (embedded in the skill body as an example) round-trips through `scripts/parse-citations.sh` and produces the expected JSON delta (`jq '.citations | length' > 0`).
3. **Worker Step 0 sees the dir:** a dry-run of `worker-implementation.md`'s orientation sequence (`ls .claude/skills/` returns non-empty) succeeds.
4. **CLAUDE.md size guard still passes:** one-line pointer addition must not trip `scripts/check-claude-md-size.sh`.
5. **Spec is linked:** grep for `2026-04-17-skill-seed-list.md` in CLAUDE.md returns at least one match.

No new unit tests, no new scripts. The seed skill is self-validating via its own example + the existing `parse-citations.sh`.

## Risks / rollback

- **Risk: we pick the wrong skills for the seed list.** Mitigated by: the seed-list spec is a proposal, reviewable per-seed; the operator can strike any entry in the PR review. Rejected seeds just don't get a follow-up ticket filed.
- **Risk: `.claude/skills/README.md` drifts from `skills/README.md` (confusingly similar names).** Mitigated by: both READMEs open with an explicit pointer to the other, so neither can quietly become the wrong home.
- **Risk: CLAUDE.md pointer bloat.** Mitigated by: strictly one line. The size-guard script catches regressions.
- **Rollback:** revert the PR. The directory + README + one skill is additive; no other code is modified. No state migrations. Follow-up tickets remain open and can be closed manually if the seed effort is abandoned.

## Memory citations used

Before the implementation, this spec was grounded in the following existing memory + docs. Emitted per the `MEMORY_CITED:` protocol:

- `memory/memory-lifecycle.md#"3+ workers across 3+ distinct tickets"` — defines the promotion threshold this audit feeds.
- `memory/escalation-faq.md#"The repo has no CLAUDE.md or .claude/skills/"` — escalation FAQ already anticipated the empty-dir case; worker is told to fall back to README + package.json. Creating the dir closes that edge case on our own repo.
- `docs/specs/2026-04-17-claudemd-size-guard.md` — the one-line pointer rule this PR honors.
- `docs/specs/2026-04-17-memory-preloading.md` — shapes the `MEMORY_CITED:` format the seed skill teaches.
