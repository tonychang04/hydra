# Using Hydra

End-to-end walkthrough of one real session. Read `README.md` first for the concept; this is the operational how-to.

## One-time setup (5 min)

Already done in Quick Start. Recap:
1. Clone, `cp` the two `.example` files, edit paths, `gh auth status` green.
2. Decide your default trigger: **assignee** (you assign a ticket to yourself, Hydra picks it up) or **label** (`commander-ready` on the issue). Configured per repo in `state/repos.json`.

## Launching a session

```bash
cd /path/to/hydra
claude
```

Hydra's Commander greets you:

```
Hydra online. 3 tickets ready across 2 repos. 0 heads active. Today: 0 done, 0 failed, 0 min wall-clock. Pause: off.
```

Then it waits. It won't spawn anything until you tell it to.

## Dispatching a ticket (the golden path)

### 1. Pick a ticket to hand off

Option A — **assignee trigger** (simplest):
```bash
gh issue edit 42 --repo your-org/your-repo --add-assignee @me
```
(Or use the GitHub web UI.) Now the issue is assigned to you. Hydra picks up anything assigned to you.

Option B — **label trigger** (explicit):
```bash
gh issue edit 42 --repo your-org/your-repo --add-label commander-ready
```

### 2. Tell Hydra to take it

In the Commander chat session:
```
pick up #42
```

or, for a bulk run:
```
pick up 3
```

### 3. What Hydra does behind the scenes

```
Gary: pick up #42
  ↓
Commander preflight:
  - PAUSE file absent? ✓
  - Concurrent heads < max_concurrent_workers? ✓  (0 / 3)
  - Daily ticket cap? ✓  (0 / 20)
  - Rate-limit health? ✓
  ↓
Commander reads gh issue view #42 → classifies tier (T1/T2/T3)
  - If T3: refuses, reports back
  - If T1/T2: proceed
  ↓
Commander reads state/repos.json → finds local_path for the repo
  ↓
Commander adds label 'commander-working' to the issue (lock)
  ↓
Agent(subagent_type="worker-implementation",
      isolation="worktree",
      prompt="<ticket body + repo path + memory path>")
  ↓
[Worker head starts in a new git worktree]
  - Reads repo's CLAUDE.md, AGENTS.md, .claude/skills/, README
  - Reads commander's memory/learnings-<repo>.md + escalation-faq.md
  - Plans → implements (TDD if feasible) → runs tests
  - If tests need docker: docker compose up -d → run → down
  - Runs /review + /codex review on its own diff
  - gh pr create --draft
  - gh issue edit --remove-label commander-working --add-label commander-review
  - Writes logs/42.json
  - Returns to Commander
  ↓
Commander spawns worker-review on the new PR
  - /review + /codex review (+ /cso if security-adjacent)
  - Posts a synthesized review comment on the PR
  ↓
Commander reports back in chat:
  "#42 → PR #501 opened (T2). Self-review passed. Ready for your merge."
```

### 4. You review + merge

Open the PR, read the diff, read the auto-review comment. If good:
```
merge #501
```

Hydra checks CI green + tier-policy allows + your explicit confirm, then merges.

If you want to reject:
```
reject #501 reason: scope was wrong, need to split into two tickets
```

Hydra closes the PR and labels the issue for follow-up.

## When Hydra asks you something

When a worker hits uncertainty memory can't resolve, you'll see:

```
⏸  Head on your-org/repo#42 is paused.

Q: Repo's CLAUDE.md says use 'pnpm test' but no pnpm is installed.
   Options: (a) install pnpm, (b) fall back to npm, (c) skip tests.
Context: Fresh worktree, package.json has pnpm in packageManager field.
Head's recommendation: (a) — the repo explicitly prefers pnpm and
  installing is fast.
Nearest precedent in memory: none.

Your call? (answer, or "kill" to abandon, or "split")
```

You respond:
```
answer #42: install pnpm — if ticket comes up again say the same
```

Commander `SendMessage`s the worker AND appends your answer to `memory/escalation-faq.md`. Next time, no ping needed.

## Daily operations

- **Morning check-in:** `status` — see what's running, today's numbers, anything stuck
- **See the queue:** `show me 5 ready tickets` — inspection only, no spawning
- **Burst:** `pick up 3` when you want parallel throughput
- **One-off:** `pick up #42` for a specific one
- **Going AFK:** `pause` before you step out, `resume` when back
- **Emergency:** `kill <head-id>` for a runaway
- **End of week:** `quota` / `cost today` to see usage; browse `logs/*.json` to see what shipped

## Self-testing Hydra itself

Before you commit changes to the Hydra framework (CLAUDE.md, a worker subagent file, policy.md):

```
self-test
```

Commander runs worker-implementation against the golden closed PRs in `self-test/golden-cases.json`, compares output to known-good, and reports pass/fail. If something regresses, it tells you which assertion failed on which case. You either fix the commander change or (rarely) update the assertion.

## Linear (opt-in, Phase 2 preview)

If your tickets live in Linear instead of GitHub Issues:

1. Install Linear's MCP server (published by Linear):
   ```
   claude mcp add linear
   ```
2. Copy `state/linear.example.json` → `state/linear.json` and fill in team ID(s) + the state/label you want as the trigger
3. In `state/repos.json`, set `"ticket_trigger": "linear"` per repo
4. Launch Commander. It will poll Linear via MCP alongside GitHub.

Linear workers post updates back to the issue via the same MCP tool. Full parity with the GitHub flow (assignee trigger / state trigger, comments on updates, state changes on PR open/merge).

## Phase-2 end state (what this turns into)

- Commander moves from your laptop to a cloud VM (stays running 24/7)
- Workers run in managed cloud sandboxes (Claude Managed Agents / Daytona / Modal) that can stand up the full service end-to-end
- Chat surface becomes Slack / web / SMS — you steer from your phone
- Memory + logs live in S3 (via S3 Files mount) so multiple operators/commanders share learnings
- Human interventions become rare and measurable — every one gets captured into escalation-faq, shrinking the next week's intervention rate
