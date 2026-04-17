---
status: draft
date: 2026-04-17
author: hydra worker (ticket #98)
---

# README first-impression rewrite — lead with "try it now"

## Problem

Operator feedback (2026-04-17): "you focused a lot on infra which is good but no one can use it." The infra is real — MCP server, cloud commander, Slack bot, docker isolation, schema validators, watchdog, auditor — but a stranger landing on the README today has to scroll past a header, badges, value-prop paragraphs, a four-role table, a demo-walkthrough pointer, three mermaid diagrams, an ASCII learning-loop, and two philosophy bullets before reaching the first copy-paste command. That's the wrong shape for "let people try it."

Concrete current state (README.md on main at commit `07138b6`):

- First `git clone` command: line 249 (inside `## Install` — the 11th H2)
- Time-to-first-copy-paste-command for a stranger skimming top-down: ~250 lines
- No 60-second escape hatch. The existing `## Try it in 10 minutes` block (line 44) points at the `hello-hydra-demo` walkthrough, which is a 10-minute end-to-end tour, not a sub-minute install check.

The observed signal is the README itself: the first ~235 lines are orientation and philosophy. There is no "scroll, copy, paste, see it work" block at the top.

## Goals / non-goals

**Goals:**

1. A stranger with 60 seconds can open README.md, copy 5 commands from the first H2, paste them into a fresh shell, and end up at a Commander session that has picked up its first ticket.
2. The same stranger sees a one-line escape hatch (`./hydra doctor` via `scripts/hydra-doctor.sh`) if any of those commands fails.
3. The "philosophy" content (learning loop, What Hydra IS / IS NOT, architecture diagrams, risk tiers prose) moves BELOW the `## How Hydra compares` table, so depth-seekers choose to scroll, rather than having it thrust on them.
4. Every link in the README still resolves after the reorder. Every section that exists today still exists tomorrow.
5. A `## Demo` placeholder block links to ticket #37 (asciinema cast) as a known follow-up, so the "where's the GIF?" first-impression gap is acknowledged without blocking this PR on #37 landing.

**Non-goals:**

- Rewriting INSTALL.md, USING.md, or CLAUDE.md. This is a README-only PR per the ticket.
- Adding new content beyond the two new H2 blocks (`Try it in 60 seconds` and `Demo`). Every other section stays verbatim.
- Recording the asciinema cast. That's #37.
- Marketing prose. Tone stays neutral — this is docs.
- Trimming the existing `## Try it in 10 minutes` block. It's different from the 60-second quick-start (it's the hello-hydra-demo walkthrough) and stays where it is.

## Proposed approach

### Target reader

The primary reader is **a stranger with 60 seconds** who has just opened README.md from a HN / Twitter / search-results link. They have:

- `git`, `claude`, `gh` already installed (we assume, because otherwise the doctor script catches it)
- `gh auth login` already done (same assumption; doctor validates)
- Zero familiarity with Hydra's internals
- A fresh shell

They decide in ~60 seconds whether to keep reading. "Try it in 60 seconds" is the copy-paste escape hatch that turns "I don't get it" into "oh, it does a thing."

### Placement decisions (what moves above/below the fold)

**Above the fold (in order):**

1. H1 + badges + existing value-prop sentences (lines 1-17 of current README — unchanged)
2. **`## Try it in 60 seconds`** (NEW — first H2 after the intro) — 5 copy-paste commands + one-line `./hydra doctor` escape hatch
3. **`## Demo`** (NEW — placeholder) — text note that the asciinema cast is ticket #37, with a link; nothing else until #37 lands
4. `## Who's who (read this first)` — kept in place; it's orientation, not philosophy
5. `## Try it in 10 minutes` — kept in place; it's the hello-hydra-demo walkthrough, the natural next step after the 60-second quick-start
6. `## How Hydra compares` — moved UP so it sits here, right after the "try it" blocks. This is the cutover point — everything below is depth.

**Below the fold (order preserved within the block):**

7. `## The loop` (mermaid) — moved down from above
8. `## Where Commander lives (local vs cloud mode)` — moved down
9. `## Inside one iteration` (mermaid) — moved down
10. `## The learning loop (TL;DR — this is the magic)` — moved down
11. `## What Hydra IS` — moved down
12. `## What Hydra is NOT` — moved down
13. `## Risk tiers (keep Hydra safe to leave running)` — kept (already below `How Hydra compares`)
14. `## Install` through `## License` — unchanged, in current order

### The 5-command quick-start

```bash
git clone https://github.com/tonychang04/hydra.git
cd hydra
./setup.sh
./hydra add-repo <owner>/<repo>
./hydra
```

Inside the launched Commander, the operator types `pick up 1` — which produces the "hydra picked up its first ticket" outcome the ticket requires.

Verification that each command exists on `main`:

- `git clone ...` — standard git.
- `cd hydra` — standard.
- `./setup.sh` — exists at repo root, executable, idempotent (verified via `test -x setup.sh`).
- `./hydra add-repo` — dispatched at `setup.sh:155` to `scripts/hydra-add-repo.sh`, which exists and is the interactive wizard documented in the CLI table (README lines 271-277).
- `./hydra` — generated by `setup.sh:92-232`, execs `claude` after env + auth sanity checks.

### Escape hatch

A one-line fallback for when any of the above fails:

> If a command above fails, run `./hydra doctor` — it runs a battery of non-destructive environment / config / state checks and prints what to fix.

`scripts/hydra-doctor.sh` is already committed and executable (verified via `ls -la scripts/hydra-doctor.sh`). No new script is introduced.

### Demo placeholder (since #37 is still open)

```markdown
## Demo

A recorded asciinema cast of Hydra picking up a ticket and opening a PR is tracked in [#37](https://github.com/tonychang04/hydra/issues/37). Until that lands, see the walkthrough below (`Try it in 10 minutes`) for the nearest thing to a live demo.
```

Short, honest, actionable. When #37 merges, replacing this block is a 3-line edit that needs no spec.

### Alternatives considered

- **Alternative A — Embed a static GIF directly now, no placeholder.** The ticket explicitly says "Link to #37's asciinema cast if it exists; if not, placeholder SVG or GIF with a TODO link." Recording a static GIF is out-of-scope for a docs-only PR (requires running Hydra end-to-end and screen-capturing), and the ticket also says "Do NOT block merge on #37." Placeholder text is the cleanest read of both constraints.
- **Alternative B — Put the CLI command table (`./hydra doctor`, `status`, `add-repo`, …) above the fold too.** Tempting because it's high-information and already exists. But it's 8 rows of detail, which undoes the "60 seconds" promise. Keep it where it is (inside `## Install`).
- **Alternative C — Delete the existing `## Try it in 10 minutes` section** in favour of the new 60-second block. The 10-minute walkthrough pays off a different reader: someone who's already convinced and wants the end-to-end tour. Deleting it would lose content and violate the "keep ALL existing content" ticket constraint. Keep both; they serve different depths.
- **Alternative D — Leave `## Install` above `## How Hydra compares`.** Currently `## Install` is the 11th H2 and `## How Hydra compares` is the 9th — so `How Hydra compares` is already above `Install`. The new plan moves `How Hydra compares` up further (to H2 position ~6, right after `Try it in 10 minutes`), not down, so `Install` stays in its current location relative to the philosophy block. No change to `Install`.

## Test plan

Docs-only PR. The test plan is structural and link-integrity, not behavioural.

1. **Commands actually work on a fresh clone.** Each command in the new `## Try it in 60 seconds` block is cross-checked against the current repo:
   - `git clone` / `cd hydra` — trivially correct.
   - `./setup.sh` — `test -x setup.sh` passes (verified during spec authoring).
   - `./hydra add-repo` — `setup.sh` line 155 dispatches to `scripts/hydra-add-repo.sh` (verified present).
   - `./hydra` — generated by `setup.sh`.
   - `./hydra doctor` (escape hatch) — `scripts/hydra-doctor.sh` is present and executable.
2. **Every link in the new first-impression section resolves.** Manual check: each `](...)` reference in the `Try it in 60 seconds` and `Demo` blocks is verified to point at a real file or real GitHub issue.
3. **No existing content is dropped.** Grep-baseline of key anchors before/after the edit:
   - `grep -c "commander-review" README.md` — was 1, must remain 1.
   - `grep -c "commander-working" README.md` — was 1, must remain 1.
   - `grep -c "hydra-operator" README.md` — was 1, must remain 1.
   - `grep -c "](" README.md` — was 21, must remain ≥ 21 (new blocks add links; none removed).
4. **CI syntax check passes.** `.github/workflows/scripts/syntax-check.sh` checks shell / JSON / specs; it does not parse README.md directly, but the new spec must have valid `status:` + `date:` frontmatter (verified — this file).
5. **`jq empty` on any JSON touched.** This PR touches no JSON files; `jq` is a no-op for this PR.

## Risks / rollback

**Risks:**

- **Merge conflict with #37.** Ticket #37 is in flight and will also add a `## Demo` block near the top. Both PRs add an H2; the conflict is mechanical. Whoever merges second rebases and either updates the placeholder prose to reference the now-landed cast, or accepts their own version. The ticket explicitly acknowledges this and asks for additive, clearly-bounded edits so the conflict-resolution is trivial.
- **A command in the quick-start stops working** (e.g. `./hydra add-repo` changes its argument shape). Mitigated by: the command is sourced from `setup.sh:153-188` which is the canonical dispatcher; if it changes, `./hydra doctor` still works as the escape hatch.
- **`## Who's who (read this first)` was previously the first H2** — moving it down two positions may be disorienting for readers who already know the README. Mitigated by: it stays near the top (H2 position 4), is still reached within a single scroll, and the new top two H2s are clearly about "try it" vs. "understand it."

**Rollback:**

- Trivial. Revert the README.md change in a single commit. No state migration, no config flip, no data loss. The spec file at `docs/specs/2026-04-17-readme-first-impression.md` remains as a record of why the change was attempted.

## Implementation notes

(Fill in after the PR lands.)
