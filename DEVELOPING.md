# Developing Hydra

For contributors improving Hydra itself. If you just want to *use* Hydra on your own repos, see **[USAGE.md](USAGE.md)** instead.

The two workflows are deliberately distinct:

| Path | File | Who | Where memory lives | How you dispatch work |
|---|---|---|---|---|
| **Use** Hydra | [USAGE.md](USAGE.md) | Operators running it on their own repos | `$HYDRA_EXTERNAL_MEMORY_DIR` (default `~/.hydra/memory/`) — outside this repo | File issues in YOUR repos, assign to self |
| **Develop** Hydra | this file | Contributors improving the framework | `./memory/` in-repo (framework-level only) | File issues on `tonychang04/hydra`, dogfood via Hydra itself |

## The dogfood principle

**Hydra builds Hydra.** Every change to Hydra goes through Hydra's own process: a spec in `docs/specs/`, a worker-implementation PR, a worker-review pass, then human merge. Proves the system works; produces the compounding "why" memory as a byproduct.

Concretely, to work on Hydra the way Hydra would work on it:

1. Ensure `tonychang04/hydra` (or your fork) is in `state/repos.json` with `"local_path"` pointing to your local clone of this repo
2. File an issue on that repo describing the change
3. Assign to yourself (or label `commander-ready` if you use label-trigger)
4. In your Commander chat: `pick up #N`
5. A worker head reads the ticket, writes a spec to `docs/specs/YYYY-MM-DD-<slug>.md`, implements, commits, opens a draft PR
6. Commander spawns `worker-review`, which runs `/review` + `/codex review` on the PR
7. You merge after reading the diff + auto-review

The only special case: if the change might regress worker behavior (worker-implementation.md, worker-review.md, worker-test-discovery.md, CLAUDE.md, policy.md, permission profile), the human reviewer MUST run `self-test` before merging. See below.

## Spec-driven is non-negotiable

Every non-trivial change writes a spec in `docs/specs/YYYY-MM-DD-<slug>.md` **before** code. See `docs/specs/README.md` and `docs/specs/TEMPLATE.md`.

"Non-trivial" = anything touching CLAUDE.md, worker subagents, policy, memory lifecycle, permission profile, escalation protocol, or architecture. Typo fixes and dep-patch bumps can skip.

The spec lives in the PR alongside the code and is never deleted — when later work supersedes a decision, the spec's `status:` frontmatter changes to `superseded` and a pointer to the new spec is added.

## Testing your changes

Three layers, in order of cost:

### 1. Syntax + static checks (seconds)
```bash
bash -n setup.sh                      # shell syntax
jq . state/*.example.json             # json validity
# For any markdown with frontmatter: manually check required fields
```

### 2. Self-test harness (minutes)

Runs the commander against golden closed PRs in `self-test/golden-cases.json` in dry-run mode and diffs the worker's output against known-good assertions. Catches regressions from prompt edits without needing real tickets.

```bash
# From inside a Commander chat session:
self-test                    # all cases
self-test cli-50             # one case
self-test --parallel         # all, concurrently
```

Before landing any change to a worker subagent, CLAUDE.md, policy.md, or permission profile: **run self-test and confirm all golden cases still pass**. If a case fails, either the change regressed behavior (fix it) or the assertion was wrong (update it — rare, document why in the PR).

You populate `self-test/golden-cases.json` locally from your own validated Stage-0 runs (see `self-test/README.md`). Template: `self-test/golden-cases.example.json`.

### 3. End-to-end (hours, manual)

The golden path across a real repo with a real ticket. Use when:
- You've changed the worktree/spawn primitives
- You've changed how workers interact with `gh` or Linear MCP
- You're migrating to Phase 2 cloud backends

Manual because it requires launching a live Commander session, filing a real test ticket, watching a worker execute, and verifying the PR. No CI equivalent yet (speccing one in a draft doc — contributions welcome).

## What NOT to touch without a spec + deliberation

- The self-modification deny list in `.claude/settings.local.json.example` — this prevents Commander from loosening its own permissions mid-session. If you think you need this changed, write a spec explaining the threat model.
- Tier 3 categories in `policy.md` — these are the "refuse" rules that keep Hydra away from auth, migrations, infra. Only change with a team-of-one post-mortem and a spec.
- The `isolation: worktree` field in worker subagents — removing it means workers can trash the main repo. There is no reason to remove it.

## Directory layout (what's committed vs gitignored)

```
hydra/
├── CLAUDE.md                              committed (commander brain)
├── README.md                              committed (landing)
├── USAGE.md                               committed (for operators)
├── DEVELOPING.md                          committed (this file)
├── LICENSE                                committed
├── setup.sh                               committed (one-time init)
├── policy.md                              committed (risk tiers)
├── budget.json                            committed (default caps)
├── .claude/
│   ├── settings.local.json                GITIGNORED (your absolute paths)
│   ├── settings.local.json.example        committed (template, setup.sh fills in)
│   └── agents/worker-*.md                 committed (subagent definitions)
├── state/
│   ├── repos.example.json                 committed (template)
│   ├── linear.example.json                committed (template)
│   └── *.json                             GITIGNORED (runtime + your config)
├── memory/                                FRAMEWORK memory only (committed):
│   ├── MEMORY.md                            index of framework files
│   ├── escalation-faq.md                    generic Q&A for workers
│   ├── memory-lifecycle.md                  compaction + promotion rules
│   ├── tier-edge-cases.md                   stub
│   └── worker-failures.md                   stub
├── self-test/
│   ├── README.md                          committed
│   ├── golden-cases.example.json          committed (template)
│   └── golden-cases.json                  GITIGNORED (your validated cases)
├── docs/
│   ├── phase2-s3-knowledge-store.md       committed (design)
│   └── specs/                             committed (living history of why)
│       ├── README.md
│       ├── TEMPLATE.md
│       └── YYYY-MM-DD-*.md
├── logs/                                  GITIGNORED (runtime)
├── .hydra.env                             GITIGNORED (local env)
└── hydra                                  GITIGNORED (generated launcher)
```

Operational memory (`learnings-<repo>.md` about external repos you clear tickets in) lives in `$HYDRA_EXTERNAL_MEMORY_DIR` (default `~/.hydra/memory/`), outside this repo entirely. See `docs/specs/2026-04-16-external-memory-split.md`.

## Out-of-scope contributions (PRs will be declined)

- Anything turning Hydra into a general chat assistant
- CEO / design / DX / plan-review workflows (use gstack for those)
- Deploy controllers / CI replacements
- Removing the self-modification deny list
- Features that blur the 3-job identity (parallel issue-clearing, auto-testing, future cloud env-spawning)

## First-time contributor checklist

- [ ] Clone fork, run `./setup.sh`
- [ ] Add `tonychang04/hydra` (or your fork) to your `state/repos.json`
- [ ] Find a spec in `docs/specs/` marked `status: draft` that you want to implement — OR file an issue describing a new one
- [ ] Launch `./hydra`
- [ ] `pick up #<your-issue-number>`
- [ ] Let a worker do the first pass; you review and refine
- [ ] Run `self-test` before merging
- [ ] Merge, watch what happens in your next real use
