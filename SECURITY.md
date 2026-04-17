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

## Evidence map — VERIFIED vs ASSUMED

Each claim above rests on at least one of: an explicit rule in the permission
profile template, a hard-coded branch in a worker prompt, or a runtime check
in a script. "VERIFIED" means we have a receipt — a probe run or a
script-kind self-test that catches the failure mode. "ASSUMED" means the
rule is in place but nobody has produced a receipt yet; the assumption
leans on Claude Code's documented behavior.

| # | Claim | Status | Receipt |
|---|---|---|---|
| 1 | Commander cannot rewrite its own `CLAUDE.md` / `policy.md` / `budget.json` / `.claude/` live | VERIFIED (rule-level) | Explicit `Write`/`Edit` deny rules in `.claude/settings.local.json.example` lines 72–79. |
| 1a | Worker subagents inherit that same deny | ASSUMED → operator-verifiable | Claude Code subagent inheritance docs; receipt pending `./self-test/run.sh --case=permission-probe` operator run. See `docs/security-audit-2026-04-17-permission-inheritance.md`. |
| 2 | Worktree FS isolation — workers cannot read HOME / SSH / AWS / other worktrees | ASSUMED → operator-verifiable | Deny rules `Read($HOME_DIR/.ssh/**)` and friends in the template; receipt pending probe actions 1–3 (audit doc). |
| 3 | Tier 3 refusal blocks workers on sensitive paths | VERIFIED | Hard branch in `.claude/agents/worker-implementation.md` lines 52 and `policy.md`. |
| 4 | No external curl | ASSUMED → operator-verifiable | Only `Bash(curl ... http://localhost:*)` allow-listed; external falls through. Receipt pending probe action 4 (audit doc). |
| 5 | Secrets never travel in logs or agent output | VERIFIED (rule-level) | Deny rules `Read(**/.env)`, `Read(**/secrets/**)`, `Read(**/*.pem)`, `Read(**/*.key)`. Receipt on worker-side pending probe action 3. |
| 6 | Merge gates — no T2 or T3 auto-merge | VERIFIED | Hard branches in `.claude/agents/worker-review.md` and Commander's `Safety rules (hard)` section in `CLAUDE.md`. |
| 7 | Kill switches — PAUSE, wall-clock cap, 2-strike rate-limit | VERIFIED | `self-test/golden-cases.example.json:autopickup-tick-behavior` exercises all three (SKIP kind today, but the fixture is canonical). |

Until probe actions have observed results, the ASSUMED rows are best
described as "documented but not proven". This is the gap
`docs/security-audit-2026-04-17-permission-inheritance.md` closes.

## Verification procedure

**When to run this:** before trusting Hydra with a production-adjacent
repo; after upgrading Claude Code; after any PR that modifies
`.claude/agents/*.md` or `.claude/settings.local.json.example`; quarterly
as hygiene.

1. Copy `.claude/settings.local.json.example` to
   `.claude/settings.local.json`. Replace `$COMMANDER_ROOT` with your
   absolute path and `$HOME_DIR` with your `$HOME`. Do not relax any
   deny rule.
2. Smoke-test the probe script as plain shell (no security guarantee,
   just schema check):

   ```bash
   bash self-test/fixtures/permission-probe/probe-script.sh \
        --worktree-root "$PWD" \
        --output /tmp/probe-smoke.jsonl
   wc -l /tmp/probe-smoke.jsonl   # expect: 9
   jq -c . /tmp/probe-smoke.jsonl # each line valid JSON
   ```

3. Run the real probe: start a real Commander session (`./hydra`),
   spawn a worker that executes the probe script, collect the JSONL
   output. Full instructions in
   `self-test/fixtures/permission-probe/README.md`.
4. Diff observed vs `self-test/fixtures/permission-probe/expected-outcomes.json`.
   Any delta is a finding; file a follow-up issue with the JSONL
   snippet as evidence.
5. Fill the Remediation checklist at the end of
   `docs/security-audit-2026-04-17-permission-inheritance.md`.

When the self-test runner's `worker-subagent` executor lands (ticket #15
follow-up), step 3 becomes automatic via
`./self-test/run.sh --case=permission-probe`.

## Things operators should still do

- Review the permission profile before first run
- Use a GitHub account with scoped permissions (not a super-admin token)
- Keep `state/repos.json` scoped to the repos you actually want Hydra to touch
- Review PRs before merging (for T2+) — Hydra is not a rubber stamp
- Monitor `logs/*.json` weekly for anything surprising
- Run the permission probe after any upstream Claude Code upgrade (see Verification procedure)
