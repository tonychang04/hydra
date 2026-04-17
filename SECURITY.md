# Security Policy

## Reporting a vulnerability

If you find a security issue in Hydra — in the framework, worker subagents, permission profile, or anything that could let an agent do something unsafe on an operator's machine — **please do not open a public GitHub issue.**

Instead, email the maintainer directly or use GitHub's [private vulnerability reporting](https://github.com/tonychang04/hydra/security/advisories/new).

Include:
- What you found
- How you found it (repro steps if feasible)
- What the impact could be (what an attacker could do)
- If relevant, a proposed mitigation

Expect an acknowledgment within 72 hours.

## Hydra's own threat model (short version)

Hydra spawns AI agents that run shell commands on your machine. The framework exists to keep those agents from doing anything you didn't sanction. Specifically:

1. **Self-modification is blocked.** The commander's permission profile (`.claude/settings.local.json`) denies the commander session from editing its own `CLAUDE.md`, `policy.md`, `budget.json`, or the `.claude/` directory mid-session. A worker can edit those files in a worktree (to propose changes via PR) but the live session cannot rewrite its own brain.

2. **Worktree FS isolation.** Workers run in git worktrees created from the target repo. They cannot see other worktrees, your home directory, `~/.ssh`, `~/.aws`, `~/.config`, or any `.env`/secret files.

3. **Tier 3 refusal.** Paths matching `*auth*`, `*security*`, `*crypto*`, migrations, `.github/workflows/`, and infra-repo paths are refused at classification time — no worker is ever spawned on them.

4. **No external curl.** Workers cannot curl arbitrary URLs; only `http://localhost:*` is allowed. Web reads go through `WebFetch` which has its own safety layer.

5. **Secrets never travel.** Real `.env*` / `secrets/` / `*.pem` / `*.key` files are in the denylist. Workers use `.env.example` / `.env.template` placeholders for tests.

6. **Merge gates.** The commander refuses to merge T3. T2 merges require passing a separate review-worker pass (which runs `/review` + `/codex review` + `/cso` for security-adjacent PRs).

7. **Kill switches.** `PAUSE` file halts all spawning. Per-ticket wall-clock cap. 2-strike rate-limit auto-disable on autopickup.

## Things operators should still do

- Review the permission profile before first run
- Use a GitHub account with scoped permissions (not a super-admin token)
- Keep `state/repos.json` scoped to the repos you actually want Hydra to touch
- Review PRs before merging (for T2+) — Hydra is not a rubber stamp
- Monitor `logs/*.json` weekly for anything surprising
