# Hydra MCP Tool Contract (agent-only interface)

Status: **CONTRACT ONLY — no server binary yet.** This PR lands the tool schemas (`mcp/hydra-tools.json`), this human-readable mirror, the connector config template (`state/connectors/mcp.json.example`), and the escalation plumbing. A follow-up PR ships the actual MCP server process. Everything below describes the surface that server will expose — client agents can plan against it today.

This document defines the agent-only interface Hydra offers to authorized MCP clients. The term **agent-only interface** is canonical; use it consistently in issues, commit messages, and docs.

Read this alongside:

- `mcp/hydra-tools.json` — the machine-readable tool schemas (JSON Schema per tool). Tooling reads that file; humans read this one.
- `state/connectors/mcp.json.example` — auth + transport config template.
- `docs/specs/2026-04-16-mcp-agent-interface.md` — the spec that motivates this contract.

If this document diverges from `mcp/hydra-tools.json`, **the JSON is authoritative** and this doc is the bug. Open a PR to sync.

---

## Why an agent-only interface

Hydra's three core jobs (parallel issue-clearing, auto-testing, cloud env-spawning) are machine-to-machine work. The happy path has no human in it. A chat UI is the wrong primary surface — it implies humans dispatch the work, when actually humans file a ticket and walk away.

The agent-only interface inverts that: another agent (the operator's supervisor agent, a team's ops agent, another Hydra instance, a dashboard bot) drives Hydra via MCP. Commander is headless. The supervisor agent wraps whatever human-facing channel exists — Slack, voice, pager — so Hydra never has to know.

The existing terminal-chat path (type `pick up 2` in `./hydra`) is not removed. It's legacy / direct-drive mode, useful for debugging and single-operator setups. The agent-only interface is additive.

---

## Scope levels

Every tool declares a scope. Tokens are granted one or more scopes in `state/connectors/mcp.json:authorized_agents[].scope`. Commander refuses tool calls that require a scope the caller's token doesn't hold.

| Scope | What it allows | Grant to |
|---|---|---|
| `read` | Non-mutating observation (status, lists, logs, retros) | Any orchestration or dashboard agent |
| `spawn` | Worker spawns, review spawns, answering paused workers | Agents that plan and dispatch work |
| `merge` | Merge or reject PRs (T3 always refused regardless) | Agents cleared for merge authority |
| `admin` | Pause, resume, kill workers | Supervisor-proxy agents only |

Scopes stack. A token with `["read", "spawn"]` can call everything in `read` plus everything in `spawn`, but nothing in `merge` or `admin`.

T3 refusal is a hard rule enforced below the scope check. Even an `admin`-scoped token cannot merge a T3 PR through this interface — `policy.md` is authoritative.

---

## Tools

### `hydra.get_status`

**Scope:** `read`

Return Commander's current runtime state — active workers, today's counters, pause/autopickup flags, quota health.

**Use cases:**
- Dashboard agent polls every 30s to render status widgets.
- Supervisor agent checks `paused` and `active_workers.length` before calling `hydra.pick_up` to avoid wasted calls.
- Self-health check by the MCP server itself.

**Tradeoffs:** cheap and idempotent — safe to poll. Does not reveal per-ticket detail (use `hydra.get_log` for that).

**Input:** empty object `{}`.

**Output:**
```json
{
  "active_workers": [{"id": "w-7f3a", "ticket": "owner/repo#N", "repo": "...", "tier": "T2", "subagent_type": "worker-implementation", "started_at": "...", "state": "running"}],
  "today": {"done": 3, "failed": 0, "wall_clock_min": 42},
  "paused": false,
  "autopickup": {"enabled": true, "interval_min": 30, "last_run": "..."},
  "quota_health": {"github_rate_limit_ok": true, "linear_rate_limit_ok": true}
}
```

---

### `hydra.list_ready_tickets`

**Scope:** `read`

Preview the queue that would be spawned on the next pickup. Inspection only — never spawns.

**Use cases:**
- Agent inspects the queue before deciding whether to trigger a pickup or wait for a smaller backlog.
- Supervisor agent presents options to a human when the human asked "what is Hydra about to work on?".

**Tradeoffs:** unlike `hydra.get_status` this one DOES poll GitHub / Linear under the hood — counts against rate limits. Don't call in a tight loop.

**Input:**
- `limit` (optional, default 10, max 100): how many tickets to return.
- `repo` (optional): `owner/name` filter; omit to span all enabled repos.

**Output:** `{tickets: [{repo, num, title, tier_guess, labels, source}]}`.

---

### `hydra.pick_up`

**Scope:** `spawn`

Spawn up to N `worker-implementation` agents on ready tickets. This is the agent-facing equivalent of the operator's `pick up N` chat command.

**Use cases:**
- Supervisor agent schedules a batch after CI recovery.
- Time-based trigger (cron-style) from an external orchestrator.

**Tradeoffs:** preflight enforced — PAUSE, concurrency cap, daily cap, rate-limit health. If preflight fails, `spawned` is empty and `preflight_blocked_reason` is set. Caller should not retry immediately on preflight failures; respect backoff.

**Input:**
- `count` (optional, default 1, max 20)
- `filter.repo` (optional)
- `filter.tier_max` (optional, `T1` or `T2`)

**Output:** `{spawned: [worker_id, ...], skipped: [...], preflight_blocked_reason: null | string}`.

---

### `hydra.pick_up_specific`

**Scope:** `spawn`

Spawn on one specific ticket by `(repo, issue_num)`. Still respects tier (T3 refused) and preflight.

**Use cases:**
- Supervisor agent prioritizes a known-urgent ticket over whatever the default poll would select.
- Retry after a previous `commander-stuck` was resolved by the supervisor.

**Tradeoffs:** takes precedence over the default trigger order but NOT over preflight. If another worker is already in flight on the same issue, returns `refused_reason: "already-in-flight"`.

**Input:** `{repo, issue_num}`.

**Output:** `{worker_id, tier, refused_reason}`.

---

### `hydra.review_pr`

**Scope:** `spawn`

Spawn a `worker-review` subagent against an existing PR. This is Commander's review gate — deliberately a separate agent from the implementer so context bias doesn't leak in.

**Use cases:**
- Supervisor agent routes a human-filed PR through Hydra's review pipeline.
- Re-review after a `worker-implementation` pushed a fix in response to previous blockers.

**Tradeoffs:** blocking-style return — the MCP call stays open until the review worker finishes (bounded by the worker's wall-clock cap). For long reviews, consider calling `hydra.get_log` instead and polling.

**Input:** `{pr_num, repo?}`.

**Output:** `{review: {verdict, blockers, concerns, nits}, worker_id}`.

---

### `hydra.merge_pr`

**Scope:** `merge`

Merge a PR subject to tier policy: T1 auto-merges on CI green, T2 requires caller attestation, T3 is always refused.

**Use cases:**
- Supervisor agent approves a T2 PR on behalf of a cleared human.
- Auto-pipeline for T1-only repos.

**Tradeoffs:** `caller_agent_id` is recorded in `logs/<ticket>.json` as the merge authorizer — this is the accountability trail. Refusing to merge T3 is a safety rail that cannot be overridden through MCP; if a T3 change must ship, the human + supervisor agent route through GitHub's native merge UI, not Hydra.

**Input:** `{pr_num, caller_agent_id, repo?}`.

**Output:** `{merged, merged_at, sha, refused_reason}`.

---

### `hydra.reject_pr`

**Scope:** `merge`

Close a PR as rejected. Adds `commander-rejected` label and posts `reason` as a close comment.

**Use cases:**
- Review verdict was `blockers` and retries exhausted.
- Supervisor override — the work is no longer needed.

**Tradeoffs:** not reversible through MCP — reopening requires GitHub-native reopen + a fresh `hydra.pick_up_specific`.

**Input:** `{pr_num, reason, repo?}`.

**Output:** `{closed, closed_at}`.

---

### `hydra.answer_worker_question`

**Scope:** `spawn`

Resolve a worker paused on a `QUESTION:` block. Commander `SendMessage`s the worker with `content` and appends the Q+A to `memory/escalation-faq.md`.

**Use cases:**
- Supervisor agent's `resolve_question` handler returned an answer (the normal upstream escalation flow).
- Direct-drive override — the caller agent supplies an answer without going through the upstream supervisor at all.

**Tradeoffs:** writing to `memory/escalation-faq.md` is the learning loop. If the caller supplies a junk answer, future workers will re-apply it. Callers should be confident in the guidance before calling this tool.

**Input:** `{worker_id, content}`.

**Output:** `{acknowledged, appended_to_faq}`.

---

### `hydra.pause` / `hydra.resume`

**Scope:** `admin`

Toggle the `PAUSE` sentinel file. `pause` blocks new spawns but lets in-flight workers finish. `resume` clears the sentinel; a separate `hydra.pick_up` is required to actually spawn.

**Use cases:**
- Investigating a rate-limit anomaly — pause, inspect, resume.
- Controlled rollout across multiple Hydra instances.

**Tradeoffs:** idempotent — repeated calls are no-ops. Does NOT cancel in-flight workers; use `hydra.kill_worker` for that.

**Input/Output:** see `mcp/hydra-tools.json`.

---

### `hydra.retro`

**Scope:** `read`

Generate the weekly retrospective markdown for an ISO year-week (defaults to current). Writes `memory/retros/YYYY-WW.md` and returns the body.

**Use cases:**
- Supervisor agent fetches Monday-morning retro to summarize the week to its human.
- Long-running audit bot archives retros to cold storage.

**Tradeoffs:** overwrites if called twice in the same week — retros are cumulative for the week, not append-only. If the caller wants historical stability, snapshot the response.

**Input:** `{week?: "YYYY-Www"}`.

**Output:** `{markdown, week, path}`.

---

### `hydra.get_log`

**Scope:** `read`

Return the per-ticket audit log (`logs/<ticket>.json`) by either ticket coordinates or worker id.

**Use cases:**
- Supervisor agent diagnosing why a worker hit `commander-stuck`.
- Dashboard agent rendering a per-ticket timeline.

**Tradeoffs:** log shape is stable but not yet schema-formalized (follow-up: `state/schemas/log.schema.json`). Callers should defensively tolerate missing fields.

**Input:** one of `{ticket_num, repo}` OR `{worker_id}`.

**Output:** `{log: <log-json>}`.

---

### `hydra.file_ticket`

**Scope:** `spawn`

File a new GitHub issue into an enabled repo and surface whether the next autopickup tick will pick it up. Primary use case: Main Agent (the operator's Claude Code session on their laptop) converts a spoken complaint — "the settings page needs an icon" — into a Hydra ticket via one MCP call, shrinking the "human notices something" → "Commander is on it" gap from ~90 seconds of manual transposition to ~3 seconds of "yes, file it."

**Use cases:**
- Main Agent listens to the human, offers to file, calls this tool, shows the URL back. Human countermands if wrong.
- A monitoring agent noticing a regression files a ticket automatically and walks away.
- A CI bot opens a ticket when a nightly job fails in a non-urgent way.

**Tradeoffs:** rate-limited to 10 calls/hour per authorized agent (rolling window; counter in `state/mcp-rate-limit.json`). Exceeds → structured refusal with `error: "rate-limited"` and `retry_after_sec`. This is a hard cap that protects target repos from runaway Main Agent loops — if you need more, either open a follow-up ticket to widen the limit or rotate to a second agent id. The tool does NOT spawn a worker directly; it queues via the usual autopickup tick, so the caller sees `will_autopickup: true` and then the autopickup scheduler picks up on its next interval.

**T3 handling:** `proposed_tier: "T3"` is allowed but auto-refused — the issue is filed with `commander-stuck` instead of `commander-ready`, the body is prefixed with a T3 notice, and the return value reports `will_autopickup: false` with `reason: "proposed_tier=T3 (Commander refuses T3 autopickup)"`. Commander never merges T3; filing as T3 is the same deal.

**Input:**
- `repo` (required) — `owner/name`; must have `enabled: true` in `state/repos.json`, else `error: "repo-not-enabled"`.
- `title` (required) — ≤ 120 chars.
- `body` (required, markdown) — combined with title must be ≥ 20 chars (anti-spam).
- `proposed_tier` (optional) — `T1` / `T2` / `T3`. Commander still re-classifies per `policy.md` before spawning.
- `labels` (optional, string[]) — appended to the commander-default labels.
- `auto_pickup` (optional, default `true`) — if `false`, `commander-ready` is NOT applied, so autopickup skips. Useful for filing draft tickets the caller wants to inspect first.

**Output:** `{issue_number, issue_url, will_autopickup, reason?}`. `reason` is populated iff `will_autopickup` is `false`.

**Example request:**
```json
{"repo": "tonychang04/hydra", "title": "Add icon to settings page", "body": "The settings page header has no icon next to each section title."}
```

**Example response:**
```json
{"issue_number": 142, "issue_url": "https://github.com/tonychang04/hydra/issues/142", "will_autopickup": true, "reason": null}
```

**Error shapes (wire format):** all errors are tool-call results with `isError: true` and `structuredContent: {error, reason, ...}`:
- `{"error": "validation-error", "reason": "title exceeds 120 chars (got 121)"}`
- `{"error": "repo-not-enabled", "reason": "repo 'foo/bar' is not enabled in state/repos.json — add or enable it before filing."}`
- `{"error": "rate-limited", "reason": "...", "limit": 10, "window_sec": 3600, "retry_after_sec": 847}`
- `{"error": "gh-failure", "reason": "gh issue create exited 1: ..."}`

**Not in scope (see ticket #143):** filing to Linear (follow-up once the Linear trigger lands), fan-out to multiple repos, bypass of the autopickup tick.

Spec: `docs/specs/2026-04-17-main-agent-filing.md`.

---

### `hydra.kill_worker`

**Scope:** `admin`

Forcibly stop a worker via TaskStop. Labels the ticket `commander-stuck`.

**Use cases:**
- Worker wall-clock runaway.
- Supervisor agent overrides an in-flight job because the underlying ticket changed.

**Tradeoffs:** irreversible for that worker. Retrying the same ticket requires `hydra.pick_up_specific` — Commander will spawn a fresh worker.

**Input:** `{worker_id, reason?}`.

**Output:** `{killed, killed_at}`.

---

## Escalation flow (Commander as MCP client)

Commander is also an MCP **client** for exactly one upstream tool: `supervisor.resolve_question`. When a worker returns a `QUESTION:` that doesn't match `memory/escalation-faq.md`, Commander calls:

```
supervisor.resolve_question({
  worker_id, question, context, options, recommendation, nearest_memory_match
}) → {answer: string, confidence: 0-1, human_involved: bool}
```

The supervisor agent decides whether to answer from its own context or loop a human via its own channel. Hydra doesn't know and doesn't care which — from Hydra's perspective the supervisor is always the "thing that resolves a question". If no supervisor is configured (or `upstream_supervisor.enabled=false`), Commander falls back to the legacy behavior: label the ticket `commander-stuck` and stop retrying.

The supervisor contract is narrow on purpose. Hydra doesn't need supervisor tools for anything else — not for status, not for approval, not for retros. Those flow the other direction (supervisor calls `hydra.*`). Keeping the upstream surface to one tool keeps the mental model legible.

---

## Audit

Every tool call is appended to `logs/mcp-audit.jsonl`:

```json
{"ts": "2026-04-16T21:00:00Z", "caller_agent_id": "supervisor-main", "tool": "hydra.merge_pr", "scope_check": "ok", "refused_reason": null}
```

No request/response bodies are logged — they may contain repo snippets that are sensitive. The envelope is enough to reconstruct accountability.

---

## Operator validation checklist

Once the follow-up PR lands the actual server binary, walk this list before exposing the MCP surface:

- [ ] `mcp/hydra-tools.json` parses with `jq`
- [ ] `state/connectors/mcp.json` exists (copied from `.example`) and has at least one `authorized_agents[]` entry with a real `token_hash`
- [ ] `token_hash` is the SHA-256 of a token stored securely (password manager, 1Password CLI, not in the repo)
- [ ] Client agent can call `hydra.get_status` and receive a valid response
- [ ] Calling a `spawn`-scoped tool with a `read`-only token gets refused
- [ ] `upstream_supervisor` is configured AND a mock `supervisor.resolve_question` returns sensibly before enabling
- [ ] If `transport: http`, the bind address is loopback OR a reverse proxy with TLS is in front

Until every box is ticked, operate in legacy direct-drive mode (`./hydra` in a terminal).

---

## Why this contract exists as an explicit doc

Two reasons:

1. **Schema-first prevents drift.** Writing the tool schemas before the server binary forces clarity on return shapes, error cases, and scope boundaries. When the server lands, the tests are obvious.
2. **Client agents can plan against a stable surface.** Other teams writing supervisor agents don't have to grep the Hydra source — they read this doc and `mcp/hydra-tools.json` and know exactly what's callable.

Think of this as Hydra's agent-facing SPI: change it deliberately, not by accident. Breaking changes get major version bumps on `mcp/hydra-tools.json:_version` and a deprecation note in this file.
