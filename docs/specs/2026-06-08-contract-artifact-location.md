---
status: accepted
date: 2026-06-08
ticket: https://github.com/tonychang04/hydra/issues/262
area: worker contract / review gate / quality
size: M
authors: [worker-implementation]
supersedes: []
extends:
  - docs/specs/2026-06-07-validation-contract.md
  - docs/specs/2026-06-07-worker-validator.md
  - .claude/agents/worker-implementation.md
  - .claude/agents/worker-review.md
  - .claude/agents/worker-validator.md
---

# Move the validation-contract artifact off the committed repo root to a per-ticket gitignored path

## Problem

#255 introduced a per-ticket **`validation-contract.md`** (the verify-first
artifact: each acceptance criterion → the command that proves it → captured
evidence), and #256 built `worker-validator` on top of it. Both specs place the
artifact **at the worktree root** and instruct the worker to **commit it**:

> "Commit the contract for Hydra's own tickets" — `.claude/agents/worker-implementation.md`.

That single committed root path **cannot represent N concurrent tickets'
contracts**, and committing it poisons `main`. Observed this session (dogfooded
while building #257):

- The #257 worker's `validation-contract.md` got merged to `main` — it is sitting
  in the repo root right now (`git ls-files validation-contract.md` → tracked).
- Every subsequent ticket worker branches off `main`, sees the **previous**
  ticket's contract at the root, and either (a) overwrites it — producing churn
  in every single PR diff (an unrelated file edit), or (b) leaves it and fails
  its own dogfood gate because the root contract is for a different ticket. This
  is exactly what blocked #261's review.

The root cause is a **shared mutable path for a per-ticket artifact**. One path,
N writers → collision. The fix is a per-ticket, non-committed location.

## Goals

1. Move the contract artifact to a **per-ticket, gitignored** path:
   `.hydra/contracts/<ticket>.md`, with `.hydra/` added to `.gitignore`. Per-ticket
   filename → no collision between concurrent workers; gitignored → never lands in
   `main`, never churns a PR diff.
2. Give the contract a **single source of truth for its path** —
   `scripts/contract-path.sh <ticket> [--worktree <dir>]` prints the canonical
   path — so the agents and both gate scripts resolve it identically (no
   convention drift).
3. Teach `validate-contract.sh` and `revalidate-contract.sh` to **locate a
   ticket's contract by convention** via a new `--ticket <n>` option (resolving
   through `contract-path.sh`), while keeping `--file`/stdin for fixtures + tests.
4. Update `.claude/agents/worker-implementation.md`, `worker-review.md`,
   `worker-validator.md`, and the #255/#256 specs to the new location.
5. **Remove the leftover tracked `validation-contract.md`** from the repo root
   (`git rm`). After this PR, `main` carries no stray root contract.

## Non-goals

- **No change to the contract FORMAT.** The 6-column Markdown table, the verdict
  vocabulary, the placeholder rules, the splitter — all unchanged. Only the
  artifact's *location* and *how callers find it* move. `validate-contract.sh`'s
  and `revalidate-contract.sh`'s parsing logic is untouched.
- **No change to the review-gate composition.** worker-review (presence) →
  worker-validator (truth) stays exactly as #255/#256 wired it. They just read the
  contract from `.hydra/contracts/<ticket>.md` instead of `<worktree>/validation-contract.md`.
- **Do NOT touch CLAUDE.md, `scripts/validate-state*.sh`, or the repos/citations
  schemas** — sibling worker #260 owns those. CLAUDE.md's contract references name
  the artifact by *concept* ("a `validation-contract.md`"), not by the committed
  root path, so they remain accurate without edits.
- **No CI hard-enforcement of the new path.** Same rollout philosophy as #255:
  the agents adopt the convention; the gate scripts support it; a follow-up can
  wire a CI check later (V1: enforce the floor, tighten with data).

## Proposed approach

### The convention

| Aspect | Old (#255/#256) | New (#262) |
|---|---|---|
| Path | `<worktree>/validation-contract.md` (repo root) | `<worktree>/.hydra/contracts/<ticket>.md` |
| Committed? | Yes (for Hydra tickets) | No — `.hydra/` is gitignored, always |
| Concurrent tickets | Collide (one path) | Isolated (one file per ticket #) |
| Located by | Hardcoded root filename | `scripts/contract-path.sh <ticket>` |

`.hydra/` is a worktree-local scratch dir (mirrors the existing
`docker-compose.override.yml` "worktree-local, never committed" guardrail). It is
gitignored unconditionally, so the artifact never appears in any PR diff and never
reaches `main` — for Hydra's own tickets AND for downstream/external repos (which
previously needed a manual `.git/info/exclude` dance; now the path is ignored by
default).

### Where the pieces live

| File | Change |
|---|---|
| `docs/specs/2026-06-08-contract-artifact-location.md` | This spec. |
| `.gitignore` | Add `.hydra/` (the per-ticket contract scratch dir). |
| `scripts/contract-path.sh` | New. `contract-path.sh <ticket> [--worktree <dir>]` → prints `<worktree>/.hydra/contracts/<ticket>.md` (default worktree = `git rev-parse --show-toplevel`, fallback `.`). Single source of truth for the convention. `--mkdir` creates the parent dir. |
| `scripts/test-contract-path.sh` | New. Self-contained TDD regression for the resolver (NO_COLOR-aware, pass/fail counter). |
| `scripts/validate-contract.sh` | Add `--ticket <n>` (resolve the file via `contract-path.sh`). `--file`/`--body`/stdin unchanged. |
| `scripts/revalidate-contract.sh` | Add `--ticket <n>` (same resolution). `--file`/stdin/`--cwd`/`--timeout` unchanged. |
| `.claude/agents/worker-implementation.md` | Write/fill/commit prose → write to `.hydra/contracts/<ticket>.md`, do NOT commit (it's gitignored), run the gate with `--ticket`. |
| `.claude/agents/worker-review.md` | Step 3b → locate the contract via `--ticket <n>` / `.hydra/contracts/<ticket>.md`. |
| `.claude/agents/worker-validator.md` | Re-run leg → `.hydra/contracts/<ticket>.md` (`--ticket <n>`). |
| `docs/specs/2026-06-07-validation-contract.md` | Update the artifact-location prose to the new path (the format section stays). |
| `docs/specs/2026-06-07-worker-validator.md` | Update the contract-path references. |
| repo root `validation-contract.md` | `git rm` — the leftover #257 contract. |

### `scripts/contract-path.sh` — the single source of truth

```
contract-path.sh <ticket> [--worktree <dir>] [--mkdir]
```

- Resolves `<worktree>` (explicit `--worktree`, else `git rev-parse --show-toplevel`,
  else `.`).
- Prints `<worktree>/.hydra/contracts/<ticket>.md` on stdout, exit 0.
- `--mkdir` → `mkdir -p` the `.hydra/contracts/` parent first.
- Validates `<ticket>` is a bare number (so callers can't smuggle a path traversal
  into the filename); bad/missing ticket → usage error, exit 2.

Both gate scripts call it for `--ticket <n>`; the agents reference it (or the
literal `.hydra/contracts/<ticket>.md`) so there is exactly one place the
convention is defined.

### `--ticket` on the gate scripts

`validate-contract.sh` / `revalidate-contract.sh` gain `--ticket <n>`: resolve the
path via `contract-path.sh <n>` and read it like `--file`. This is the "locate by
convention" acceptance criterion. The existing `--file`/`--body`/stdin inputs are
untouched (fixtures and the test suites keep using `--file`), and `--ticket` +
`--file` are mutually exclusive (last-one-wins is avoided — passing both is a
usage error) to keep behavior unambiguous.

### Alternatives considered

- **A — per-ticket filename at the root (`validation-contract-<ticket>.md`),
  committed.** Rejected: still pollutes `main` and the PR diff with N files over
  time; the whole point is to keep the artifact OUT of the committed tree.
- **B — keep the root path but gitignore `validation-contract.md`.** Rejected:
  one path still can't hold two concurrent tickets in the *same* worktree base,
  and a flat ignored root file is easy to clobber; a per-ticket subdir is the
  clean isolation. (Worktrees are separate dirs, but the convention must also be
  robust when a worker resumes/rescues and when humans inspect multiple
  contracts.)
- **C — `.git/info/exclude` per worker (the current #255 downstream guidance).**
  Rejected as the *primary* mechanism: it's a manual per-repo step the worker must
  remember; a committed `.gitignore` entry for `.hydra/` makes it automatic
  everywhere.
- **Chosen:** `.hydra/contracts/<ticket>.md` (gitignored `.hydra/`) + a
  `contract-path.sh` resolver + `--ticket` on both gates.

## Test plan

- `bash scripts/test-contract-path.sh` — TDD regression for the resolver:
  resolves to `<wt>/.hydra/contracts/<n>.md`; `--mkdir` creates the parent;
  non-numeric ticket → exit 2; `--help` → exit 0; default worktree falls back to
  `.` outside a git repo.
- `bash scripts/test-validate-contract.sh` — #255's suite still green (parity:
  `--ticket` added without breaking `--file`/stdin/placeholder/splitter behavior).
- `bash scripts/test-revalidate-contract.sh` — #256's suite still green.
- **Two-concurrent-tickets, no-collision proof:** create
  `.hydra/contracts/300.md` and `.hydra/contracts/301.md` in a temp worktree,
  show both resolve to distinct paths and `validate-contract.sh --ticket 300` /
  `--ticket 301` each read the right one; `git status` shows NEITHER tracked
  (gitignored) — committed-path absence proven.
- `git ls-files validation-contract.md` → empty after the `git rm` (no stray root
  contract on the branch; merges to a clean `main`).
- `self-test/run.sh --kind script` — no NEW failures vs the documented baseline
  (the pre-existing `state-schemas` / ajv `SKIP_HAS_AJV` case is the only red).
- `scripts/preflight-syntax.sh` — bash -n + jq + spec frontmatter (this spec
  included).
- **Dogfood:** THIS ticket's own contract lives at `.hydra/contracts/262.md`
  (gitignored, NOT in the PR diff) and passes `validate-contract.sh --ticket 262`.

## Risks / rollback

- **Risk: a worker still writes to the old root path out of habit.** Mitigation:
  the agent prose is updated to the new path in all three worker defs, and the
  `--ticket` convenience makes the new path the path of least resistance.
- **Risk: `.hydra/` collides with some other tool's use of that dir name.**
  Mitigation: `.hydra/` is Hydra-namespaced; nothing else in the repo uses it
  (grep clean). The contract lives under `.hydra/contracts/` specifically.
- **Risk: removing the root contract breaks a reference somewhere.** Mitigation:
  grep for `validation-contract.md` path usage was done; the only consumers are
  the agent prose + the two gate scripts (all updated). The literal string still
  appears in historical spec narrative (#257's anti-drift spec) describing what
  that worker did — left as a historical record, not load-bearing.
- **Rollback:** revert the spec + `contract-path.sh` + its test + the `--ticket`
  additions + the agent/spec prose edits + the `.gitignore` line, and (if needed)
  restore the root file. The contract format and gates degrade to the #255/#256
  behavior; removal is clean.
