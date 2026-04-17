---
status: implemented
date: 2026-04-16
author: hydra worker (issue #38)
---

# README comparison table: Hydra vs Dependabot / Aider / Copilot Workspace / Codex CLI

## Problem

New visitors to the repo ask "isn't this just Dependabot / Aider / Copilot Workspace?" The README pitch ("auto-machine that clears your ticket queue while you sleep") sets up the niche, but does not place Hydra against the existing tools a reader has probably used. Without a side-by-side, the reader has to reconstruct the comparison themselves, and the ones who don't finish that reconstruction bounce off thinking Hydra is a redundant entry in a crowded space.

A short comparison table is the cheapest possible fix: one scroll, nine rows, five columns, and the niche becomes obvious. It also forces us to be honest — for pure dependency bumps, Dependabot wins outright, and saying so up front is more credible than pretending Hydra competes on every axis.

## Goals / non-goals

**Goals:**

- A new `## How Hydra compares` section in `README.md` with a table covering: Scope, Trigger, Parallelism, Autonomy, Learning over time, Self-hosted, Cost model, Isolation, Safety tiers, Learning from other workers — across Hydra, Dependabot, Aider, Copilot Workspace, Codex CLI.
- Placement: AFTER the identity pitch (`## What Hydra IS` / `## What Hydra is NOT`), BEFORE the detailed sections that start with `## Risk tiers`. This is the "Why Hydra" region the ticket references — it closes the identity argument rather than burying the comparison mid-mechanics.
- Honest cells. Where Hydra loses, the cell says so. Where we are unsure of a competitor's current behavior, the cell says "per their docs as of 2026-04-16" or is left blank with a footnote rather than fabricated.
- A short follow-up paragraph names the niche in plain English ("general-purpose parallel ticket clearing that learns") and calls out the case where Hydra is the wrong tool (pure dependency bumps).
- A maintenance note in the section (not a separate doc) reminds future contributors to revisit the table semi-annually as these tools evolve — the cell contents will drift otherwise.

**Non-goals:**

- Exhaustive feature matrix. Ten rows covers the dimensions a reader actually uses to pick a tool; adding "supports Jira" or "runs offline" dilutes the signal.
- Comparing against non-agent tools (ChatGPT, Cursor inline completions, plain `gh copilot`). Scope is "agent that opens PRs or edits code on its own."
- Marketing spin. No "✓✓✓ blazing fast" cells. Every cell is a short factual phrase, and where it reads as pro-Hydra it's because the underlying design choice is pro-Hydra, not because the cell is boosted.
- Screenshots or logos. Markdown table only. Keeps the README readable in plain-text viewers and in `gh repo view`.
- External web verification. The worker is not permitted to browse the web (WebFetch/WebSearch disabled). Competitor cells are built from the ticket body's explicit assertions plus the worker's prior training knowledge; any cell the worker is uncertain about gets a date-stamped "per their docs" caveat or is left blank — never invented.

## Proposed approach

Insert one new `## How Hydra compares` section in `README.md` between `## What Hydra is NOT` (line ~170) and `## Risk tiers (keep Hydra safe to leave running)` (line ~172). The section contains three beats:

1. **A one-sentence intro** naming the question the table answers ("if you've used Dependabot / Aider / Copilot Workspace / Codex CLI, here's where Hydra fits").
2. **The table** — ten rows, five columns (Hydra + four competitors), exactly the schema the ticket specifies. Cells are short factual phrases; where a dimension doesn't apply to a tool (e.g. "Safety tiers" for Aider), the cell reads `n/a`.
3. **A three-bullet honesty paragraph** — names the niche, names at least one case where Hydra is the wrong pick (pure dep updates → Dependabot), and one reminder that the table should be updated semi-annually.

Source-of-truth for the Hydra column: `README.md` + `CLAUDE.md` in this repo. Every Hydra cell must be backable by a line in one of those files (self-hosted — yes; autopickup — `state/autopickup.json`; T1/T2/T3 tiers — `policy.md`; learning loop — `memory/` + `state/memory-citations.json`; parallelism — `budget.json:max_concurrent_workers`; isolation — git worktrees in `.claude/worktrees/`; peer help — spec `docs/specs/...` references #21). The Hydra column is the one we can be exactly right about; we owe readers the most rigor there.

Source-of-truth for competitor columns: the ticket body lists the expected claims verbatim ("dependency updates only", "interactive code edits", etc.). Those are the baseline. Where the ticket body and the worker's prior knowledge agree, the cell is confident. Where they disagree or the worker is uncertain, the cell gets a `per their docs as of 2026-04-16` suffix (or is left blank) — we'd rather ship a cell that says "blank, we're not sure" than a cell that looks confident and is wrong.

### Alternatives considered

- **Alternative A — link out to an external comparison page (blog post, docs site).** Lower maintenance burden (one page, one update), but adds a click-through that most README readers won't take. The whole value of the table is that it's in the first scroll; externalizing it defeats the purpose.
- **Alternative B — a longer feature matrix (25+ rows covering every knob).** More "complete," but the interesting dimensions are the ones in the ticket body; adding more rows dilutes the takeaway and raises the maintenance cost. Ten rows is the right density for a README — enough to make the niche obvious, few enough to read in one glance.
- **Alternative C — omit competitor-specific cells and only state Hydra's positioning.** Avoids the risk of competitor-cell drift (Dependabot ships a new feature and our cell becomes wrong), but then the table stops being a comparison. Readers would still have to do the mental compare themselves. The `per their docs as of <date>` pattern + the semi-annual review note is the chosen mitigation.
- **Alternative D — place the section higher, right after the tagline.** More prominent, but breaks the existing README flow (tagline → glossary → demo → loop → identity → mechanics). Placing the comparison mid-identity would preempt the "Who's who" and "The loop" sections, which are more fundamental. After `## What Hydra is NOT` is the natural close of the identity argument.

## Test plan

Docs-only change. No unit tests. Verification is:

- `README.md` still renders as valid GitHub-flavored Markdown (spot-check the new section in the GitHub PR preview).
- The new section is the only structural change to `README.md`; the existing sections (`## Who's who`, `## Try it in 10 minutes`, `## The loop`, `## What Hydra IS`, `## What Hydra is NOT`, `## Risk tiers`, `## Install`, etc.) are unchanged both in content and in section-header level (all remain `##`).
- The table validates against the ten-row / five-column schema in the ticket body (spot-check row order and column order match the ticket's table exactly).
- Every cell in the **Hydra** column is backable by a specific line in this repo's `README.md` / `CLAUDE.md` / `policy.md` / `state/*` — a reader who doesn't trust the table can `grep` for the claim. (The spec does not cite every line — that's verification work in the PR.)
- CI's `check-syntax` job passes (Markdown lint; we're not introducing broken fences or stray HTML).

No self-test golden case is added for this ticket — a Markdown diff in `README.md` isn't load-bearing on worker behavior the way `policy.md` or a subagent prompt would be. Text rot in the table is a documentation-drift concern addressed by the semi-annual review note, not by `self-test/`.

## Risks / rollback

- **Risk: competitor cell is wrong on the day of merge.** Likelihood: low-medium — we're shipping with `per their docs as of 2026-04-16` date-stamps on uncertain cells, and the Hydra column is the one we control. Mitigation: the review note commits us to a revisit; a follow-up issue filed against this repo can update specific cells without a full section rewrite. If a reader flags a wrong cell, the fix is a one-cell diff.
- **Risk: a competitor ships a major change and the table becomes stale inside six months.** Likelihood: medium — the agent-coding space moves fast. Mitigation: the semi-annual review note is the primary defense; a secondary is that the `## Learning from other workers` row is the one with the longest half-life (no competitor is shipping that today, and it's the core differentiator, so even a stale table still communicates the niche correctly).
- **Risk: the table reads as marketing spin despite the goal.** Mitigation: the honesty paragraph explicitly names a case where Hydra loses (dep updates → Dependabot). If a reader only reads the paragraph and not the table, they still get the correct takeaway.
- **Rollback:** revert this PR. One file changes (`README.md`) plus the spec file. No config, no code, no state. Reverting is `git revert <sha>` with zero downstream cleanup.

## Implementation notes

- The table is inserted at a single location in `README.md`; no other section is reflowed. Keep the PR diff tight.
- Every cell is a short phrase, not a sentence. The reader should be able to compare columns by scanning a row, not by reading paragraphs.
- Where a competitor doesn't have a concept that Hydra does (e.g. safety tiers, per-worker isolation), the cell says `n/a` rather than `—` or a blank. Consistent language helps the reader tell "this dimension doesn't apply here" apart from "we don't know."
- The section is intentionally placed before `## Risk tiers` because `## Risk tiers` opens the "Install / mechanics / reference" half of the README. The comparison table is identity content, not reference content.
- No emojis in the table. README body already uses a few (in the Mermaid diagrams), but the table itself stays plain text for grep-ability and accessibility.
