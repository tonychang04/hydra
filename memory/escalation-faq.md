---
name: Worker escalation FAQ
description: Answers to recurring worker questions. Commander reads this before escalating to the supervisor agent. Append new entries whenever the supervisor (or, in legacy direct-drive mode, the operator) answers a novel one.
type: feedback
---

# Worker Escalation FAQ

Commander uses this to answer worker `QUESTION:` blocks without calling the supervisor agent every time. Scan by keyword before escalating. Append new Q+A pairs after an escalation resolves a novel question — whether the answer came from the supervisor's autonomous decision, a human the supervisor looped in, or (in legacy direct-drive mode) the operator typing in a terminal. The contents of the FAQ compound equivalently regardless of which transport produced the answer.

## Format

```
### <short question>
- **Context:** when does this come up
- **Answer:** what the worker should do
- **Source:** ticket or session where this was decided
```

## Pre-existing test / lint / typecheck failures

### Lint script is broken on the baseline. Do I fix it as part of my ticket?

- **Context:** worker runs `npm run lint` and it fails; investigation shows the failure predates the worker's changes (e.g. eslint CLI flag mismatch, missing plugin).
- **Answer:** NO. Do not fix. Note it in your report as a pre-existing baseline issue, confirm your changes don't introduce new lint errors by running lint on a stashed version if needed, and proceed. Opening a separate PR for the lint fix is out of scope for the current ticket.
- **Source:** sdk-js #56 Stage 0, 2026-04-16

### Typecheck shows hundreds of errors. Are they all mine?

- **Context:** monorepo package like `packages/dashboard` where `npm run typecheck` emits 150+ errors.
- **Answer:** Almost certainly pre-existing. Establish a BASELINE: stash your changes, run typecheck, count errors (e.g. 154). Pop stash, run typecheck again, compare. If the count is equal, you're clean. Report both numbers. Don't try to fix baseline errors in this ticket.
- **Source:** insforge #1092 Stage 0, 2026-04-16

### No test runner is configured in the package I'm editing. Should I set one up?

- **Context:** e.g. `packages/dashboard` has no `test` script; no vitest/jest config.
- **Answer:** NO. Don't invent test infrastructure. Note in your report that tests were not added because no runner exists. The commander will flag whether adding test infra is worth its own ticket.
- **Source:** insforge #1092 Stage 0, 2026-04-16

### The repo has no CLAUDE.md or .claude/skills/. What test commands do I use?

- **Context:** older snapshots of a repo may not have agent skill files.
- **Answer:** Fall back to `README.md` + `package.json` scripts. Document the test command you discovered in `memory/learnings-<repo>.md` so future workers don't have to re-derive it.
- **Source:** CLI #50 Stage 0, 2026-04-16

## Package lockfile / dependency drift

### `npm install` changed package-lock.json in ways unrelated to my ticket. Include the changes?

- **Context:** fresh install in a worktree can bump internal versions, strip `"peer": true` markers, etc.
- **Answer:** REVERT the lockfile changes before committing. Your commit should contain only changes necessary for the ticket. Lockfile drift is its own concern.
- **Source:** CLI #50 + sdk-js #56 Stage 0s, 2026-04-16

## Tier escalation

### Ticket looked T1/T2 on the label but the code I need to touch is clearly T3 (auth/migration/infra). What now?

- **Answer:** STOP. Do not proceed. Return with `QUESTION: should I reclassify as T3?` and wait. The commander will either confirm T3 (label the issue, abandon) or route to a different approach with the operator's input. Never push through to a PR that touches T3 paths.
- **Source:** Policy rule from `policy.md`

### Ticket is borderline — small change, but touches a file matching `*auth*`. Am I sure it's T3?

- **Answer:** Default to more restrictive (T3 refuse). Error on the side of caution. If the operator disagrees, he'll reclassify manually and re-queue.
- **Source:** Policy rule from `policy.md`

## Scope

### Fixing the ticket requires a small refactor of an unrelated module to make the code cleanly testable. Do I include it?

- **Answer:** If the refactor is <20 lines and genuinely required for testability, include it with a clear note in the PR body. If >20 lines or optional for correctness, STOP and ask — probably needs a separate ticket.

### Ticket says "X". Code reality is "X and also Y and Z". How much scope do I take?

- **Answer:** Do only X. Note Y and Z in your PR description as "follow-up tickets to file". Stay in scope of what the ticket asked for.

## Host environment pollution

### Test runner hangs or fails with errors about host-level config (e.g. `postcss.config.js`, `tailwindcss` not found).

- **Context:** Vite / similar bundlers walk up the filesystem looking for config files and can load one from the operator's home directory. Worktrees don't have the required host deps installed, so the test runner hangs.
- **Answer:** Create a local stub at the worktree root that neutralizes the parent config (e.g. `postcss.config.cjs` with `module.exports = { plugins: [] };`). Run tests. DELETE the stub before committing. Flag it in your report so the commander can file a permanent fix (adding explicit `css: { postcss: { plugins: [] } }` to `vitest.config.ts` or equivalent) as a separate ticket.
- **Source:** dynamic testing pattern

## PR shape

### Should I include a version bump in my PR?

- **Answer:** NO unless the ticket explicitly asks for it. Version bumps are their own PR. The commander tracks version-bump tickets separately.

### Should I write tests when the ticket doesn't mention them?

- **Answer:** YES if a test runner exists and the change is non-trivial. Missing tests is a quality gap — if the ticket is "fix bug X", a test that reproduces X and now passes is gold. Skip tests only if: (a) no runner exists, (b) change is pure refactor with no behavioral delta, or (c) change is pure CSS/style.

## Docker / env / dynamic testing

### Repo has no test command I can find. Can I make one up?

- **Answer:** First try dynamic discovery: look for `docker-compose.yml`, `Dockerfile`, `Makefile`, `.env.example`. Try `docker compose up -d`, run what looks like the test entrypoint, verify with `curl localhost:PORT/health`. If anything works, **document it in TESTING.md or CLAUDE.md and include in your PR**. If nothing works after 10 minutes of probing, STOP and ask — don't invent a test procedure.
- **Source:** Policy decision, 2026-04-16

### docker-compose wants DB credentials / API keys. Where do I get them?

- **Answer:** Use `.env.example` or `.env.template` placeholders only. Copy to `.env.test`, fill with safe defaults (e.g. `POSTGRES_PASSWORD=test`). NEVER read real `.env*` files (they may have production secrets). If the test genuinely requires a real secret (e.g. third-party API key), STOP and ask the operator to provide it at spawn time.
- **Source:** Security policy, 2026-04-16

### I brought up docker services for testing. Do I leave them running?

- **Answer:** NO. Always `docker compose down` at the end of your ticket, even on failure. Orphaned containers from prior tickets can conflict with the next worker. Include cleanup in your finally block / end-of-work.
- **Source:** Policy decision, 2026-04-16

### curl to external URLs is denied. How do I hit an API I'm integrating with?

- **Answer:** Workers can only curl `http://localhost:*`. For external API testing, use the repo's existing test fixtures, mocks, or sandbox mode. If you genuinely need to hit a real external endpoint, STOP and ask — the operator may provide a proxy or a specific allowed URL.
- **Source:** Permission profile, 2026-04-16

## PR review worker specifics

### I'm a review worker but spotted a bug the PR author should fix. Do I fix it?

- **Answer:** NO. You're a review worker, not an implementation worker. Note the bug as a blocker in your review comment. If the operator agrees, he'll spawn an implementation worker on the ticket (or retry the original PR's worker).
- **Source:** Policy decision, 2026-04-16

### My review found a security issue. Escalation path?

- **Answer:** Mark your review as REQUEST_CHANGES with a `SECURITY:` prefix on the blocker. Label the PR `commander-stuck` (not `commander-rejected`). Commander will page the operator. Never merge or suggest merge of a PR with an unresolved SECURITY: blocker.
- **Source:** Security policy, 2026-04-16

## Linear MCP integration

### Linear MCP tool names don't match `docs/linear-tool-contract.md`. What do I do?

- **Context:** Worker tries to call `linear_list_issues` but `claude mcp call linear linear_list_issues ...` errors with "tool not found." The Linear MCP server has a different naming convention.
- **Answer:** STOP. Do not invent tool names on the fly. Return a `QUESTION:` block describing the mismatch. `scripts/linear-poll.sh` supports env var overrides (`HYDRA_LINEAR_TOOL_LIST`, etc.) but the fix is a PR to `docs/linear-tool-contract.md` (the source of truth) + matching updates to `state/linear.example.json` and `self-test/fixtures/linear/*.json`. Operators without Linear creds cannot validate this — escalate to the operator so they can confirm the real names.
- **Source:** Issue #5 — Linear MCP integration was scaffolded without live-workspace validation; 2026-04-16

### Linear state transition fails with "state 'In Review' not found"

- **Context:** `linear_update_issue` is called after PR open but the team uses a custom state name (e.g. `Code Review` instead of `In Review`).
- **Answer:** Surface ONE message to the operator: "Linear state 'In Review' not found on team <team_id>. Configure state_name_mapping in state/linear.json." Do NOT retry silently. The fix is to populate `teams[0].state_name_mapping` in `state/linear.json` — it maps Hydra's logical state names to the operator's actual Linear state names.
- **Source:** `docs/linear-tool-contract.md` error handling, 2026-04-16

### Linear MCP returns 401/403 mid-session

- **Context:** Auth was fine at session start but a later `linear_*` call fails with auth error.
- **Answer:** OAuth token expired. The worker cannot re-auth itself. Escalate to the operator: "Linear MCP auth expired — please re-run `claude mcp add linear` and reply when done." Until the operator re-auths, skip Linear-triggered tickets (GitHub-triggered tickets still work).
- **Source:** `docs/linear-tool-contract.md` error handling, 2026-04-16

## Issue close semantics

### Do I need to close the issue after merging the PR?

- **Answer:** NO, GitHub does it automatically. Every worker's PR body contains a `Closes #N` line referencing the ticket. On merge, GitHub auto-closes the issue with a back-link to the PR. Don't manually `gh issue close` — that'd add a duplicate close event and look off in the issue timeline.
- **Exception:** if a PR is merged that DOESN'T fully resolve the ticket (e.g. it splits the work and only closes part of it), manually close with `gh issue close <N> --comment "split into follow-ups #X and #Y"`.
- **Exception:** if a duplicate or "won't fix" issue is filed that no PR will address, close manually with `--reason "not planned"` + a comment explaining why.
- **Source:** operational convention, 2026-04-17

## Conflict resolution

These rules govern `worker-conflict-resolver` (and any future automation that merges multiple PRs). They're the source of truth for "what's safe to auto-merge" vs "what has to escalate." Don't expand the additive list without updating this FAQ first.

### When to auto-resolve a conflict vs escalate to the supervisor

- **Context:** `worker-conflict-resolver` (or a human Commander merging in parallel PRs) encounters a merge conflict. The question is always: is this deterministic (safe to resolve mechanically) or semantic (requires a judgment call)?
- **Answer:** Auto-resolve ONLY if the conflict matches one of four additive patterns:
  1. **Both sides added rows to the same markdown table** → keep both rows, in numeric-PR order (lowest PR first). Dedupe exact byte-for-byte matches.
  2. **Both sides appended new sections to the same file** (same heading anchor, new content) → keep both sections, in numeric-PR order.
  3. **Both sides added elements to the same JSON array** → keep both, in numeric-PR order; re-run `jq empty` to validate; fix trailing-comma issues.
  4. **Both sides added keys to the same JSON object** → keep both keys. If they collide on the same key name with different values, STOP — that's semantic.
  Escalate (STOP + emit `QUESTION:` block, no commit) if ANY of these hold:
  - Both sides modified the SAME LINE with different content
  - One side deleted a line the other side modified
  - Both sides renamed the same file to different names
  - Same JSON key with different values
  - Anything you're unsure about
- **Source:** ticket #7, spec `docs/specs/2026-04-16-worker-conflict-resolver.md`, fixture `self-test/fixtures/conflict-resolver/semantic-conflict-example.md`

### Why the additive list is narrow

- **Context:** it's tempting to add "close enough" patterns to the auto-resolve list (e.g. "two modifications that look compatible").
- **Answer:** don't. The whole point of the deterministic path is that operators can trust it without reading every merge diff. Every additive pattern passes a structural test: two sides added NEW things at the same anchor, so concatenation is correct by construction. A modification-vs-modification conflict can never pass that test — by definition, both sides wrote over something that was already there, and concatenating "rewritten" things is nonsense. If you want a new auto-resolve rule, state the structural invariant that makes it safe; if you can't, it's semantic.
- **Source:** ticket #7 design decision, 2026-04-16

### I'm worker-conflict-resolver and a semantic conflict shows up. What do I do?

- **Context:** mid-merge, a conflict region doesn't fit any of the four additive patterns.
- **Answer:** STOP immediately. Do NOT `git add` the conflict markers. Do NOT commit. Emit a `QUESTION:` block with: which PRs, which file and line range, both versions verbatim (short excerpts), your best guess + why, and three options (take A / take B / needs human). Commander either answers from memory or escalates to the supervisor agent. Under no circumstances pick silently — that's how data gets lost.
- **Source:** ticket #7, spec `docs/specs/2026-04-16-worker-conflict-resolver.md`

## When supervisor must be looped in (no heuristic works)

Commander escalates to `supervisor.resolve_question` (see `docs/mcp-tool-contract.md`) whenever the heuristics above don't match. In the legacy direct-drive path (`./hydra` in a terminal, no `upstream_supervisor` configured), the same escalation surfaces as the chat-prompt surfacing in `CLAUDE.md` and the operator answers live. The supervisor agent decides from there whether to answer autonomously or loop its own human — Hydra does not dictate that decision.

Trigger cases:

- Genuinely ambiguous acceptance criteria that memory can't resolve
- Security-adjacent tickets (even T2) where the worker wants a second opinion
- Any suggestion that might break a downstream consumer
- Conflicts between `CLAUDE.md` / `AGENTS.md` and ticket body
- Worker has been stuck on the same failure 2+ times
- A test run requires real production secrets
- A `/cso` review finds a blocker
