---
status: draft
date: 2026-06-18
author: hydra worker (ticket #308)
---

# Pre-spawn readiness gate — catch stale-main / dirty-base before cutting a worktree

## Problem

There is no pre-spawn gate that verifies the base a worktree is cut from is
current and clean. Two concrete failure classes recur:

1. **Commander's own preflight reads stale numbers.** This session (2026-06-18)
   Commander's session-start `CLAUDE.md` size read reported 94% when the real
   tree was 64% — local `main` was **27 commits behind origin**. That stale base
   caused a redundant ticket (#305) a worker had to refuse.
2. **Workers branch a worktree off a stale or dirty local `main`.** Once on a
   stale base, the worker trims the wrong byte counts, commits to the wrong
   branch, or rebases a mega-diff. `memory/learnings-hydra.md` cites this class
   16+ times across #177 / #185 / #203 / #231 / #262 / #267 / #285 — every one
   a "wrong/stale base" incident.

`scripts/plan-parallel-batch.sh` (#257) prevents *file-overlap* collisions
between concurrent tickets. Nothing prevents *stale-base* collisions. This spec
adds the missing half: a deterministic, report-only check, runnable before any
spawn, that answers "is the base this checkout would cut a worktree from current
and clean enough to spawn against?"

## Goals / non-goals

**Goals:**

- A new `scripts/assert-spawn-readiness.sh` that, given a checkout, computes how
  far its base branch is behind/ahead of `origin/<default>` and whether the base
  has dirty tracked changes, then emits a machine-readable `--json` verdict plus
  a human one-line verdict + exact remediation command.
- The helper is **report-only** — it RECOMMENDS a remediation (`git merge
  --ff-only origin/<b>`); it never runs `git merge`, never spawns, never mutates
  state. This mirrors `scripts/plan-parallel-batch.sh` and
  `scripts/autopickup-tick.sh`.
- Wire the gate as a preflight item in the authoritative operating-loop /
  preflight spec (`docs/specs/2026-05-24-self-driving-autopickup-tick.md`), as a
  read-only check Commander runs BEFORE spawning.
- A `scripts/test-assert-spawn-readiness.sh` unit harness (sibling of
  `scripts/test-plan-parallel-batch.sh`) covering all four acceptance cases
  offline (real throwaway git repos in a tmpdir, no network).

**Non-goals:**

- The helper does **not** auto-run `git merge --ff-only`. ff-only is safe but
  actuation stays with Commander — the helper surfaces the remediation; Commander
  decides. Same report-only boundary as the existing helpers.
- It does **not** fetch-and-merge, rebase, or touch any worktree. It inspects the
  checkout it is pointed at (`--repo-dir` / cwd) and reports.
- It does **not** replace `plan-parallel-batch.sh` — that prevents file-overlap;
  this prevents stale-base. Complementary, both stay.
- It does **not** decide tier, pick tickets, or enumerate `gh` issues.

## Proposed approach

`scripts/assert-spawn-readiness.sh` (bash + jq, mirroring
`plan-parallel-batch.sh` flag-parsing / `--json` shape / exit-code conventions).

Flags:

```
scripts/assert-spawn-readiness.sh [--repo-dir <path>] [--base <branch>]
    [--no-fetch] [--json] [-h|--help]
```

Flow:

1. Resolve the repo dir (`--repo-dir`, default cwd's `git rev-parse
   --show-toplevel`) and the default branch (`--base`, else
   `origin/HEAD`'s target, else `main`).
2. Unless `--no-fetch`, run `git -C <dir> fetch origin <base> -q` so the
   behind/ahead count is against the true remote tip. `--no-fetch` makes the
   check fully offline (used by the unit test, which has a local `origin`).
3. Compute behind/ahead via
   `git rev-list --left-right --count origin/<base>...<base>` →
   `behind` = commits on `origin/<base>` not in local `<base>`,
   `ahead` = local commits not on `origin/<base>`.
4. Compute `dirty`: any **tracked** change (staged or unstaged modification) on
   the base. Untracked files are NOT dirty — they're listed in `untracked[]` but
   never block (a worktree cut from the base won't inherit another worker's
   untracked scratch into a tracked diff).
5. `ready` = `behind == 0 && !dirty`. (`ahead > 0` does not block — being ahead
   of origin is normal mid-session and never corrupts a freshly-cut worktree.)
6. `remediation` = `"git merge --ff-only origin/<base>"` when `behind > 0`, else
   `null`. (We recommend ff-only, not rebase — it's the safe, non-rewriting way
   to catch up a base that has only moved forward; if the local base diverged
   such that ff-only would fail, `ready` is already false via `behind`, and the
   operator/Commander resolves the divergence deliberately.)

Output:

- `--json`: one stable object
  `{generated_at, ready, behind, ahead, dirty, default_branch, untracked,
  remediation, reason}`.
- human (default): a one-line verdict (`READY` / `NOT READY: <reason>`) + the
  exact remediation command when not ready.

Exit codes (mirroring the ticket): `0` when `ready:true`; non-zero
(`1`) when `ready:false` with a clear reason; `2` on usage / parse error
(bad flag, not a git repo, missing jq).

### Alternatives considered

- **Alternative A — fold the check into `autopickup-tick.sh`'s preflight block
  directly.** Rejected: the tick's preflight is about *Commander state* (PAUSE,
  `validate-state-all`, concurrency headroom), not *git base freshness*, and the
  tick is already large. A standalone helper is independently testable offline
  and callable by a worker too (a worker can self-check its base before
  branching). The tick can call it later without this spec reworking the tick.
- **Alternative B — have the gate auto-run `git merge --ff-only`.** Rejected:
  violates the report-only boundary every sibling helper holds. ff-only is safe,
  but actuation is an irreversible-class decision that belongs to Commander, and
  auto-merging inside a read-only preflight would make the gate untestable
  offline and surprising. We surface the one-line remediation instead.
- **Alternative C (picked)** — a thin, report-only, offline-testable helper that
  RECOMMENDS and a one-line preflight wiring note.

## Test plan

`scripts/test-assert-spawn-readiness.sh` (bash, colored pass/fail counter, no
external harness — style of `scripts/test-plan-parallel-batch.sh`). Each test
builds a throwaway git repo + a bare `origin` in a `mktemp -d`, runs the helper
with `--no-fetch` (offline), and asserts the `--json` verdict + exit code:

1. **Clean, up-to-date base** → `ready:true`, `behind:0`, `dirty:false`, exit 0.
2. **Base N behind origin** → `ready:false`, `behind:N`, `remediation` is the
   `git merge --ff-only origin/<b>` string, exit non-zero (1).
3. **Dirty tracked change on base** → `ready:false`, `dirty:true`, exit 1.
4. **Untracked-only files** → `ready:true` (not a blocker), exit 0, and the
   untracked path appears in `untracked[]`.
5. `--json` is valid JSON in every case above (`jq empty` succeeds).
6. Usage errors: not-a-git-repo → exit 2; unknown flag → exit 2; `--help` →
   exit 0.
7. Determinism: same repo state twice → byte-identical JSON modulo
   `generated_at`.

`scripts/validate-state-all.sh` must exit 0 (no state schema touched, but the
spec adds a `docs/specs/*.md` so the repo-wide syntax-check must stay green).

## Risks / rollback

- **Risk:** `git fetch` in the gate is slow or offline-flaky on a real run.
  **Mitigation:** `--no-fetch` makes it fully offline; a fetch failure is
  reported as `reason:"fetch-failed"` and `ready:false` (fail-closed — don't
  spawn against an un-verifiable base), never an unhandled crash.
- **Risk:** the gate blocks a legitimately-ahead base. **Mitigation:** `ahead`
  never blocks; only `behind > 0` or `dirty` blocks.
- **Risk:** drift between this gate's "dirty" definition and a worker's actual
  worktree hazard. **Mitigation:** the gate checks the *base* the worktree is cut
  from; tracked dirt on the base is exactly what leaks into a fresh worktree.
  Untracked is explicitly excluded and surfaced separately.
- **Rollback:** delete `scripts/assert-spawn-readiness.sh` +
  `scripts/test-assert-spawn-readiness.sh` + this spec, and revert the one-line
  preflight note in the autopickup-tick spec. No other script changes, so nothing
  else regresses.

## Implementation notes

(Fill in after the PR lands.)
