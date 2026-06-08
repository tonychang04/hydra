---
status: proposed
date: 2026-06-07
author: hydra worker
ticket: 271
tier: T1
---

# README enhancement: sharper positioning, accurate state, learn-loop pointer

**Ticket:** [#271](https://github.com/tonychang04/hydra/issues/271)

## Problem

The README is 650 lines. It is thorough but has drifted from what actually
ships, and it repeats its own pitch enough times that the front door reads
longer than it needs to. Concretely:

1. **Three near-duplicate "try it" entry points.** "Try it in 60 seconds"
   (top), "Demo" (~10 min), and "Try it in 10 minutes" all sell the
   `hello-hydra-demo` fixture or the launch flow. Two of them describe the
   same demo fixture in nearly the same words.
2. **An invented confirmation string.** The 60-second section promises the
   reader will see the literal text **"hydra picked up its first ticket"**.
   No code emits that string — Commander reports a free-form one-line status
   (`CLAUDE.md` step 7, "Report one-line status"). A reader who watches for
   that exact phrase will think the run failed.
3. **Worker-type count is stale.** README says "Three worker types" and lists
   `worker-implementation` / `worker-review` / `worker-test-discovery`.
   `.claude/agents/` actually defines **seven**: those three plus
   `worker-validator`, `worker-auditor`, `worker-conflict-resolver`,
   `worker-codex-implementation`. The "Inside one iteration" prose and the
   "Three worker types" table both undercount.
4. **A dead relative link.** The "Staged rollout" section points at
   `docs/superpowers/specs/2026-04-16-commander-agent-design.md`. That file
   does not exist (there is no `docs/superpowers/specs/` tree at all).
5. **The learning loop has no pointer to the code that runs it.** The ticket's
   headline ask: make `memory → citations → skill promotion →
   CLAUDE.md/policy evolution` concrete with a real pointer. The loop IS
   real and shipped — `scripts/parse-citations.sh` ticks
   `state/memory-citations.json`, `scripts/promote-citations.sh` fires the
   `count >= 3` promotion PR, nine skills already live in `.claude/skills/`,
   and the design is specced in
   `docs/specs/2026-04-17-skill-promotion-automation.md`. The README narrates
   the loop three times in prose but never links any of it, so a reader can't
   verify it's not vaporware.

## Goals

- Cut the three "try it" sections to **one** canonical quick-start plus one
  clearly-labeled longer demo pointer. Net fewer lines.
- Fix every drifted claim so it matches files/specs in-repo (worker count,
  the invented string, the dead link).
- Add a real code pointer to the learning-loop section so the
  memory→citation→skill-promotion pipeline is verifiable, not just asserted.
- Keep the existing voice; run mentally through the humanizer (no rule-of-three
  padding, no inflated claims, no em-dash overuse).

## Non-goals

- No new badges (ticket constraint; only badges reflecting real state).
- No touching `CLAUDE.md` (a separate worker owns #270), `scripts/`, `.claude/`,
  or `state/`. README.md only. INSTALL.md / DEVELOPING.md only if a claim must
  relocate (it does not, in this pass).
- No rewrite of the Mermaid diagrams' semantics — only correct counts/labels
  if a diagram states a wrong number.
- The "How Hydra compares" table stays (the ticket says add such a note *if it
  strengthens positioning*; it already exists and is honest, so it stays).

## Proposed approach

Edit README.md in place:

1. **Consolidate try-it.** Keep "Try it in 60 seconds" as the single
   quick-start. Fold the redundant "Try it in 10 minutes" section into the
   existing "Demo" section (they describe the same fixture) so there is one
   demo pointer, not two. Remove the invented "hydra picked up its first
   ticket" promise; describe the real outcome (a worker spawns; Commander
   prints a one-line status).
2. **Fix the worker-type drift.** Update "Three worker types" → the real
   roster (note the seven agent definitions, keep the table focused on the
   core three a new user meets, but stop claiming there are only three).
   Reconcile the "Inside one iteration" wording.
3. **Repair the dead link.** Point the staged-rollout reference at a spec that
   exists, or drop the broken pointer if no equivalent spec exists.
4. **Ground the learning loop.** In "The learning loop" / "Memory & learning",
   add a compact pointer block: the two scripts, the state file, and the
   promotion spec — so the loop is checkable.

**Alternative considered:** a full top-to-bottom rewrite. Rejected — the
README is mostly accurate and well-voiced; a rewrite risks introducing new
drift and loses reviewable diff granularity. Targeted edits keep the change
auditable and match gstack's `document-release` (polish an existing doc, don't
regenerate it).

## Test plan

This is a docs change; verification is link/claim integrity, captured in
`validation-contract.md`:

- Every relative link in README.md resolves to an existing path (scripted
  check extracting `](...)` targets and stat-ing each).
- The "Three worker types" claim no longer contradicts the seven files in
  `.claude/agents/`.
- The invented "hydra picked up its first ticket" string is gone.
- The learning-loop section names at least one real script/spec that exists
  on disk (`grep` for the pointer + `stat` the target).
- README is shorter than the 650-line starting point (`wc -l`).

## Risks / rollback

Low risk — Markdown only, no executable paths touched. Rollback is a single
`git revert` of the README commit. The only subtle risk is removing content a
reader relied on; mitigated by consolidating (not deleting) the duplicated
demo material and keeping every unique section.
