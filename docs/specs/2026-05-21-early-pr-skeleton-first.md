---
status: draft
date: 2026-05-21
author: hydra worker (ticket #188)
---

# Skeleton-first early-PR: workers commit + push + open a draft PR as their FIRST milestone

**Ticket:** [#188 — Workers commit+push+open draft PR EARLY so a ~13-min stall is recoverable](https://github.com/tonychang04/hydra/issues/188)

## Problem

On 2026-05-20/21 multiple `worker-implementation` spawns hit the ~13-min turn /
stream-idle limit having *done the work* but never committed, never pushed, and
never opened a PR. The result was an orphaned worktree that needed manual
surgery: `scripts/rescue-worker.sh` to find the partial work, then Commander
finishing the commit/push/PR by hand (incidents #157, #176, #159).

Root cause is in the **documented flow**, not in any one worker. Today
`worker-implementation.md`'s Flow does all the work first and creates the PR at
the END (step 6 of 10). The branch is only pushed when the PR is created. If the
turn limit fires before that step — which is exactly when the work is largest and
most worth saving — there is nothing on the remote and no PR to continue. The
rescue path (`scripts/rescue-worker.sh --rescue`) can recover *committed* work,
but a worker that batches all its commits to the end leaves nothing for it to
find either.

This is the recoverability gap. Memory already hints at the fix
(`memory/learnings-hydra.md`, 2026-04-16 #45: "if you notice your own work
approaching 15 min in a single chat stream, commit early + often so the rescue
can find partial work") but it is advisory and buried in learnings, not doctrine
in the worker flow. This spec promotes it to a mandated first milestone.

## Goals

- Make **skeleton-first early-PR** the documented FIRST concrete milestone of a
  `worker-implementation` run: within the worker's first few actions, make an
  initial commit (the spec, or a WIP stub when the spec isn't ready yet), push
  the branch, and open a **draft PR**. Then iterate with incremental
  commits + pushes.
- A stall after that milestone leaves a recoverable draft PR — Commander reads /
  continues it — instead of an orphaned worktree.
- Communicate the early-PR expectation in the slim spawn template
  (`docs/specs/2026-04-17-slim-worker-prompts.md`) so the worker is told "open
  the draft PR early" at spawn time, not just in its own agent definition.
- A self-test fixture asserts the early-PR milestone is present in the documented
  flow (worker-implementation agent def + slim spawn template) and stays there.

## Non-goals

- **`worker-review.md` changes are OUT OF SCOPE.** The ticket's third acceptance
  criterion (run `/review` and post its output before the slower `/codex review`,
  or time-box `/codex`, so a codex stall doesn't lose the whole review) is a
  separate concern tracked in **#199**. This spec touches only the
  implementation-worker flow + the spawn template + the fixture. See "Follow-up".
- **`worker-codex-implementation.md`, `worker-test-discovery.md`,
  `worker-conflict-resolver.md`, `worker-auditor.md`** — not touched here. The
  early-PR milestone is most acute for `worker-implementation` (heavy multi-file
  work). Extending the doctrine to the other implementing workers is a natural
  follow-up but is held out to keep this PR's blast radius small and to avoid
  colliding with the #199 worker on `worker-review.md`.
- **The rescue mechanism itself** (`scripts/rescue-worker.sh`, the watchdog) is
  unchanged. This spec changes when work first reaches the remote; the rescue
  path that consumes that work is already in place.
- **`self-test/golden-cases.example.json`** is not modified — the operator pinned
  it as off-limits. The fixture is a standalone `run.sh` under
  `self-test/fixtures/early-pr-skeleton/`, the same shape as the existing
  `self-test/fixtures/slim-worker-prompts/run.sh`. Wiring into the shared runner
  is deferred until that file reopens for writes.
- **CLAUDE.md** is not modified. The CLAUDE.md scope rule keeps procedures in
  specs; the worker flow lives in the agent definition, not CLAUDE.md.

## Proposed approach

### 1. The skeleton-first milestone (worker-implementation.md)

Add a dedicated section to `worker-implementation.md` — **"## Early-PR
discipline (skeleton-first, MANDATORY)"** — placed immediately before the
existing `## Flow` section so the worker reads it before it starts working. It
states the milestone and the ordering:

1. Branch off `origin/main` in your worktree (existing git-discipline rules
   apply — `git -C "<worktree>"` for every op).
2. Make an **initial commit** as early as possible: the spec file for non-trivial
   tickets (you write the spec before code anyway), or a tiny WIP stub commit
   (e.g. an empty marker / the spec skeleton) for the rare trivial ticket.
3. **Push** the branch.
4. Open a **draft PR** with `gh pr create --draft` — title `[T<tier>] <title>`,
   body `Closes #<num>` plus a one-line "WIP — skeleton commit, iterating" note.
5. THEN do the implementation, committing + pushing incrementally so each
   increment is on the remote.

The existing Flow's PR step (currently step 6, `gh pr create --draft …`) is
reframed: when the draft PR already exists from the milestone, **do not** call
`gh pr create` again (it errors "a pull request for branch X already exists" —
see `memory/learnings-hydra.md` 2026-04-17 #84). Instead push the final commits
(they append to the existing PR) and update the body with `gh api --method PATCH
/repos/.../pulls/<n> -f body=…` to the full summary + test plan. This reuses the
exact recovery pattern already documented for the rescue case, so there is one
code path for "PR already exists," not two.

The Flow's numbered steps are NOT renumbered (error-prone, and the existing step
references are cited elsewhere). Instead the early-PR section is the doctrine and
step 6 gains a one-line cross-reference to it ("the draft PR already exists from
the Early-PR milestone — finalize, don't recreate").

### 2. Spawn-template signal (slim-worker-prompts.md)

The slim spawn template's footer currently ends with:

```
Done = draft PR with "Closes #<n>" + tests passing. Report: branch, PR #, test output, any QUESTION blocks.
```

Add one line BEFORE that, in the footer, so the worker is told at spawn time to
open the PR early:

```
First milestone: skeleton commit → push → DRAFT PR (so a stall is recoverable). THEN iterate.
```

Plus a short subsection in the spec body ("### Early-PR milestone in the
footer") explaining why the line is there and pointing at this spec. The
template's ≤ 800-char envelope budget is re-checked: the new footer line is ~95
chars; the slim fixture's existing 800-char assertion still must pass, so the
sample-spawn-prompt.txt fixture is updated in lock-step and re-measured.

### 3. Self-test fixture (early-pr-skeleton/run.sh)

A standalone fixture, `self-test/fixtures/early-pr-skeleton/run.sh`, with static
assertions (no worker spawn — same rationale as the slim fixture: a real
spawn-based A/B needs Claude auth + two spawns, out of scope for a unit fixture):

1. `worker-implementation.md` contains a skeleton-first / early-PR section
   header (asserts the doctrine block is present).
2. That section mandates the three sub-actions — an initial/skeleton **commit**,
   a **push**, and a **draft PR** — in the documented flow (grep for the
   commit + push + draft-PR vocabulary within the agent file).
3. The slim spawn template spec (`docs/specs/2026-04-17-slim-worker-prompts.md`)
   communicates the early-PR milestone (grep for the "First milestone" / early
   draft-PR phrasing).
4. The slim fixture's sample-spawn-prompt.txt carries the early-PR footer line
   (so the canonical example stays in sync with the template).
5. This spec file exists at its expected path (frontmatter contract per
   `memory/learnings-hydra.md` 2026-05-21 #201).

Exit 0 if all assertions hold, 1 otherwise. Same `set -euo pipefail` + grep + wc
shell pattern as the other `self-test/fixtures/*/run.sh` scripts.

### Alternatives considered

- **Put the doctrine only in CLAUDE.md.** Rejected: the worker flow is in the
  agent definition, and CLAUDE.md's scope rule pushes procedures to specs. A
  worker reads its own agent def, not CLAUDE.md, for its flow.
- **Renumber the Flow steps so "early PR" becomes step 1.** Rejected: renumbering
  10 steps risks breaking the bug-class-flow example and any external references
  to step numbers; a doctrine section + a one-line cross-reference is lower-risk.
- **Make the milestone advisory ("commit early if you can").** Rejected: that is
  the status quo (the learnings entry) and it didn't prevent #157/#176/#159. The
  milestone is mandated, with the fixture guarding it.

## Test plan

1. `bash self-test/fixtures/early-pr-skeleton/run.sh` on a clean tree → exit 0
   (all assertions pass). This is the red→green proof: the fixture fails before
   the agent-def + template edits land and passes after.
2. `bash self-test/fixtures/slim-worker-prompts/run.sh` → exit 0 (the existing
   slim fixture still passes after the footer line is added and the sample is
   updated — the ≤ 800-char envelope assertion in particular).
3. `bash .github/workflows/scripts/syntax-check.sh` → `syntax-check: OK` (this
   spec's frontmatter contract, per #201).
4. Grep `worker-implementation.md` for the early-PR section header → matches.

## Risks / rollback

1. **Early draft PR creates noise** (a draft PR per ticket from action 1). This
   is intended — a draft PR is the recoverable artifact. Drafts are clearly
   marked WIP and finalized at the end; Commander's review gate only fires when
   the worker reports done, not on draft creation. No extra reviewer load.
2. **`gh pr create` double-call** if a worker forgets the early PR already
   exists. Mitigated by reframing step 6 to "finalize, don't recreate" and by
   the existing #84 learning (check `gh pr list --head <branch>` first; push +
   PATCH the body rather than recreate). The error is non-destructive (gh just
   refuses) and self-correcting.
3. **Spawn-template envelope grows past 800 chars.** Mitigated: the new footer
   line is ~95 chars and the slim fixture re-measures the envelope on every run;
   if it ever exceeds the cap the slim fixture (test 2) fails loudly.
4. **Rollback.** `git revert` the agent-def + template commits — the worker falls
   back to end-of-run PR creation. The fixture would then fail, signalling the
   doctrine regressed; remove the fixture in the same revert if a full rollback
   is wanted. No state or schema changes to unwind.

## Follow-up

- **#199** — apply the same partial-survives-a-stall principle to
  `worker-review.md`: run `/review` and post/commit its output BEFORE the slower
  `/codex review` (or time-box `/codex`) so a codex stall doesn't lose the whole
  review. Deliberately not done here to avoid colliding with the #199 worker.
- Extend the skeleton-first milestone to the other implementing workers
  (`worker-codex-implementation.md`) once #199 lands and the `worker-*.md` files
  are no longer being edited concurrently.
