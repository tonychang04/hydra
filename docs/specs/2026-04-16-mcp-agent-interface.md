---
status: draft
date: 2026-04-16
author: hydra worker (issue #50)
---

# Hydra as MCP server: agent-only interface

Implements: ticket #50 (T2). Supersedes #42 (Slack bot) and #49 (Discord bot), both closed as "not planned".

## Problem

Hydra's three core jobs (parallel issue-clearing, auto-testing, cloud env-spawning) are machine-to-machine. The happy path never involves a human. Yet the only way an operator drives Hydra today is by opening a terminal, running `./hydra`, and typing `pick up 2` into a Claude Code chat. That's:

- **The wrong primary surface.** A chat UI implies humans dispatch the work, when actually humans file a ticket and walk away.
- **Not composable.** Another agent — the operator's supervisor, a team's ops bot, a dashboard bot — can't drive Hydra without awkwardly wedging itself between stdin and stdout of a terminal session.
- **Not deployable.** A cloud-hosted Commander (Phase 2 direction) has no human terminal. Something needs to drive it programmatically.

Earlier spike proposals (#42 Slack bot, #49 Discord bot) tried to solve the "Hydra in the cloud" version of this by adding chat-platform integrations. Both were rejected as wrong-level: adding N adapters to chat platforms is per-platform work that conflicts with "Hydra is agent-to-agent".

The right interface is MCP. Every agent ecosystem already speaks it. Claude Code already speaks it. Custom supervisor agents, CI systems, dashboard bots — all can speak it with minimal glue.

## Goals

- A committed, versioned tool schema (`mcp/hydra-tools.json`) declaring every public verb an authorized client agent can call: status, list, pick_up (both forms), review, merge, reject, answer-worker-question, pause/resume, retro, get_log, kill_worker. Full JSON Schema per tool.
- A human-readable mirror (`docs/mcp-tool-contract.md`) that agents' authors can read without parsing JSON.
- A connector config template (`state/connectors/mcp.json.example`) with three concepts: server (inbound), authorized_agents (per-agent tokens + scopes), upstream_supervisor (outbound escalations).
- Escalation plumbing that stops treating "the human" as a first-class concept in Commander's prompt. Instead, there is "the supervisor agent", and the supervisor wraps the human (if there is one). This is the mental-model shift that unblocks headless Commander.
- Install docs updated with a third option (agent-driven install / Phase 2 direction) alongside the existing terminal-chat options.
- Legacy terminal-chat path remains fully supported. MCP is additive, not replacement.

## Non-goals

- **Not implementing the MCP server binary.** This PR lands the contract, config, docs, and escalation edits. The actual server process (stdio + HTTP transport) is a follow-up ticket.
- **Not implementing a supervisor agent.** Hydra ships the outbound surface (`supervisor.resolve_question` contract) and the config hook. The supervisor agent itself is someone else's code.
- **Not replacing workers' `QUESTION:` block protocol.** Workers continue to emit `QUESTION:` blocks exactly as today. Only Commander's handling downstream changes.
- **Not adding a chat-platform bot.** #42 and #49 are superseded. A read-only web dashboard is still allowed (different ticket, different surface).
- **Not changing risk tiers or merge policy.** `policy.md` is unchanged. T3 refusal is enforced below the scope check; even an `admin`-scoped token cannot merge a T3 PR through MCP.

## Proposed approach

### Three artifacts + one mental-model shift

**1. Tool schemas (`mcp/hydra-tools.json`).** One JSON file with a `tools[]` array, each entry declaring `name`, `description`, `scope`, `input_schema` (JSON Schema), `output_schema`, `example_request`, `example_response`. A future MCP server reads this file at startup and serves the declared tools. Tooling stays in sync because this file is the source of truth — no hand-written adapters that can drift.

**2. Human mirror (`docs/mcp-tool-contract.md`).** Prose walkthrough of each tool: use cases, tradeoffs, input/output shapes. Written for the author of a supervisor agent who wants to decide which tools to call when. Mirrors the JSON — if they diverge, JSON wins.

**3. Connector config (`state/connectors/mcp.json.example`).** Three sections:
- `server`: inbound transport (stdio or http) + bind address + port.
- `authorized_agents[]`: one entry per agent allowed to call Hydra. Token is NEVER committed — only the SHA-256 hash (`token_hash`). Scope is an array of `["read", "spawn", "merge", "admin"]`.
- `upstream_supervisor`: outbound config for `supervisor.resolve_question`. Disabled by default — when disabled, Commander falls back to labeling unresolved questions `commander-stuck`.

**4. Mental-model shift (prompt edits).** Commander's `CLAUDE.md` has a "When to involve the human" section and a "Three-tier decision protocol" diagram. Both treat "the operator" / "the human" as first-class. This spec changes both to:

- Rename the section: "When Commander can't resolve from memory — escalate to supervisor agent".
- Flow becomes: `worker QUESTION → memory lookup → if miss, call supervisor.resolve_question → supervisor answers (possibly looping its own human) → Commander SendMessage(worker, answer) + append to escalation-faq`.
- The human is not removed from the repo. The human is still there — but Hydra talks to the supervisor, and the supervisor talks to the human if necessary. This is the abstraction that makes Commander headless.

Worker subagent prompts (`worker-implementation.md`, `worker-review.md`, `worker-test-discovery.md`) are **unchanged**. Workers still emit `QUESTION:` blocks. Only Commander's downstream handling changes. This keeps the worker contract stable across the MCP migration.

### Three auth scope levels

The four scope levels (`read`, `spawn`, `merge`, `admin`) map to real accountability boundaries:

- **`read`** is safe to grant broadly — a dashboard bot, a metrics collector, another Hydra instance checking peer status. No way to cause work or cost.
- **`spawn`** triggers workers — which cost minutes and quota. Grant to agents that are cleared to plan work but NOT to approve what those workers produce.
- **`merge`** is the authority to ship. Kept separate from `spawn` so a planning agent can't also approve its own output. (An agent holding both is fine, but it should be a deliberate choice.)
- **`admin`** is lifecycle — pause, resume, kill. Grant to supervisor-proxy agents only.

T3 refusal is a safety rail below the scope check. `admin` + `merge` on a T3 PR still refuses. That's policy, not scope.

### Alternatives considered

- **Chat-platform bots (#42 Slack, #49 Discord).** Rejected: per-platform glue for every platform, doesn't compose across ecosystems, pulls Hydra toward being a chat app.
- **HTTP REST API.** Rejected: reinvents what MCP already gives us (capability discovery, typed schemas, trust-scoped handshake). REST would need custom auth, custom schema serving, custom discovery.
- **Named pipe / Unix socket with JSON lines.** Rejected: same reinvention problem as REST, plus no network-reachable variant.
- **Single "hydra.exec" tool that takes arbitrary commander chat strings.** Tempting (minimal surface) but terrible: no schema, no scope boundaries, agents would guess syntax. Dropped.

### Upstream escalation handshake — exact shape

When a `worker-implementation` or `worker-review` returns a `QUESTION:` block:

1. Commander parses the block, extracts `question`, `context`, `options`, `recommendation`.
2. Commander scans `memory/escalation-faq.md` + `memory/learnings-<repo>.md` for nearest match.
3. If match found → `SendMessage(worker_id, answer)`. Done. No upstream call.
4. If miss AND `upstream_supervisor.enabled=true`:
   - Compute `nearest_memory_match` (top-1 fuzzy hit or `null` if truly novel).
   - Call `supervisor.resolve_question({worker_id, question, context, options, recommendation, nearest_memory_match})`.
   - Wait up to `upstream_supervisor.timeout_sec` (default 300).
   - On response: `SendMessage(worker_id, response.answer)` AND append Q+A pair to `memory/escalation-faq.md` so next time no escalation is needed.
   - On timeout or error: label ticket `commander-stuck`, stop retries for this worker.
5. If miss AND `upstream_supervisor.enabled=false`:
   - Label ticket `commander-stuck`, stop retries for this worker. (Legacy fallback behavior.)

The supervisor's return shape (`{answer, confidence, human_involved}`) intentionally surfaces `human_involved`. Commander doesn't act on it for now, but future retros can cite it to show what share of novel questions needed a real human vs. what share the supervisor resolved autonomously.

## Test plan

This PR lands contract + docs + config + prompt edits. Tests are correspondingly shape-focused:

- `jq . mcp/hydra-tools.json` — valid JSON.
- `jq . state/connectors/mcp.json.example` — valid JSON.
- `bash -n setup.sh install.sh` — shell syntax unchanged (no script edits in this PR).
- Manual grep: `CLAUDE.md` + `memory/escalation-faq.md` + `README.md` + `INSTALL.md` read coherently with "supervisor agent" as the escalation target; "operator must merge" / "operator-facing" phrasing in the escalation context should be contextualized as legacy or absent.
- The self-test harness (`self-test/`) is not invoked in this PR — no golden case exists yet for MCP-driven spawns because the server binary isn't live. A follow-up PR that lands the server will add a `mcp-agent-interface-smoke` case.

When the follow-up PR ships the server binary:

- Mock supervisor binary + real Commander → verify full `worker QUESTION → supervisor.resolve_question → Commander SendMessages worker → FAQ appended` loop.
- Scope violation test: `read`-only token calls `hydra.pick_up` → structured refusal with `scope_check: denied` in audit log.
- T3 refusal test: `admin` token calls `hydra.merge_pr` on a ticket classified T3 → refused with `refused_reason: "T3-policy"`.

## Risks / rollback

**Risk: tool-contract drift.** If a future commit edits `mcp/hydra-tools.json` without updating `docs/mcp-tool-contract.md`, the human-readable doc lies. Mitigation: the doc has a "JSON is authoritative" disclaimer and explicit cross-reference. Future work could add a check script that diffs tool names between the two files in CI.

**Risk: prompt drift from the mental-model shift.** `CLAUDE.md` now says "supervisor" where it used to say "the human". If an operator runs a local Hydra without configuring `upstream_supervisor`, the prompt still mentions supervisor — but the fallback path (label `commander-stuck`, no upstream call) is exactly what used to happen for the operator. Legacy operators lose nothing; they just see a slightly different phrasing in the ticket label.

**Risk: authorized_agents token leakage.** The config file holds only the SHA-256 hash, but operators might copy the raw token into a comment by mistake. Mitigation: `.gitignore` covers `state/connectors/mcp.json` (the real file, not `.example`), and the doc explicitly says "never commit the raw token".

**Rollback:** this PR is doc + config + prompt edits. Revert the commit. No runtime behavior changes (the actual server binary is not landed yet). Even the prompt edit to CLAUDE.md is safe to revert — it renames and restructures a section but keeps the three-tier decision protocol intact.

## Implementation notes

(To fill in after the follow-up PR lands the server binary. Things to capture: whether stdio vs. http was contentious in practice, what the first supervisor agent implementation looked like, whether `timeout_sec=300` was the right default, whether `confidence` from the supervisor turned out useful.)

### Follow-up tickets to file once this lands

- **Actual MCP server binary.** Reads `mcp/hydra-tools.json` at startup; dispatches tool calls to Commander's existing internal verbs. Stdio transport first, HTTP transport second.
- **Mock supervisor fixture.** A tiny stdio MCP server that returns canned answers to `resolve_question`, used by the self-test case.
- **`scripts/mcp-audit-tail.sh`.** A small helper for operators to `tail -f logs/mcp-audit.jsonl | jq` — because the audit trail is useless without a nice viewer.
- **`state/schemas/mcp-audit.schema.json`.** JSON Schema for the audit log line shape, so future log-parsing tools can validate.
