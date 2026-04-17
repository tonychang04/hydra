---
status: draft
date: 2026-04-16
author: hydra design
---

# External Memory: Separate Framework Memory from Per-Repo Operational Memory

## Problem

Today Hydra's `memory/` directory mixes two very different kinds of data:

1. **Framework memory** — `escalation-faq.md`, `memory-lifecycle.md`, `tier-edge-cases.md`, `worker-failures.md`, `MEMORY.md`. These apply to ANY operator, across ANY repo. They belong in the Hydra repo (committed, shared via OSS).

2. **Operational memory** — `learnings-CLI.md`, `learnings-InsForge-sdk-js.md`, etc. These are per-operator, per-target-repo. They may contain sensitive snippets of the operator's private code or internal system references. They are already gitignored to keep them out of the public repo, but they still live INSIDE the hydra repo directory, which conflates concerns and makes it easy to accidentally commit (especially if someone relaxes the gitignore).

When the operator clones Hydra, updates their framework memory, and pushes a contribution PR, they shouldn't have to worry about leaking repo-specific learnings. Physical separation is better than a gitignore rule.

Additionally, Phase 2 plans to put operational memory in S3 (`docs/phase2-s3-knowledge-store.md`). Phase 1 should already have that memory in a clean external location so the Phase 2 migration is a config flip, not a refactor.

## Goals

- Framework memory stays at `$HYDRA_ROOT/memory/` (committed)
- Operational memory moves to `$HYDRA_EXTERNAL_MEMORY_DIR` (default `~/.hydra/memory/`, configurable via env var)
- Worker subagents read both: first `$HYDRA_ROOT/memory/` for framework rules, then `$HYDRA_EXTERNAL_MEMORY_DIR/learnings-<repo>.md` for repo-specific gotchas
- `setup.sh` creates the external directory and writes the path to `.hydra.env`
- Phase 2 migration to S3 is a single `HYDRA_EXTERNAL_MEMORY_DIR=s3-files-mount-point` change, nothing else

## Non-goals

- Not moving `escalation-faq.md` externally. It's framework-level and benefits from being shared.
- Not making the external path bucket-aware in Phase 1. POSIX-style directory path only.
- Not migrating existing operator memory automatically. `setup.sh` creates the empty external dir; operators move their own current learnings.

## Proposed approach

**Path resolution:**
- `.hydra.env` defines `HYDRA_EXTERNAL_MEMORY_DIR` (setup.sh populates it)
- `./hydra` launcher sources `.hydra.env` before `exec claude`, so the Commander session has the env var
- Worker subagents inherit the env var; their prompts reference `$HYDRA_EXTERNAL_MEMORY_DIR/learnings-<repo>.md` rather than `$COMMANDER_ROOT/memory/learnings-<repo>.md`

**File movement:**
- `memory/learnings-<repo>.md` → `$HYDRA_EXTERNAL_MEMORY_DIR/learnings-<repo>.md`
- `memory/archive/` → `$HYDRA_EXTERNAL_MEMORY_DIR/archive/`
- Stays in `memory/`: `MEMORY.md`, `escalation-faq.md`, `memory-lifecycle.md`, `tier-edge-cases.md`, `worker-failures.md`

**Index file:**
- `$HYDRA_EXTERNAL_MEMORY_DIR/MEMORY.md` holds the per-operator pointer index (the committed `memory/MEMORY.md` has a minimal index of framework files only)

**Worker prompt update:**
- Step 0 in worker-implementation.md reads both locations in order:
  1. `$HYDRA_ROOT/memory/escalation-faq.md` + framework files
  2. `$HYDRA_EXTERNAL_MEMORY_DIR/learnings-<repo>.md` (if present)

### Alternatives considered

- **A: Keep operational memory in `./memory/` and rely on gitignore.** Current state. Rejected: too easy to leak if gitignore is loosened; conflates concerns; Phase 2 migration is harder.
- **B: Separate hydra-operational repo (private) and hydra-framework repo (public).** Overkill; two repos to maintain for one tool.
- **C: Single `$HYDRA_HOME` dir that holds both framework and operational memory.** Means the framework memory (escalation-faq etc.) lives OUTSIDE the repo, which blocks OSS contributions to it. Rejected.
- **D (picked):** Framework memory in-repo; operational memory in `$HYDRA_EXTERNAL_MEMORY_DIR`; env var wires them together.

## Test plan

1. Fresh clone → run `./setup.sh` → verify `$HYDRA_EXTERNAL_MEMORY_DIR` created at default `~/.hydra/memory/`
2. Launch Hydra via `./hydra`, spawn a worker-implementation on a test ticket
3. Verify the worker reads `$HYDRA_EXTERNAL_MEMORY_DIR/learnings-<repo>.md` (create an entry pre-spawn and check worker's report for `MEMORY_CITED:` referencing it)
4. Verify the worker writes any new learning to the external location, not in-repo
5. Confirm `git status` after a ticket completion shows NO changes in `memory/learnings-*.md` (because those files no longer live in the repo)
6. Self-test: add a golden case where the worker is expected to cite an external memory entry

## Risks / rollback

- **Risk:** Operator forgets to set `HYDRA_EXTERNAL_MEMORY_DIR`, commander/worker can't find learnings. **Mitigation:** `./hydra` launcher fails fast if the env var is unset or the dir doesn't exist. Setup.sh enforces creation.
- **Risk:** Operators on a shared machine accidentally point to someone else's memory dir. **Mitigation:** default is `~/.hydra/` (user-scoped). Documented warning in `setup.sh` if they point elsewhere.
- **Risk:** Worker prompts referencing the wrong path → silent memory misses. **Mitigation:** worker subagents emit `MEMORY_CITED:` markers; self-test catches if they drop to zero after this change.
- **Rollback:** `HYDRA_EXTERNAL_MEMORY_DIR=$HYDRA_ROOT/memory` returns to the old behavior. Zero-risk revert.

## Implementation notes

(To fill after PR lands.)
