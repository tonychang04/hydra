---
status: draft
date: 2026-04-16
author: hydra worker (ticket #45)
---

# Worker timeout watchdog — recover silent workers autonomously

## Problem

3 out of 9 worker spawns in a recent session hit `API Error: Stream idle timeout - partial response received` around the ~18-minute mark. The pattern correlates with heavy multi-file work (5+ files, ≥500 LOC); tight-scope workers finished cleanly. Specific observed cases:

- `#13` (S3 knowledge store) — partial response, rescued by hand
- `#32` (exercise test-discovery) — ~80% done, rescued by hand
- `#30` (state schemas) — ~30% done, shipped partial + reopened ticket

The work itself is typically recoverable (the worker committed some files before dying) — but **the worker never gets to self-report, open the PR, or emit `MEMORY_CITED:` markers**. Commander has to discover the dead worker on its own and run the rescue steps by hand. This undermines the "set and forget" guarantee of scheduled autopickup: a cold stream-idle timeout today means the operator has to intervene to salvage the work.

We need commander to detect a silent worker, decide whether uncommitted work exists, and run the rescue mechanically. If there's nothing to rescue, the ticket is reopened clean. Either way, commander stops requiring a human to babysit.

## Goals / non-goals

**Goals:**
- A documented commander procedure in `CLAUDE.md` ("Worker timeout watchdog" section) that tells commander exactly what to do when a spawned worker has been silent for ≥12 min: probe the worktree for uncommitted work, run `scripts/rescue-worker.sh` if there's something to save, otherwise reopen the ticket with a retry note.
- A `scripts/rescue-worker.sh` helper that does the mechanical rebase / commit / push given a worktree path + branch name + ticket number. Idempotent; safe to run twice; exits non-zero with a clear message when state is ambiguous.
- A self-test golden case fixture in `self-test/golden-cases.example.json` (SKIP'd for now, pointed at ticket #45) that documents how a future executor would simulate a timeout and assert the watchdog's diagnose-and-recover loop.
- One-paragraph note in `CLAUDE.md` acknowledging **chunked worker prompts** as the future optimization (option #2 from the ticket) — not implemented here.

**Non-goals:**
- Does NOT replace the Managed Agents path (option #4 from the ticket). When commander moves to Managed Agents for worker execution, the underlying harness gets real timeout handling; this watchdog remains as an application-level safety net but may become less frequently invoked.
- Does NOT implement chunked prompts (option #2). Noted as future work only.
- Does NOT wire a background monitor thread or cron. The watchdog is a commander-side procedure invoked at specific decision points (on the next autopickup tick, on operator `status`, on worker-spawn completion). Out-of-band monitoring is a Phase 2 concern.
- Does NOT change merge policy, tier classification, or safety rails. A rescued worker's PR still goes through the normal commander review gate and human-merge (for T2+) requirement.
- Does NOT modify the self-test runner. The new golden case is a SKIP'd stub — wiring live execution is a follow-up that lands with the worker-subagent executor (same blocker as `test-discovery-dormant-to-active`).

## Proposed approach

**Watchdog is a commander-side decision procedure, not a daemon.** Commander already touches `state/active.json` on every tick (autopickup), every `status` command, and every worker-finish event. The watchdog check piggybacks on those existing touchpoints:

1. **Detection:** For each entry in `state/active.json`, compute `now() - started_at`. If > 12 min AND the worker has not yet reported (no log entry in `logs/<ticket>.json`), the worker is a **candidate for rescue**. 12 min is under the observed 18-min stream-idle threshold, giving commander a ~6 min window to act before the session itself gives up.

2. **Probe:** Commander runs `scripts/rescue-worker.sh --probe <worktree> <branch> <ticket>`. The script inspects the worktree:
   - Are there local commits ahead of `origin/main` on the worker's branch?
   - Are there uncommitted staged/unstaged changes in the worktree?
   - Is the branch already pushed?
   The script emits a JSON verdict on stdout — one of `rescue-commits`, `rescue-uncommitted`, `push-only`, `nothing-to-rescue` — so commander can branch on it without parsing human-readable output.

3. **Rescue:** If the probe returns anything other than `nothing-to-rescue`, commander runs `scripts/rescue-worker.sh --rescue <worktree> <branch> <ticket>`. The script:
   - Fetches `origin/main`, rebases the worker's branch on top (fast-forward if possible; on conflict, bails out with a clear error and `rescue-conflict` exit code — commander then surfaces to the operator).
   - If there are uncommitted changes, commits them with a `rescue: partial work from timed-out worker on #<ticket>` message.
   - Pushes the branch to `origin`.
   - Prints the branch name on stdout so commander can hand it to `gh pr create` (or locate an existing PR if one already exists).
   - Exits 0 on success.

4. **Follow-up:** Commander labels the ticket `commander-rescued`, comments with the rescue details (worktree path, commit SHAs pushed, which step the worker died at), and spawns a fresh `worker-implementation` with a `--resume-from-rescue` hint telling it to read the partial work, finish the remaining acceptance criteria, and open / update the PR. This keeps the machine moving without the operator intervening.

5. **Nothing to rescue:** If the probe returns `nothing-to-rescue`, commander labels the ticket `commander-stuck` with a comment noting stream-idle timeout + no partial work recovered. The operator can `retry #<n>` when ready. This is the legacy behavior, just triggered faster (within 12 min vs whenever the operator notices).

**Why a shell script + docs, not a fancy supervisor:** the rescue logic is maybe 30 lines of git plumbing + a JSON probe. Turning it into a standalone Python service or a supervisor-agent ability would balloon the blast radius and require its own testing. A bash script following the established `scripts/hydra-*.sh` pattern (same structure as `hydra-pause.sh`, `hydra-doctor.sh`) is cheap, auditable, and inherits the existing self-test conventions.

### Alternatives considered

- **Alternative A — background monitor thread inside commander.** A loop that pings every active worker every 60s and probes stream health. Cost: requires async state management inside the commander prompt (not a natural fit — commander is driven tick-by-tick via `/loop`). Worse: the monitor itself would race with scheduled autopickup ticks and foreground chat. Rejected because the existing tick-based decision cadence is already well-understood and "check on every tick that touches active.json" adds no new concurrency primitives.

- **Alternative B — wait for Managed Agents.** Option #4 from the ticket; once commander runs workers in a managed cloud sandbox, the underlying SDK handles stream timeouts natively. Cost: unknown timeline for the #43 migration; meanwhile every big ticket is a potential operator interruption. Rejected as the primary fix because the current failure is recurring *today*. Managed Agents is complementary — once it lands, this watchdog becomes less frequently invoked but remains as an application-level safety net.

- **Alternative C — chunked worker prompts.** Split large tickets into smaller worker runs (option #2). Cost: requires a planning pass on every ticket and probably a new "worker-planner" subagent type. Rejected for this PR because it's a structural change; noted as future work in `CLAUDE.md`. The watchdog unblocks the immediate pain regardless of whether chunking lands.

## Test plan

**Goal 1 — documented watchdog procedure:** reviewers can read the new "Worker timeout watchdog" section in `CLAUDE.md` and know exactly when the check fires, what commands to run, and how to interpret the probe verdict. Manual review on the PR + the `spec-presence-check.sh` CI job (already gating framework changes).

**Goal 2 — `scripts/rescue-worker.sh` helper:**
- `bash -n scripts/rescue-worker.sh` passes (enforced by CI `syntax` job, and by the new golden-case step).
- `scripts/rescue-worker.sh --help` prints usage and exits 0 (new golden-case step).
- `scripts/rescue-worker.sh --probe <tmpdir> <branch> <ticket>` on a fresh worktree with no commits returns `nothing-to-rescue` JSON on stdout with exit 0 (new golden-case step, uses a mktemp'd git init as fixture).
- `scripts/rescue-worker.sh --probe <tmpdir> <branch> <ticket>` on a worktree with one local commit returns `rescue-commits` (new golden-case step).
- `scripts/rescue-worker.sh` with missing required args exits 2 with a usage error (new golden-case step).
The live `--rescue` path is exercised on real worktrees by commander itself; the golden case deliberately limits itself to `--probe` + help/usage/syntax checks so it runs in CI without network and without `gh` auth.

**Goal 3 — golden case stub:** a `worker-timeout-watchdog-script` case added to `self-test/golden-cases.example.json` with `kind: script`. The script-kind steps run live in CI today (syntax, --help, probe on fresh worktree, probe on worktree with a commit, missing-args). A second `worker-timeout-watchdog-rescue` case with `kind: worker-subagent` is added as a SKIP'd stub pointing at ticket #45 — this is the full rescue-loop simulation that'll go live once the worker-subagent executor lands.

**Goal 4 — chunked prompts note:** reviewers can find the one-paragraph forward-looking note near the watchdog section in `CLAUDE.md`. No code change beyond docs.

## Risks / rollback

- **Risk: rescue script misidentifies work as rescuable and commits a worktree that wasn't actually the worker's (e.g. stale state from a prior ticket).** Mitigation: the script requires an explicit `<worktree>` + `<branch>` + `<ticket>` on the command line; commander pulls those from `state/active.json`, so there's no guesswork. The script also refuses to run if the checked-out branch doesn't match the expected `<branch>` argument, catching mismatches before they commit.

- **Risk: rebase-on-main during `--rescue` produces a conflict.** Mitigation: the script bails out with exit code 3 and a `rescue-conflict` message on stderr; commander then surfaces to the operator rather than trying to resolve the conflict (which is by definition semantic in a rescue context). This matches the conflict-resolver escalation rule already in `escalation-faq.md`.

- **Risk: 12 min threshold is too tight and triggers rescues on slow-but-alive workers.** Mitigation: the threshold is documented in `CLAUDE.md` as a tunable default, and the rescue decision first runs `--probe` (non-mutating) before any commit/push. A false-positive probe on a live worker is harmless — the script sees the worktree state and simply reports it; nothing is committed until `--rescue` runs. Commander also checks for worker liveness signals (recent log writes) before invoking `--rescue`.

- **Risk: the watchdog confuses a healthy long-running worker with a stream-idle ghost.** Mitigation: detection requires BOTH silence on the chat-stream side AND absence of a completion log. If a worker is actively writing to `logs/<ticket>.json` (e.g. streaming status updates in Phase 2), the watchdog leaves it alone.

**Rollback:** delete the new "Worker timeout watchdog" section from `CLAUDE.md`, delete `scripts/rescue-worker.sh`, and remove the two golden-case entries. Commander falls back to the legacy path (operator notices dead worker in `state/active.json`, runs rescue by hand). Single revert commit.

## Implementation notes

(Filled in after the PR lands.)
