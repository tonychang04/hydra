---
status: draft
date: 2026-05-23
author: hydra worker (ticket #219)
---

# Auto-rescue on worker completion — probe/rescue committed-but-dirty workers

## Problem

**Observed 2026-05-23 (dogfooding).** A worker on #198 ran ~14 min, opened
draft PR #218 (the early-PR doctrine from #216 worked), but on **clean
completion** left 6 files of *verified* work uncommitted in its worktree — 117
lines of codex-review fixes to `pr-shepherd.sh` plus a new review-threads
fixture. The pr-shepherd smoke self-test passed (exit 0) on that uncommitted
state, so the work was good — it just never got its final `git commit`.
Commander had to rescue-commit (`ced2b494`) the worktree by hand.

The existing safety nets miss this case:

- **The early-draft-PR doctrine (#216)** covers *stalls* — it gets a skeleton
  PR up early so a stream-idle timeout doesn't lose everything. It does NOT
  guarantee the *final* state is committed+pushed when a worker stops cleanly
  one step short of its last commit.
- **The timeout watchdog (#45)** only fires on the timeout path: workers >12 min
  with no completion log. A worker that finishes cleanly (writes its completion
  log, reports done) is never probed — so leftover verified work sits in the
  worktree until Commander notices by hand.

There is **no automatic safety net for a clean completion that stops one commit
(or one push) short.** That manual rescue step is exactly the human dependency
the machine is supposed to eliminate.

A second, related blind spot surfaced while reproducing #198: a worker that
opens a draft PR early (so the **remote branch already exists**) and then makes
additional commits it never pushes. The probe today reports this as
`rescue-commits` with `"pushed":true` — a contradiction (`rescue-commits` is
documented as "local commits ahead of base, **not pushed**"). Commander can't
cleanly tell "never pushed at all" from "pushed a draft PR, then left newer
commits behind". Both need rescuing, but the rescue action differs (the second
case only needs a push, no rebase risk on already-shared history).

## Goals / non-goals

**Goals:**

1. Extend `scripts/rescue-worker.sh --probe` to name the committed-but-unpushed
   case distinctly: a new **`rescue-unpushed`** verdict for "the remote PR
   branch exists but local HEAD is ahead of it" (commits committed, never
   pushed). Keep `rescue-uncommitted` (dirty worktree) and `rescue-commits`
   (commits ahead of base, **no remote branch yet**) as-is.
2. `--rescue` must (already commits dirty work; now also) **push unpushed
   commits to the PR branch** — covering both `rescue-commits` (first push,
   `--set-upstream`) and `rescue-unpushed` (the remote branch already exists).
   The dirty-commit message keeps its clear `rescue:` marker.
3. `--rescue` must **never commit gitignored files** (`.env`/secrets). This is
   already true because `git add -A` honors `.gitignore`; the spec adds an
   explicit regression test asserting a gitignored `.env` is *not* committed
   by a rescue.
4. Document a new Commander procedure in the timeout-watchdog spec: run the
   rescue **probe on every worker completion notification** (not just on
   timeouts), so verified work left committed-but-dirty is auto-rescued without
   manual inspection.
5. A self-test golden case / fixture step exercising the new completed-but-dirty
   detection (`rescue-unpushed`) and the secrets-exclusion guarantee, run live
   in CI (`kind: script`).

**Non-goals:**

- Does NOT add a worker-side post-step / wrapper that auto-commits inside the
  worker process. The ticket floats that ("a worker post-step ... `git add -A
  && git commit`") as one option, but the worker agent definitions
  (`.claude/agents/*.md`) are being changed concurrently by PR #223 — editing
  them here would conflict. We make the rescue **automatic at the
  rescue/watchdog layer** instead, which is where the plumbing already lives and
  which catches the case regardless of why the worker stopped short.
- Does NOT change the rescue's rebase-onto-main behavior, the index-lock guard
  (#81), the flaky-tool verdict (#190), the trace-forensics verdicts (#206), or
  the review-rescue path (#75). Those are untouched.
- Does NOT change merge policy, tier classification, or safety rails. A rescued
  worker's PR still goes through the normal Commander review gate.
- Does NOT add a daemon/background monitor. The probe-on-completion is a
  Commander-side decision at an existing touchpoint (the worker-finish event),
  same model as the timeout watchdog.

## Proposed approach

### 1. New `rescue-unpushed` probe verdict

The probe already computes three facts: `commits_ahead` (vs the resolved base),
`dirty` (worktree has staged/unstaged/untracked changes), and `pushed`
(does `<remote>/<branch>` exist). The verdict precedence stays:

1. flaky-tool marker (#190) → `flaky-tool-retry` (exit 5)
2. trace forensics (#206) → `worker-looping` (7) / `worker-mid-tool-call` (6)
3. `dirty` → `rescue-uncommitted` (exit 0)
4. `commits_ahead > 0` → **git-state branch (changed below)**
5. else → `nothing-to-rescue` (exit 0)

The change is inside step 4 only. When `commits_ahead > 0`:

- **No remote branch (`pushed == false`)** → `rescue-commits`
  (`"pushed":false`). Unchanged — "committed locally, branch never pushed".
- **Remote branch exists (`pushed == true`)** and local HEAD == remote HEAD →
  `push-only`. Unchanged — commits are ahead of `main` but the PR branch is
  fully up to date (the early-PR happy path).
- **Remote branch exists (`pushed == true`)** and local HEAD != remote HEAD →
  **`rescue-unpushed`** (NEW; was `rescue-commits` with the contradictory
  `"pushed":true`). This is the #198 committed-but-unpushed case: a draft PR was
  pushed early, then newer commits were left behind.

`rescue-unpushed` carries `commits_ahead`, `dirty:false`, `pushed:true`, and a
new `unpushed: N` field = the count of local commits not on the remote branch
(`<remote>/<branch>..HEAD`), which is the actionable number for Commander.

### 2. `--rescue` pushes unpushed commits

`--rescue` already: commits dirty work (`git add -A && git commit -m "rescue:
..."`), fetches `<remote> main`, rebases onto the base, then pushes
`--set-upstream`. That push already covers `rescue-unpushed` (it pushes whatever
HEAD is after the rebase). The only refinement: when the remote branch already
exists (`rescue-unpushed`), the rebase-onto-main step is a no-op-or-FF in the
common case, and the existing `git push --set-upstream` updates the remote
branch. No new push code is needed — the existing push already handles both the
"create" and "update" cases. We add a regression test proving a committed-but-
unpushed worktree ends with the remote branch advanced to local HEAD.

### 3. Secrets / gitignore safety

`git add -A` stages tracked + untracked files **but never `.gitignore`d ones**;
`.env` is gitignored repo-wide. The rescue therefore cannot commit secrets. We
add a regression test: drop an untracked `.env` (matched by `.gitignore`) plus a
real `work.txt` into a worktree, run `--rescue`, and assert the rescue commit
contains `work.txt` but **not** `.env`.

### 4. Commander procedure: probe on every completion

Update `docs/specs/2026-04-16-worker-timeout-watchdog.md` with a new section:
"Probe on completion (#219)". On **every worker completion notification** (the
worker reported done / wrote its `logs/<ticket>.json`), Commander runs
`scripts/rescue-worker.sh --probe <worktree> <branch> <ticket>` before
considering the ticket finished:

- `nothing-to-rescue` / `push-only` → completion is clean; proceed to the review
  gate as normal.
- `rescue-uncommitted` / `rescue-commits` / `rescue-unpushed` → verified work was
  left behind. Run `--rescue` (commit + rebase + push), label `commander-rescued`,
  and continue to the review gate against the now-pushed branch. No human
  inspection needed.
- `rescue-conflict` (exit 3) → surface to the operator (semantic conflict).
- The liveness verdicts (flaky-tool / mid-tool-call / looping) cannot occur on a
  *completed* worker; if one fires, treat as a stale marker/trace and re-probe.

This is the same probe→branch-on-verdict→rescue loop the timeout watchdog uses;
the only new thing is the trigger (completion, not just >12-min silence).

### Alternatives considered

- **Worker-side auto-commit post-step** (the ticket's option). A wrapper in the
  worker agent that runs `git add -A && git commit && git push` before
  returning. Rejected for this PR: (a) it lives in `.claude/agents/*.md`, which
  PR #223 is concurrently rewriting — guaranteed conflict; (b) it only catches
  the case when the *worker* remembers to run the wrapper, which is the very
  thing that failed in #198. A watchdog-layer net catches the case regardless of
  worker behavior, and degrades gracefully (probe is non-mutating). The two are
  complementary — once #223 lands, a worker-side post-step can be added on top;
  this rescue-layer net remains the backstop.

- **A loud `UNCOMMITTED:` signal only** (the ticket's minimum option) — emit a
  marker and let Commander notice. Rejected as the primary fix because Commander
  *already* has the probe plumbing; wiring a brand-new signal channel is more
  surface area than reusing `--probe` on the completion event. The probe verdict
  IS the structured signal.

- **Fold `rescue-unpushed` into `rescue-commits`** and leave the verdict name
  alone. Rejected: the current `"pushed":true` + `rescue-commits` pairing is
  self-contradictory and Commander can't distinguish "first push needed" from
  "branch exists, just behind" — they have different blast radii (the latter
  touches already-shared history). A distinct verdict keeps the watchdog logic
  honest.

## Test plan

All new checks land in `self-test/fixtures/rescue-worker/run.sh` (the existing
`kind: script` fixture, run live in CI) and are summarized in the
`worker-timeout-watchdog-script` golden case description.

**`rescue-unpushed` detection:**
- Build a throwaway repo with a real remote (a local bare repo as `origin`),
  push a branch (simulating the early draft-PR push), then add a commit that is
  NOT pushed. `--probe` must report `"verdict":"rescue-unpushed"`,
  `"pushed":true`, `"unpushed":1`. (exit 0)
- After pushing that commit (local == remote), `--probe` must report
  `push-only` (regression: not `rescue-unpushed`).
- `rescue-commits` regression: a committed branch with NO remote branch still
  reports `rescue-commits` with `"pushed":false`.

**`--rescue` pushes unpushed commits:**
- On the committed-but-unpushed repo above, run `--rescue`. Assert it exits 0,
  prints the branch name, and the remote branch (`origin/<branch>`) now equals
  local HEAD.

**Secrets exclusion:**
- In a dirty worktree, drop an untracked `.env` (matched by a fixture-local
  `.gitignore`) plus `work.txt`. Run `--rescue`. Assert the resulting rescue
  commit lists `work.txt` but NOT `.env` (`git show --stat`/`git ls-files`).

**`--help` documents the new verdict + behavior:**
- `--help` output mentions `rescue-unpushed`.

**Existing behavior unchanged (regressions):** the full pre-existing fixture
(steps 1–33: nothing-to-rescue / rescue-uncommitted / rescue-commits /
branch-mismatch / index-lock / probe-review / flaky-tool / trace forensics)
must still pass.

**Verification commands (run locally + in CI):**
- `bash -n scripts/rescue-worker.sh`
- `self-test/run.sh --case worker-timeout-watchdog-script`
- `scripts/check-claude-md-size.sh --quiet`

## Risks / rollback

- **Risk: renaming the committed-but-unpushed verdict from `rescue-commits` to
  `rescue-unpushed` breaks a Commander code path keying on the old string.**
  Mitigation: `rescue-commits` is NOT removed — it still fires for the
  "no remote branch yet" case (the common timeout-rescue path). Only the
  `pushed:true && local!=remote` sub-case is renamed, which previously emitted a
  self-contradictory `rescue-commits`+`pushed:true` that no consumer could have
  relied on. The watchdog spec treats both `rescue-commits` and `rescue-unpushed`
  as "run `--rescue`", so behavior is identical.

- **Risk: `--rescue` pushes over a divergent remote branch.** Mitigation: the
  push is `git push --set-upstream` (a fast-forward push, NOT `--force`). If the
  remote branch has commits the local doesn't, the push fails loudly (exit 1)
  rather than clobbering — Commander then surfaces. We never force-push (hard
  rule).

- **Risk: a gitignored secret gets committed by the rescue.** Mitigation:
  `git add -A` respects `.gitignore`; a dedicated regression test asserts `.env`
  is excluded. If a repo somehow tracks a secret (already committed before the
  rescue), that's out of scope — the rescue doesn't make it worse.

**Rollback:** revert the verdict change in `scripts/rescue-worker.sh` (restore
the single `rescue-commits` branch), drop the new fixture steps, and remove the
"Probe on completion (#219)" section from the watchdog spec. Single revert
commit. Commander falls back to probing only on timeout, and manual rescue on
clean-completion-left-dirty.

## Implementation notes

(Filled in after the PR lands.)
