# Hydra

**A long-lasting AI agent with many worker heads.** One persistent brain (the **Commander**), many parallel workers (the **heads**). Clears tickets autonomously. Learns from every run. Gradually replaces the human in the loop.

The metaphor is literal: Hydra has one body (the long-running Commander session that keeps memory, tracks state, routes work, and evolves its own policy) and many heads (short-lived worker subagents, one per ticket, each in its own isolated git worktree). Cut off a head (worker fails), two grow back (retry with what was learned). The body is immortal.

## What Hydra does

- Reads GitHub Issues (Linear support planned) — tickets either assigned to the operator or labeled `commander-ready`
- Classifies each ticket by risk tier (T1 auto-merge / T2 human-merge-gate / T3 refuse)
- Spawns N isolated worker subagents in parallel, each on its own ticket in its own git worktree
- Each worker reads the repo's own `CLAUDE.md` / `AGENTS.md` / `.claude/skills/`, discovers how to test the repo (docker, .env.example, Makefile), implements, runs tests, and opens a draft PR
- A separate **review-worker** runs `/review` + `/codex review` on the PR before the human sees it
- Workers return `QUESTION:` blocks when uncertain; Commander answers from its accumulated memory first, pings the human only when memory can't resolve
- Every completed ticket feeds the learning loop: cited patterns → per-repo memory → consistent ones graduate into repo-local skills every future agent inherits

Built on [Claude Code subagents](https://code.claude.com/docs/en/sub-agents) and [superpowers skills](https://github.com/anthropics/superpowers).

## Identity (on purpose, narrow)

Hydra is for **three things. Nothing else:**

1. **Parallel issue-clearing** — N tickets in flight, each isolated, each producing a draft PR
2. **Auto-testing** — workers discover how to test any repo (docker, .env.example, makefile), run it, document what worked. The same primitive self-tests the commander itself.
3. **Future cloud env-spawning** — Phase 2: managed cloud sandboxes so workers can stand up the service end-to-end, not just typecheck. Commander itself graduates from a local Claude Code session to a VM-hosted loop with a Slack / web / SMS chat surface.

Humans are the exception, not the default. Hydra runs while you sleep and pings you only for: merge gates on non-trivial PRs, genuinely novel questions, security tripwires, and weekly retros. Every time it has to ping you, the answer gets captured so it won't need to ping again for a similar question. The goal is a slow, measurable reduction in how often a human is in the loop.

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/tonychang04/hydra.git
cd hydra

# 2. Export your paths
export COMMANDER_ROOT=$(pwd)

# 3. Configure your permission profile
cp .claude/settings.local.json.example .claude/settings.local.json
# Then edit .claude/settings.local.json and replace $COMMANDER_ROOT and $HOME_DIR
# with absolute paths. The deny list for self-modification is critical — don't relax it.

# 4. Configure which repos to poll
cp state/repos.example.json state/repos.json
# Edit state/repos.json to list your repos + their local clone paths.
# Default infra/security-critical repos to enabled:false.

# 5. Authenticate
gh auth status  # must be logged in

# 6. Launch
claude
```

**No labels required up-front.** Commander creates the handful of state labels it uses (`commander-working`, `commander-review`, `commander-stuck`, etc.) lazily on first use.

## How tickets reach the commander

Two trigger modes, configurable per repo in `state/repos.json`:

**Default: assignee trigger**
Assign an issue to yourself (the `gh auth`'d user). Commander polls `gh issue list --assignee @me` and picks it up. Simplest UX — no labels, no extra step. Use this if "assigned to me" naturally means "please take this."

**Alternative: label trigger**
If "assigned to me" is already your personal in-progress field, set `"ticket_trigger": "label"` on a repo. Then commander picks up only issues labeled `commander-ready`. More explicit, slightly more friction.

**Linear (Phase 2):** same shape — assign to the commander's Linear user, OR set a specific status/state like "Ready for commander". Configured per Linear team in `state/linear.json` (coming in Phase 2).

The session loads `CLAUDE.md` as its system prompt, greets you with queue status, and waits. Try `status`, then `show me 3 ready tickets` (inspection only), then `pick up 1` for a real run.

## Mental model

```
You (chat) ──────────────────────────────────────────────┐
                                                         │
Commander (the body: this dir's long-lived claude session)│ ← operator asks
  │                                                      │   question only
  ├─ reads MEMORY.md, policy.md, budget.json             │   when memory
  ├─ polls GitHub issues (label: commander-ready)        │   can't resolve
  ├─ classifies tier (T1 auto-merge / T2 human-merge     │
  │                   / T3 refuse)                       │
  │                                                      │
  ├─ Agent(subagent_type="worker-implementation",        │
  │        isolation="worktree")  ──┐                    │
  │                                 │                    │
  │                                 ▼                    │
  │                       Head (one of many workers —    │
  │                       fresh context, own worktree,   │
  │                       own memory, own permission     │
  │                       scope, short-lived)            │
  │                         ↓                            │
  │                       Reads repo's CLAUDE.md /       │
  │                       AGENTS.md / .claude/skills/    │
  │                         ↓                            │
  │                       brainstorming → plan → TDD     │
  │                         ↓                            │
  │                       Runs tests (docker if needed)  │
  │                         ↓                            │
  │                       /review → /codex review        │
  │                         ↓                            │
  │                       Opens draft PR → labels issue  │
  │                                                      │
  ├─ Agent(subagent_type="worker-review",                │
  │        isolation="worktree")                         │
  │     (runs against the worker's new PR before         │
  │      surfacing to human for merge)                   │
  │                                                      │
  └─ QUESTION: block from a worker ─────────────────────>┘
        (surfaced in chat with nearest memory precedent)
```

## Three worker types (defined in `.claude/agents/`)

| Type | When | Never does |
|---|---|---|
| `worker-implementation` | Any ticket with code changes | Review / discovery |
| `worker-review` | After a PR opens, before human merge gate | Code changes |
| `worker-test-discovery` | When a repo has no working documented test procedure | Source changes |

Each is a proper Claude Code subagent definition (YAML frontmatter with `isolation: worktree`, `memory: project`, `maxTurns`, `skills:` preload, `color:`).

## Chat reference

| You say | Commander does |
|---|---|
| `status` | Summary of running workers + today's quota |
| `show me N ready tickets` | Inspect without spawning |
| `pick up N` | Spawn up to N implementation workers |
| `pick up #42` | Target a specific ticket |
| `review PR #501` | Spawn a review worker on an existing PR |
| `test discover <repo>` | Figure out how to test a repo, commit the docs |
| `classify <ticket text>` | Dry-run the tier classifier |
| `retry #42` | Re-spawn with prior failure as hint |
| `undo #501` | Revert a previously-merged commander PR (within 72h) |
| `pause` / `resume` | Toggle `PAUSE` kill switch |
| `kill <id>` | Stop a runaway worker |
| `merge #501` | T1 auto-merge; T2 requires explicit confirm; T3 refused |
| `reject #501 reason: ...` | Close PR, label `commander-rejected` |
| `quota` / `cost today` | Tickets done + wall-clock + rate-limit health |
| `self-test` | Run the regression harness on golden closed PRs |
| `compact memory` / `promote learnings` | Manual memory hygiene pass |
| `answer #42: <guidance>` | Resolve a paused worker's question |

## Safety layers

1. **Worktree FS isolation** — workers can't see siblings or your home dir
2. **Scoped permission profile** — no `curl` to external URLs, no `rm -rf`, no `sudo`, no reads of `.ssh`/`.aws`/real `.env*`, no self-modification of commander's own CLAUDE.md / policy / settings
3. **Tier 3 refusal** — `policy.md` enumerates paths (auth, migration, infra, secrets, workflows) that refuse outright
4. **Wall-clock cap** — each worker self-terminates past the budget's limit
5. **Concurrency cap** — default 3 workers to prevent rate-limit exhaustion
6. **PAUSE kill switch** — `touch PAUSE` halts all new spawns
7. **Merge gate** — T1 may auto-merge on CI green; T2 always requires human confirm; T3 refused
8. **Rate-limit auto-pause** — auto-pauses 1hr on rate-limit error

## Staged rollout (don't skip)

See `docs/superpowers/specs/2026-04-16-commander-agent-design.md` for the full spec.

- **Rung 1 — smoke test (5 min):** launch, verify state files parse, classify a few test tickets. No spawning.
- **Rung 2 — Stage 0 (30-60 min):** one small already-merged PR, compare worker's diff to the real one
- **Rung 3 — Stage 1 (2 hr):** three closed PRs in parallel, watch label locks
- **Rung 4 — Stage 2 (48 hr):** label real open tickets `commander-dryrun`, walk away, review next morning
- **Rung 5:** graduate T1 auto-merge + full throughput

## Memory & learning

Project-specific knowledge (what works in each repo) lives in `memory/` and is **gitignored** — never committed to this public repo. You keep your own learnings local.

- `memory/MEMORY.md` — index (committed as template)
- `memory/escalation-faq.md` — generic answers to recurring worker questions (committed; framework-level)
- `memory/memory-lifecycle.md` — rules for compaction + promotion (committed)
- `memory/learnings-<repo>.md` — **gitignored**; your per-repo gotchas
- `memory/archive/` — **gitignored**; compacted older entries
- `state/*.json` — **gitignored**; live runtime state
- `logs/*` — **gitignored**; per-ticket audit trail

**Phase 2 knowledge store:** `memory/` and `state/` graduate to S3 (via S3 Files filesystem mount), so multiple commander instances share learnings. See `docs/phase2-s3-knowledge-store.md`.

## Self-test

Changes to your `CLAUDE.md` / worker subagents / `policy.md` can regress worker behavior. The self-test harness runs the commander against golden closed PRs and compares output.

```
self-test            # run all golden cases
self-test <case-id>  # one case
self-test --parallel # up to max_concurrent_workers in parallel
```

Golden cases live in `self-test/golden-cases.json` (gitignored; you populate from your own validated Stage 0 runs). Template: `self-test/golden-cases.example.json`.

## Files

```
commander/
├── CLAUDE.md                              commander's operating loop (committed)
├── README.md                              this file (committed)
├── LICENSE                                MIT (committed)
├── policy.md                              risk-tier rules (committed; tune locally)
├── budget.json                            concurrency + wall-clock caps (committed; tune locally)
├── .claude/
│   ├── settings.local.json                permissions (GITIGNORED — copy from .example)
│   ├── settings.local.json.example        template (committed)
│   └── agents/
│       ├── worker-implementation.md       (committed)
│       ├── worker-review.md               (committed)
│       └── worker-test-discovery.md       (committed)
├── state/
│   ├── repos.json                         your repos (GITIGNORED)
│   ├── repos.example.json                 template (committed)
│   ├── active.json                        runtime (GITIGNORED)
│   ├── budget-used.json                   runtime (GITIGNORED)
│   └── memory-citations.json              runtime (GITIGNORED)
├── memory/
│   ├── MEMORY.md                          index (committed)
│   ├── escalation-faq.md                  generic Q&A (committed)
│   ├── memory-lifecycle.md                rules (committed)
│   ├── tier-edge-cases.md                 stub (committed)
│   ├── worker-failures.md                 stub (committed)
│   ├── learnings-*.md                     per-repo (GITIGNORED)
│   └── archive/                           (GITIGNORED)
├── logs/                                  per-ticket audit (GITIGNORED)
├── self-test/
│   ├── README.md                          (committed)
│   ├── golden-cases.json                  your cases (GITIGNORED)
│   └── golden-cases.example.json          template (committed)
└── docs/
    ├── superpowers/specs/                 design docs (committed)
    └── phase2-s3-knowledge-store.md       S3 plan (committed)
```

## Hard rules (operator-side)

- **Don't edit `CLAUDE.md`, `policy.md`, or `budget.json` while a session is live.** Stop, edit, restart.
- **Review every T2 PR before merging.** Auto-merge is T1 only. Commander refuses to merge T2 without explicit chat confirm.
- **Run `self-test` before committing changes to commander framework files.** Catches regressions from prompt edits.
- **Watch the first week closely.** Read every log. Tune policy/budget from what you see.
- **If anything unexpected touches prod or customer data, say `pause` immediately** and investigate.

## Contributing

This is an opinionated framework. PRs welcome for:
- Bug fixes in worker prompts or safety layers
- Additional worker types that serve the 3-job identity (parallel issue-clearing, auto-testing, cloud env-spawning)
- Phase 2 adapters (Claude Managed Agents, Daytona, Modal, Fly Machines)
- Ticket-source adapters (Linear, Jira)
- S3 knowledge store integration

Out of scope (PRs will be declined):
- Anything that turns Hydra into a general chat assistant
- CEO / design / DX / plan-review workflows (use gstack or similar)
- Deploy controllers / CI replacements
- Features that loosen the self-modification safety rules in the permission profile

## License

MIT. See `LICENSE`.
