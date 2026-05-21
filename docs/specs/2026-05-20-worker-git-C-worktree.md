---
status: proposed
date: 2026-05-20
author: hydra worker
ticket: 185
tier: T2
---

# Workers must use `git -C <worktree>`: stop cwd-reset cross-branch contamination

**Ticket:** [#185 — Workers must use git -C \<worktree\>](https://github.com/tonychang04/hydra/issues/185)

## Problem

The Bash tool's working directory **resets to the main repo dir between calls** — a
`cd <worktree>` in one Bash invocation does NOT persist to the next. Shell variables
also do not persist across separate Bash calls. Any worker that runs
`cd "$WT" && git commit …` across separate Bash invocations actually commits in the
**main repo**, on whatever branch the main worktree currently has checked out. With N
parallel workers this means:

- cross-branch commits (one worker's commit lands on another worker's branch),
- the main repo parked on a random worker's branch, and
- risk to other workers' uncommitted working-tree state.

This is not theoretical. Incident 2026-05-20 (in the ticket body and recorded in
`memory/learnings-hydra.md`, the `#177` entry):

> 2026-05-20 #177 — The Bash tool's cwd resets to the MAIN repo dir between calls — it
> does NOT persist your worktree. […] In #177 a spec commit landed on top of a sibling
> worker's branch (`hydra/commander/159`, which had their uncommitted changes) this way.
> ALWAYS target your own worktree by absolute path with `git -C "$MYWT" <cmd>` […]

- **Worker #159** did its entire job in the **main repo working directory** instead of
  its worktree, leaving the main repo checked out on `hydra/commander/159` with an
  uncommitted edit.
- **Worker #177**'s first commit landed on **#159's branch** by accident; it recovered
  with `git reset --soft HEAD~1` and redid the work via `git -C`.

No data was lost (luck, not design). The framework currently has **no written rule**
forcing `git -C`, **no explicit worktree-path hand-off** in the spawn template, and
**no guard** that makes a worker fail loudly instead of committing to the wrong branch.

`scripts/rescue-worker.sh` is the existing good precedent: it takes `<worktree>` as an
explicit positional arg, routes every git call through `git_in() { git -C "$worktree" "$@"; }`
(`scripts/rescue-worker.sh:171`), and refuses to run when `HEAD` isn't on the expected
branch (`scripts/rescue-worker.sh:181-183`, exit 1). The worker-facing flow should be
just as explicit.

## Goals

- Every worker agent def that performs git operations MANDATES `git -C "$WORKTREE"`
  (worktree resolved once, used explicitly on every call) — never a bare `git` or a
  `cd`-dependent git across Bash calls.
- The slim spawn template communicates the worktree path explicitly (a `Worktree:`
  line), so the worker never has to guess or rely on cwd.
- A documented **pre-commit branch-assertion guard**: the worker asserts
  `git -C "$WT" rev-parse --abbrev-ref HEAD` equals its expected branch before
  committing; abort loudly if not. Provide a small, reusable helper script so the
  guard is one command, not a copy-pasted snippet.
- A self-test fixture that simulates a cwd reset and proves the guidance prevents a
  wrong-branch commit: **red** (bare `git commit` lands on the wrong branch) without
  the guard, **green** (`git -C` + the assertion) with it.

## Non-goals

- **Changing the worker output contract** (PR body format, skill chain, memory
  citations). This is a git-hygiene + safety ticket.
- **Enforcing the guard via a git hook** in every worker worktree. Worktrees are
  ephemeral and created by the harness; installing per-worktree hooks is out of scope.
  The guard is a documented helper the worker calls before committing, plus the agent
  doc mandate. A hook-based belt-and-suspenders layer can be a follow-up if the
  documented guard proves insufficient in practice.
- **`worker-auditor`** does no git operations (its only write action is `gh issue
  create`; `Edit`/`Write`/`NotebookEdit` are `disallowedTools`). It gets a one-line
  note that it performs no git ops, not the full mandate — adding commit guidance to a
  read-only worker would be misleading.
- **Rewriting `scripts/rescue-worker.sh`** — it already does this correctly and is the
  precedent we cite.
- **Auto-deriving `$WORKTREE`** from the harness env. Commander writes the
  `Worktree:` line into the spawn prompt by hand (same as the other slim-template
  fields); auto-population from `state/active.json` is a possible follow-up but is not
  required to fix the incident.

## Proposed approach

### 1. Reusable helper: `scripts/assert-worktree-branch.sh`

A focused, dependency-free (bash 3.2 + git) guard modeled on `rescue-worker.sh`'s
`git_in()` + branch check. Contract:

```
scripts/assert-worktree-branch.sh <worktree> <expected-branch>
```

- Resolves the worktree's current branch via `git -C "<worktree>" rev-parse --abbrev-ref HEAD`.
- Exit `0` and print `OK: <worktree> on <branch>` when current == expected.
- Exit `1` when current != expected, when `<worktree>` is not a git work tree, or when
  `<worktree>` doesn't exist — printing a loud, actionable message to stderr
  (`✗ branch mismatch: expected '<expected>', worktree is on '<current>' …`).
- Exit `2` on usage error (wrong arg count), with a `Usage:` block.
- `-h`/`--help` prints usage, exit 0.

Why a script and not just doc prose: a single command (`scripts/assert-worktree-branch.sh
"$WT" "$BR" || exit 1`) is harder to get subtly wrong than a hand-copied
`rev-parse | grep` snippet, and it gives the self-test something concrete to exercise.
It mirrors the `rescue-worker.sh` exit-code contract (1 = mismatch/IO, 2 = usage) so the
two are mentally consistent.

### 2. Worker agent doc updates

Add a new **"Worktree git discipline (mandatory)"** section to each git-using worker
def, in the same voice/structure as the existing "Hard rules" sections:

- `worker-implementation.md`
- `worker-codex-implementation.md`
- `worker-test-discovery.md`
- `worker-review.md` (it runs `gh pr` commands but no `git commit`; it still gets the
  rule because it may run `git -C "$WT" diff`/`log` and must not assume cwd)
- `worker-conflict-resolver.md` (its Flow currently shows **bare** `git fetch` /
  `git checkout` / `git merge` / `git commit` — these get rewritten to `git -C "$WT"`)

The section text (adapted per worker; conflict-resolver and the two implementers get the
full pre-commit-assertion paragraph, review/test-discovery get the trimmed read-only
variant):

> ## Worktree git discipline (mandatory)
> The Bash tool's cwd RESETS to the main repo between calls, and shell variables do NOT
> persist between separate Bash calls. A `cd <worktree>` in one call is gone by the next.
> If you run a bare `git commit` (or `cd "$WT" && git commit`) across separate Bash
> calls, you commit in the MAIN repo, on whatever branch it currently has checked out —
> often another in-flight worker's branch. This corrupted two workers on 2026-05-20
> (incident in ticket #185).
> - In your FIRST command, capture your worktree's absolute path:
>   `WT="$(git rev-parse --show-toplevel)"`. Write it down; you cannot rely on a shell var
>   surviving to the next call, so type the absolute path explicitly each time.
> - Use `git -C "<that absolute path>" …` for EVERY git operation — `add`, `commit`,
>   `checkout`, `fetch`, `merge`, `push`, `diff`, `log`, `status`. Never a bare `git`,
>   never a `cd`-then-git.
> - BEFORE every commit, assert you're on your branch:
>   `scripts/assert-worktree-branch.sh "<worktree>" "<repo>/commander/<ticket>" || exit 1`.
>   If it fails, STOP — do not commit. (Helper is in the Commander root, not the target
>   repo; reference it by its Commander-root path.)
> Precedent: `scripts/rescue-worker.sh` already takes an explicit `<worktree>` and routes
> all git through `git -C` (see `git_in()` and the branch-mismatch guard).

`worker-auditor.md` instead gets a single line in its Hard rules confirming it performs
no git operations (its only write is `gh issue create`).

Also fix the example git commands in `worker-conflict-resolver.md`'s Flow to use
`git -C "$WT"` so the doc's own examples don't contradict the new rule.

### 3. Slim spawn template: explicit worktree path

Add a `Worktree:` line to the canonical template in
`docs/specs/2026-04-17-slim-worker-prompts.md` and the matching CLAUDE.md template
block. The `Repo:` line already carries `<owner>/<repo> @ <local_path>` but that path is
the **target repo clone**, not necessarily the worker's isolated **worktree**. We add an
explicit, unambiguous worktree line and a one-line directive:

```
Ticket: https://github.com/<owner>/<repo>/issues/<n>
Repo: <owner>/<repo> @ <local_path>
Worktree: <absolute worktree path>   ← all your git ops must target this with `git -C`
Tier: T<n>
…
```

The slim-prompt fixture already asserts header lines in order; we extend it (in this
ticket's fixture, not by editing the slim-prompt fixture) only to the extent the
acceptance criteria require. The slim-prompt spec gets a short subsection documenting the
new line and pointing at this spec.

### 4. Self-test fixture: prove red→green

New behavioral fixture `self-test/fixtures/worker-git-worktree/run.sh`, modeled on
`self-test/fixtures/rescue-worker/run.sh` (throwaway git repos, real script, exit-code
asserts). It:

1. **Sets up the trap.** Two throwaway repos: a `main` repo checked out on a *sibling*
   worker's branch (`hydra/commander/159`) and a separate `worktree` repo on the
   current worker's branch (`hydra/commander/185`). This reproduces the parallel-worker
   layout where the main repo is parked on someone else's branch.
2. **RED — demonstrate the bug.** Run a bare `git commit` *from inside the main repo's
   dir* (simulating a worker whose cwd reset to main). Assert the commit landed on the
   **sibling's** branch (`hydra/commander/159`), NOT on the worker's branch — i.e. the
   contamination the ticket describes actually happens without discipline. Then reset it
   out (`git reset --soft HEAD~1`) so the fixture leaves no residue.
3. **RED — the guard catches it.** Run `scripts/assert-worktree-branch.sh "<main>"
   "hydra/commander/185"` and assert it **exits 1** (the main repo is on the sibling's
   branch, not ours) with a `branch mismatch` message. This proves the guard would have
   stopped the bad commit.
4. **GREEN — discipline fixes it.** Run `scripts/assert-worktree-branch.sh "<worktree>"
   "hydra/commander/185"` → exit 0. Then `git -C "<worktree>" commit` and assert the
   commit landed on **`hydra/commander/185`** inside the worktree and that the main repo
   is **unchanged** (still on the sibling branch, sibling's HEAD untouched).
5. **Helper unit asserts.** usage error (exit 2) on wrong arg count; exit 1 on a
   nonexistent path; `--help` prints `Usage:` and exits 0; `bash -n` clean.

Wire it into `self-test/golden-cases.example.json` as a `script`-kind case
`worker-git-worktree-discipline` (kind `script` is the only executable kind today),
mirroring the `worker-timeout-watchdog-script` case's `bash -n` + `--help` +
fixture-roundtrip step shape.

## Test plan

1. `bash -n scripts/assert-worktree-branch.sh` → exit 0.
2. `bash self-test/fixtures/worker-git-worktree/run.sh` → prints `PASS`, exit 0. The
   RED steps inside the fixture must observably fail the wrong-branch way before the
   GREEN steps pass; the script asserts both.
3. `./self-test/run.sh --case worker-git-worktree-discipline` → case passes.
4. `bash self-test/fixtures/slim-worker-prompts/run.sh` → still exit 0 (we didn't break
   the existing slim-prompt assertions; the `Worker type:` / `Coordinate-with:` lines
   are unchanged, and the new `Worktree:` line doesn't violate the ≤800-char envelope —
   re-checked in step 6).
5. `grep -l 'git -C' .claude/agents/worker-implementation.md
   .claude/agents/worker-codex-implementation.md .claude/agents/worker-test-discovery.md
   .claude/agents/worker-review.md .claude/agents/worker-conflict-resolver.md` → all five
   match; `grep -c 'cd "\$WT" && git\|^\s*git fetch\|^\s*git checkout'` in
   conflict-resolver shows the bare-git examples are gone.
6. `bash scripts/check-claude-md-size.sh` → exit 0 (CLAUDE.md template addition stays
   within the 18,000-char ceiling; the `Worktree:` line adds ~1 line).
7. `jq empty self-test/golden-cases.example.json` → valid JSON after the new case.

## Risks / rollback

1. **Helper path resolution.** Workers run inside a worktree but the helper lives in the
   Commander root (`scripts/`). The agent docs reference it by its Commander-root path
   (the same way they already reference `$COMMANDER_ROOT/memory/…` and
   `scripts/rescue-worker.sh`). Within this repo (Hydra dogfooding itself), the worktree
   *is* a checkout of this repo, so `scripts/assert-worktree-branch.sh` resolves
   relative to the worktree root. For external target repos the helper won't exist in
   the worktree — the doc makes the `git -C` mandate the primary defense and the helper
   the convenience layer; the mandate alone (use `git -C`, never bare git) prevents the
   incident even where the helper isn't reachable. Documented in the agent-doc section.
2. **Over-strict guard blocks a legit commit.** The guard only fails on a real branch
   mismatch (current != expected). If a worker passes the wrong expected branch it gets
   a loud error and stops — which is the desired behavior; the fix is to pass the right
   branch, not to weaken the guard.
3. **Fixture flakiness.** The fixture uses `mktemp -d` + a cleanup `trap`, identical to
   the rescue-worker fixture; no network, no `gh`, no Claude auth. Runs anywhere bash +
   git is installed.
4. **Rollback.** `git revert` the implementation commits. The agent-doc mandate is pure
   documentation; reverting it restores the prior (incident-prone) prose. The helper and
   fixture are additive; reverting removes them with no other code depending on them.
   The slim-prompt template change is one line; reverting drops the explicit `Worktree:`
   line and Commander falls back to inferring the worktree from `Repo:` (the pre-fix
   behavior).
