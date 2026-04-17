---
name: worker-resume-from-rescue
description: |
  Resume a Hydra ticket branch after Commander ran `scripts/rescue-worker.sh
  --rescue`. Use when the spawn prompt contains a "resume from rescue" hint,
  the `commander-rescued` label is on the ticket, or the branch already has
  commits from a prior worker and you're the fresh worker picking it up.
  Teaches the orient → diff → finish → draft-PR loop: how to read the prior
  worker's partial work (including the `rescue: partial work …` WIP commit),
  identify remaining acceptance criteria, commit incrementally so the next
  stream-idle timeout doesn't lose your work either, and flip the label
  from `commander-rescued` / `commander-ready` to `commander-review`.
  Do NOT re-run steps the prior worker already completed. (Hydra)
---

# Resume a ticket after `scripts/rescue-worker.sh --rescue`

## Overview

Stream-idle timeouts around ~18 min on big tickets are real (see `docs/specs/2026-04-16-worker-timeout-watchdog.md`). When they hit, Commander's watchdog detects the silent worker, runs `scripts/rescue-worker.sh --rescue`, which commits uncommitted changes (`rescue: partial work from timed-out worker on #<ticket>`), rebases on `origin/main`, and pushes. You are the fresh worker spawned to finish the job. Your first instinct — "start from a clean slate" — is the expensive wrong move: you'll duplicate files the prior worker already wrote, blow another 15-18 min re-doing solved work, and potentially hit a second timeout before you reach the novel part of the ticket.

Instead: orient on what's already landed, pick up mid-stride, and commit incrementally so the next rescue (if it happens) preserves *your* progress too.

## When to Use

- Spawn prompt mentions "resume from rescue", "rescued", or includes the rescue commit's final log line.
- Ticket has label `commander-rescued`.
- `git log --oneline origin/main..HEAD` on `hydra/commander/<n>` already shows commits by a prior worker — regardless of whether you were told "this is a resume".
- The branch tip is a commit whose message starts `rescue: partial work from timed-out worker on #<ticket>` (WIP blob from `--rescue`).

Skip when:

- The branch is at `origin/main` (no prior work — it's a fresh ticket, not a resume).
- You see `commander-stuck` instead of `commander-rescued` — that means the probe returned `nothing-to-rescue` or the rescue hit a conflict (exit 3). Don't apply this skill; fall back to fresh-spawn.

## Process / How-To

1. **Orient on the prior worker's work. Don't edit yet.**

   ```
   git fetch origin
   git checkout hydra/commander/<n>
   git log --oneline origin/main..HEAD
   ```

   Read every commit subject. The last commit is often `rescue: partial work from timed-out worker on #<n>` — that's the WIP blob committed by `--rescue`. Everything before it is work the prior worker had already committed cleanly.

2. **See the full pre-rescue delta.**

   ```
   git diff origin/main -- . ':(exclude)**/*.lock'
   ```

   Exclude lockfiles so you don't drown in `package-lock.json` / `yarn.lock` / `Cargo.lock` churn. Read the diff end-to-end — it is the complete state of the ticket so far. You need a mental map of which files exist, which are partially done, and which are untouched.

3. **Compare against the ticket's acceptance criteria.** Fetch the ticket (`gh issue view <n> --repo <owner>/<repo> --json title,body,labels`) if you don't already have it. For each AC bullet, classify: **done** (present in the diff, tests pass), **partial** (present but incomplete — missing function body, missing test, missing spec cross-link), or **untouched** (no sign of it in the diff). The rescue commit's final log line (surfaced in your spawn prompt's resume hint) is a load-bearing clue about what the prior worker was mid-step on — prioritize that partial.

4. **If the tip is a `rescue:` WIP commit, decide: amend or new-commit.** Usually **new-commit**. Amending would rewrite history that's already pushed (`git push --force` territory, which is on the hard-rails list). The clean move is to leave the WIP blob in place and build forward with narrow commits on top. Amending is acceptable only if (a) you explicitly checked the branch hasn't been pushed yet AND (b) you'd be squashing a partial function into its finished form — which the PR's squash-merge will do for you anyway. Default to new-commit.

5. **Finish the remaining work in narrow incremental commits.** One commit per AC item, or per file-pair (implementation + test). After each finished chunk: `git add <files> && git commit -m "<scoped subject>" && git push`. This matters because a second stream-idle timeout is not impossible on a resumed ticket — the watchdog's 12-min threshold is per-spawn, not per-ticket. Frequent pushes mean a second rescue will have less to rescue.

6. **Do not re-run steps the prior worker already completed.** If step 2's diff shows `docs/specs/YYYY-MM-DD-<slug>.md` already committed, don't rewrite the spec from scratch — add to it if the AC demands more, otherwise move on. Duplicating completed work is the #1 failure mode for resume-spawns.

7. **Open a DRAFT PR with `Closes #<n>`.** In the PR body, include a short "Resume from rescue" section that names (a) the rescue commit SHA, (b) the pre-rescue commits the prior worker landed, (c) what you added on top. The reviewer cares about continuity — this is how you show them the handoff was clean.

8. **Flip the label via REST.** On PR open:

   ```
   gh api --method POST /repos/<owner>/<repo>/issues/<n>/labels -f "labels[]=commander-review"
   gh api --method DELETE /repos/<owner>/<repo>/issues/<n>/labels/commander-ready
   gh api --method DELETE /repos/<owner>/<repo>/issues/<n>/labels/commander-rescued
   ```

   Use REST, not `gh pr edit --add-label` (GraphQL path fails on Projects-classic deprecation; see `CLAUDE.md` → "Applying labels"). `commander-rescued` may or may not be present — `DELETE` on a missing label returns 404; ignore that.

9. **Final report: pre- vs post-rescue delta + any unfinished items.** Your worker report should name the prior-worker commits (SHAs), the rescue-commit SHA, your new commits on top, and — if any AC bullet remains unfinished — a `QUESTION:` block with the specific gap. Emit `MEMORY_CITED:` markers for any memory entries or specs you leaned on.

## Examples

### Scenario A — rescue-commits (prior worker got work committed; rebase succeeded)

Probe returned `rescue-commits`: commits-ahead ≥ 1, dirty false. `--rescue` rebased cleanly, pushed.

```
$ git log --oneline origin/main..HEAD
9f2a4c1 <prior worker> spec: add skill worker-X
3b7e8d5 <prior worker> skill: stub SKILL.md for worker-X
```

No `rescue:` blob (nothing was uncommitted at timeout). The prior worker finished the spec + stubbed the skill file but timed out mid-authoring. Your move: read both files, identify which sections of `SKILL.md` are stubbed (`TBD`, missing examples), fill them in with small commits. Do not touch the spec unless AC demands changes.

### Scenario B — rescue-uncommitted (rescue committed a WIP blob)

Probe returned `rescue-uncommitted`: commits-ahead ≥ 0, dirty true. `--rescue` ran `git add -A && git commit -m "rescue: partial work from timed-out worker on #<n>"`.

```
$ git log --oneline origin/main..HEAD
a1b2c3d rescue: partial work from timed-out worker on #158
7e4f1a9 <prior worker> skill: add Overview + When-to-Use sections
```

Inspect the WIP blob first:

```
$ git show a1b2c3d --stat
 .claude/skills/worker-X/SKILL.md | 45 +++++++++
```

The blob is often half-written — one file with mid-sentence content. Do **not** `git commit --amend` (it rewrites a pushed SHA). Instead: make the partial complete in new commits. If the blob itself is salvageable as-is (e.g. a full section that was never syntactically broken), you can leave it and build on top. If it's mid-sentence garbage, overwrite the affected file with a clean version and commit with a message like `skill: complete <section> (supersedes rescue WIP)`.

## Verification

Author of this skill confirmed the flow by walking a synthetic resume scenario against the current `rescue-worker.sh`:

- `scripts/rescue-worker.sh --probe` on a branch with one prior commit returns `rescue-commits` (exit 0).
- `scripts/rescue-worker.sh --probe` on a branch with one prior commit + dirty worktree returns `rescue-uncommitted` (exit 0).
- After `--rescue`, the branch tip is a `rescue: partial work …` subject matching the skill's step 4 condition; `git log --oneline origin/main..HEAD` renders exactly as the examples above.
- `scripts/rescue-worker.sh` refuses to mutate if `.git/index.lock` is stale (exit 1, see `docs/specs/2026-04-17-rescue-worker-index-lock.md`) — meaning if you arrive at a worktree with the lock present, abort and return a `QUESTION:` rather than try to unstick git yourself.

## Related

- `scripts/rescue-worker.sh` — the rescue tool. Read its header comment for the full exit-code contract.
- `docs/specs/2026-04-16-worker-timeout-watchdog.md` — why the watchdog exists; threshold semantics; detection rules.
- `docs/specs/2026-04-17-rescue-worker-index-lock.md` — stale `.git/index.lock` handling; why `--probe` skips the guard but `--rescue` does not.
- `docs/specs/2026-04-17-review-worker-rescue.md` — sibling flow for `worker-review` timeouts (`--probe-review`). Different kind of worker, different skill — not covered here.
- `.claude/skills/worker-emit-memory-citations/` — emit `MEMORY_CITED:` correctly in your final report.
- `CLAUDE.md` → "Applying labels" — why step 8 uses REST not `gh pr edit --add-label`.
