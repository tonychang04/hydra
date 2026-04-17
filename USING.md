# Using Hydra

End-to-end walkthrough of one real session. Read `README.md` first for the concept; this is the operational how-to.

Hydra has **two operating modes**. Both run on the same framework — the same CLAUDE.md, same workers, same memory, same self-test. The only difference is where Commander lives and how work gets dispatched to it.

| Mode | Commander runs on | You dispatch by | When to pick it |
|---|---|---|---|
| **[Local mode](#local-mode-terminal-chat-default)** (default) | Your laptop, inside a `claude` session | Typing commands in the Commander chat | Fastest start. Laptop-bound (closes the lid, work stops). |
| **[Cloud mode](#cloud-mode-flyio--mcp-agent-driven)** | A Fly.io VM (or any Debian VPS) | Another agent calling `hydra.*` MCP tools (or GitHub webhook, once #40 lands) | 24/7 commander. Works while you sleep. Agent-driven, headless. |

Sections below are self-contained — if you only care about one mode, read only that section. Everything below "Self-testing Hydra itself" applies to both modes.

## Local mode (terminal chat, default)

### One-time setup (5 min)

Already done in Quick Start. Recap:
1. Clone, `cp` the two `.example` files, edit paths, `gh auth status` green.
2. Decide your default trigger: **assignee** (you assign a ticket to yourself, Hydra picks it up) or **label** (`commander-ready` on the issue). Configured per repo in `state/repos.json`.

### Launching a session

```bash
cd /path/to/hydra
./hydra
```

Hydra's Commander greets you:

```
Hydra online. 3 tickets ready across 2 repos. 0 heads active. Today: 0 done, 0 failed, 0 min wall-clock. Pause: off.
```

Then it waits. It won't spawn anything until you tell it to.

### Dispatching a ticket (the golden path)

#### 1. Pick a ticket to hand off

Option A — **assignee trigger** (simplest):
```bash
gh issue edit 42 --repo your-org/your-repo --add-assignee @me
```
(Or use the GitHub web UI.) Now the issue is assigned to you. Hydra picks up anything assigned to you.

Option B — **label trigger** (explicit):
```bash
gh issue edit 42 --repo your-org/your-repo --add-label commander-ready
```

#### 2. Tell Hydra to take it

In the Commander chat session:
```
pick up #42
```

or, for a bulk run:
```
pick up 3
```

#### 3. What Hydra does behind the scenes

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

#### 4. You review + merge

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

### When Hydra asks you something

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

### Daily operations

#### From the Commander chat (interactive)

- **Morning check-in:** `status` — see what's running, today's numbers, anything stuck
- **See the queue:** `show me 5 ready tickets` — inspection only, no spawning
- **Burst:** `pick up 3` when you want parallel throughput
- **One-off:** `pick up #42` for a specific one
- **Going AFK:** `pause` before you step out, `resume` when back
- **Emergency:** `kill <head-id>` for a runaway
- **End of week:** `quota` / `cost today` to see usage; browse `logs/*.json` to see what shipped

#### From any terminal (no chat needed)

Routine ops are also exposed as `./hydra <subcommand>` — no Claude session launch, no waiting for a greeting. Safe for scripts, cron, or SSH from your phone. Spec: `docs/specs/2026-04-16-hydra-cli.md` (ticket #25).

```bash
./hydra status                                   # read-only snapshot
./hydra status --with-tickets                    # also count `gh issue list @me`
./hydra pause --reason "debugging prod incident" # toggle PAUSE on
./hydra resume                                   # toggle PAUSE off
./hydra list-repos                               # table view of state/repos.json
./hydra add-repo your-org/new-repo               # interactive wizard
./hydra add-repo your-org/new-repo \             # non-interactive variant
    --local-path ~/code/new-repo \
    --trigger assignee \
    --non-interactive
./hydra remove-repo your-org/new-repo            # remove an entry
./hydra issue https://github.com/foo/bar/issues/42  # queue for next tick
./hydra issue foo/bar#42                         # same, shorter form
./hydra doctor                                   # install sanity-check
```

These subcommands edit `state/repos.json` and `state/pending-dispatches.json` directly via atomic writes (tmp + mv); they never spawn a worker. `./hydra issue` appends to a queue that the Commander's autopickup tick drains first — useful when you want a specific ticket processed now but don't want to open chat. `pause` / `resume` toggle the `PAUSE` file that the Commander respects at spawn time.

## Cloud mode (Fly.io + MCP, agent-driven)

Cloud mode keeps Commander alive 24/7 and removes "type into a terminal" as a requirement for dispatching work. Same framework, same workers, same memory — just a different home for the Commander process and a different transport for its control surface.

> Install: **[INSTALL.md Option C](INSTALL.md#option-c--agent-driven-install-phase-2-direction-agent-only-interface)**. Current status: contract + config + deploy artifacts shipped (#48 + #50). The MCP server binary and GitHub/Linear webhook receivers are separate follow-ups (#40, #41, server binary follow-up under #50).

### Topology (what runs where)

```
┌─────────────────────┐                  ┌──────────────────────────────┐
│  Your Main Agent    │                  │  Fly.io VM (or Debian VPS)   │
│  (Claude Code on    │─── MCP ─────────▶│                              │
│   your laptop, or   │   over stdio     │  Commander (headless)        │
│   a supervisor bot) │   or HTTP+SSE    │    ├─ reads hydra-tools.json │
│                     │                  │    ├─ authorizes per-agent   │
│  Calls hydra.*      │◀───responses─────│    │   (token_hash + scope)  │
│  tools              │                  │    ├─ spawns workers as      │
└─────────────────────┘                  │    │   subprocesses          │
                                          │    └─ escalates novel Qs via │
                                          │        supervisor.resolve_*  │
                                          │                              │
                                          │  Persistent volume:          │
                                          │  /hydra/data/{state,memory,  │
                                          │   logs}                      │
                                          └──────────────────────────────┘
```

Commander is the *same* Claude Code process running `CLAUDE.md` as its system prompt — it's just that the inputs come from MCP tool calls instead of keystrokes, and the process lives in a Docker container on Fly.io instead of a terminal on your laptop.

### Deploying Commander to the cloud

One-command Fly.io deploy (details + rollback in [`docs/phase2-vps-runbook.md`](docs/phase2-vps-runbook.md)):

```bash
./scripts/deploy-vps.sh
```

The script prompts for your Fly app name, region, `CLAUDE_CODE_OAUTH_TOKEN` (preferred — uses your Max subscription), and `GITHUB_TOKEN`. It then runs `fly launch --copy-config`, stages the secrets, creates a persistent volume, and deploys. ~3–5 minutes end to end.

Non-Fly operators: `infra/systemd/hydra.service` has the equivalent unit-file for bare Debian VPS (Hetzner, DO). Same env contract, same entrypoint.

### Validating artifacts before you deploy

Two smoke scripts sanity-check the cloud + local artifacts without side effects:

```bash
./scripts/test-cloud-config.sh   # fly.toml, Dockerfile, entrypoint, deploy-vps, MCP JSON
./scripts/test-local-config.sh   # setup.sh → .hydra.env + repos.json + ./hydra launcher
```

Both exit 0 iff every available check passes. They skip gracefully when optional prereqs (flyctl, docker, shellcheck, hadolint) aren't installed, so they're safe in CI and on bare operator laptops alike.

### Dispatching a ticket from the Main Agent (agent-only interface)

Once the MCP server binary ships (`./hydra mcp serve` — follow-up to #50), your Main Agent has `hydra.*` tools available. The dispatch pattern:

```
# your Main Agent invokes tools — no human chat with Commander
hydra.get_status({})
hydra.list_ready_tickets({limit: 5})
hydra.pick_up({count: 2})                         # spawn up to 2 workers
hydra.review_pr({pr_num: 501})                    # deliberate review worker
hydra.merge_pr({pr_num: 501, caller_agent_id: "supervisor-main"})   # T1 auto / T2 gated
hydra.answer_worker_question({worker_id: "w-7f3a", content: "Revert the lockfile."})
```

Full tool reference: [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md). Every tool's scope, input/output shape, and refusal rules are there.

### When a worker gets stuck in cloud mode

Same mechanics as local mode — worker returns a `QUESTION:` block, Commander scans memory, and if there's no match:

- **If `upstream_supervisor.enabled=true`** (in `state/connectors/mcp.json`): Commander calls `supervisor.resolve_question({worker_id, question, context, options, recommendation, nearest_memory_match})` on the configured supervisor agent. The supervisor answers (optionally looping its own human through its own channel — Slack, pager, voice call). Commander `SendMessage`s the answer back to the worker AND appends Q+A to `memory/escalation-faq.md` with the citation source tagged `"source": "supervisor"`.
- **If `upstream_supervisor.enabled=false`** (default until configured): Commander labels the ticket `commander-stuck`, stops retries. Same fallback as local mode with no operator online.

The supervisor agent is NOT Hydra's responsibility to implement — Hydra ships the outbound tool contract; you (or your Main Agent vendor) wire up whatever human-facing channel makes sense.

### Observing a cloud Commander

Attach to the Fly tmux session any time from any terminal:

```bash
fly ssh console --app <your-app> -C 'tmux attach -t commander'
```

Or tail the logs:

```bash
fly logs --app <your-app>
```

Health endpoint:

```bash
curl https://<your-app>.fly.dev/health
# {"status":"ok","uptime_s":12345}
```

### What's NOT in cloud mode yet (follow-ups)

- **GitHub webhook receiver** (#40) — when filed issue auto-dispatches Commander without you typing `hydra.pick_up` anywhere.
- **Linear webhook receiver** (#41) — same, for Linear.
- **MCP server binary** — follow-up under #50. Today `state/connectors/mcp.json` is read by nobody; it exists so operators can pre-configure.

Until those land, cloud mode is: Commander running 24/7, you SSH-attach the tmux pane to dispatch work.

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
2. Copy `state/linear.example.json` → `state/linear.json` and fill in team ID(s) + the state/label you want as the trigger (full field reference in [INSTALL.md §Linear](INSTALL.md#optional-linear))
3. In `state/repos.json`, set `"ticket_trigger": "linear"` per repo
4. Launch Commander. It will poll Linear via MCP alongside GitHub.

### What differs from the GitHub flow

| Step | GitHub flow | Linear flow |
|---|---|---|
| Trigger | `assignee` (ticket assigned to you) or `label` (`commander-ready` on the issue) | `assignee` / `state` (e.g. `Ready for Hydra`) / `label` — configured per Linear team in `state/linear.json:teams[].trigger` |
| Pickup signal | `gh issue list --assignee @me` | `linear_list_issues` via the Linear MCP server (see `docs/linear-tool-contract.md` for the exact tool contract) |
| State lock | Labels (`commander-working`) | Linear state transition — by default `Todo` → `In Progress` on pickup (configurable in `state_transitions.on_pickup`) |
| PR open signal back | `gh issue edit --add-label commander-review` | Linear state → `In Review` **and** a comment on the Linear issue linking the GitHub PR |
| PR merged signal back | GitHub closes the linked issue automatically (if `Closes #N` in PR body) | Linear state → `Done` **and** a comment "PR merged." posted on the Linear issue |
| Stuck signal | `commander-stuck` label on the GitHub issue | Linear state → `Blocked` **and** a comment with the stuck reason |

Hydra always opens PRs in the GitHub repo mapped to the Linear team (`state/linear.json:teams[].repo_mapping`). Linear issues don't host code — they host the ticket and the status thread.

### What gets posted back to the Linear issue

Governed by `state/linear.json:comment_on`:

- `worker_started: true` → comment when worker spawns ("Hydra worker started. Branch: ...")
- `pr_opened: true` → comment with the draft PR URL when the worker finishes
- `pr_merged: true` → comment "PR merged." when the operator merges
- `worker_stuck: true` → comment with the stuck reason + last error excerpt
- `question_asked: true` → comment when a worker hits a `QUESTION:` block and pauses

All flippable independently — set any of these to `false` if you want silent behavior for that phase.

### Validating your Linear install

See `docs/linear-tool-contract.md` for the exact tool surface Hydra calls (`linear_list_issues`, `linear_get_issue`, `linear_add_comment`, `linear_update_issue`) and a checklist you should walk through once per workspace before trusting the Linear path on production tickets. Hydra's assumptions about tool names may differ from your actual Linear MCP server — if they do, update the contract doc first, then retarget the scripts via `HYDRA_LINEAR_TOOL_LIST` env vars.

### Fixture-mode smoke test (no Linear needed)

```bash
scripts/linear-poll.sh --fixture self-test/fixtures/linear/mock-list-issues-response.json
```

Returns three normalized issues. Useful for sanity-checking `jq` is present and the script parses responses before hitting real Linear.

## Phase-2 end state (what this turns into)

- Commander moves from your laptop to a cloud VM (stays running 24/7)
- Workers run in managed cloud sandboxes (Claude Managed Agents / Daytona / Modal) that can stand up the full service end-to-end
- Chat surface becomes Slack / web / SMS — you steer from your phone
- Memory + logs live in S3 (via S3 Files mount) so multiple operators/commanders share learnings
- Human interventions become rare and measurable — every one gets captured into escalation-faq, shrinking the next week's intervention rate
