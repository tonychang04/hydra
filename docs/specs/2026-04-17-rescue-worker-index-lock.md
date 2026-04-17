---
status: draft
date: 2026-04-17
author: hydra worker (issue #81)
---

# rescue-worker.sh — guard against `.git/index.lock` race

Implements: ticket [#81](https://github.com/tonychang04/hydra/issues/81) (T2).

## Problem

`scripts/rescue-worker.sh` documents its exit-code contract as
`{0: success, 1: I/O or branch mismatch, 2: usage error, 3: rescue conflict}`.

During the review of PR #69 the reviewer reproduced a race: when `--rescue`
is invoked while a git operation is mid-flight in the worker worktree
(`.git/index.lock` is still present), the first mutating git call fails with
git's own exit code **128** and the opaque message
`fatal: Unable to create '.git/index.lock': File exists.`

Callers — most importantly Commander's rescue-from-timeout path — see an
undocumented exit code, and Commander's retry logic (which only recognizes
exit 1) never fires. No data is corrupted (git's lock mechanism prevents
that), but the rescue flow stalls and the ticket has to be hand-escalated.

## Goals

1. `--rescue` detects `.git/index.lock` **before** it issues any mutating git
   call (`git add`, `git commit`, `git rebase`, `git push`).
2. On detection, exit with a documented code and a rescue-specific message so
   Commander's existing retry logic handles it without a human in the loop.
3. Self-test fixture covers the new path so future regressions are caught by
   `./self-test/run.sh --case worker-timeout-watchdog-script`.

## Non-goals

- Eliminate the TOCTOU window entirely. The check is best-effort — another
  process can still create the lock between the probe and the first
  `git add`. We only need to close the common window where the lock is
  already present when rescue begins.
- Add a new exit code. Reusing `1` is cheaper for callers (see "Alternatives"
  below).
- Gate `--probe`. Probe is non-mutating and reads git state via `git rev-parse`
  / `git rev-list` / `git status --porcelain`, none of which need the lock.
  Adding the guard there would false-positive on live-but-alive workers and
  defeat the purpose of the non-mutating probe.

## Proposed approach

Add a single helper `ensure_no_stale_lock()` at the top of the `--rescue`
code path (after branch / worktree validation, before the first `git add`).

```bash
ensure_no_stale_lock() {
  local lock="$worktree/.git/index.lock"
  if [[ -f "$lock" ]]; then
    local pid=""
    # best-effort PID extraction: some git versions write the PID into the lock
    if [[ -r "$lock" ]]; then
      pid="$(tr -d '[:space:]' < "$lock" 2>/dev/null || true)"
    fi
    [[ -z "$pid" ]] && pid="unknown"
    echo "ERROR: .git/index.lock present at $worktree — worker may still be writing; rerun when fully exited (pid $pid)" >&2
    exit 1
  fi
}
```

Exit code: **1** (matches the existing `I/O or branch mismatch` bucket —
`.git/index.lock` is an I/O-sibling concern and reusing the code keeps the
documented contract at 4 values).

Message format (load-bearing — self-test asserts substring):
```
ERROR: .git/index.lock present at <worktree> — worker may still be writing; rerun when fully exited (pid <stale-or-unknown>)
```

### Alternatives considered

1. **Add a new exit code `5 = git-lock busy`.** Slightly more explicit for
   callers, but expands the contract from 4 codes to 5 and forces every
   caller (including Commander's watchdog) to grow a new branch. Given the
   `.git/index.lock` case is semantically `I/O busy`, folding it under exit 1
   is the smaller, less-invasive change. **Rejected.**
2. **Guard every single mutating call separately.** More precise but creates
   four identical guards (before `git add`, `git commit`, `git rebase`,
   `git push`) — more code, same TOCTOU window between any pair. A single
   guard at the top of `--rescue` covers the realistic failure mode (lock
   held continuously by a still-alive worker). **Rejected — YAGNI.**
3. **Acquire the lock ourselves (`flock`).** Cross-platform flakiness on macOS
   (`flock(1)` is not in base) and doesn't match git's own locking semantics.
   **Rejected.**

## Test plan

1. Extend `self-test/fixtures/rescue-worker/run.sh` with ONE new assertion:
   - In the existing throwaway repo, create `$tmp/.git/index.lock` with a
     dummy PID
   - Run `"$RESCUE" --rescue "$tmp" hydra/commander/45 45 --base refs/heads/main`
   - Assert exit code is `1`
   - Assert stderr contains the substring
     `".git/index.lock present"` and `"worker may still be writing"`
2. Existing fixture assertions (probe verdicts, branch mismatch, usage
   errors, help) continue to pass.
3. `./self-test/run.sh --case worker-timeout-watchdog-script` passes.

## Risks / rollback

- **TOCTOU:** the check only narrows the window; it doesn't eliminate it. A
  worker that creates the lock *after* the check still lands on the original
  exit-128 path. Documented in non-goals; acceptable — the primary failure
  mode (lock present when rescue starts) is fully covered.
- **Probe untouched:** probe still skips this check, so it never refuses to
  run. This is intentional (see non-goals).
- **Rollback:** single helper + single call site. Revert is trivial if a
  regression surfaces — just remove `ensure_no_stale_lock` and the call.

## Acceptance (mirrors ticket #81)

- [x] Spec at `docs/specs/2026-04-17-rescue-worker-index-lock.md`
- [x] `scripts/rescue-worker.sh` adds the lock check before any mutating git
  call in `--rescue`
- [x] Update CLAUDE.md "Safety guarantees of `scripts/rescue-worker.sh`"
  bullet list (one-line addition)
- [x] Self-test assertion added to fixture
- [x] `./self-test/run.sh --case worker-timeout-watchdog-script` passes
