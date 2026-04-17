---
status: draft
date: 2026-04-17
author: hydra worker (ticket #72)
---

# `./hydra mcp serve` — minimum viable MCP server for the agent-only interface

## Problem

PR #52 (closes #50) landed the MCP tool contract — `mcp/hydra-tools.json`, `state/connectors/mcp.json.example`, `docs/mcp-tool-contract.md`, and the upstream-supervisor escalation protocol. The contract is schema-first and complete: 13 tools, scope-levels, authorized-agents, audit envelope, everything client agents need to plan against.

What is still missing is the **server binary**. Today `curl https://hydra-commander-tonychang.fly.dev/mcp` returns 404. The only way to talk to cloud Commander is `fly ssh console -C 'tmux attach -t commander'`, which defeats the agent-only interface the whole architecture is organized around. Any external client — OpenClaw, a Discord bridge, a Main Claude agent, a dashboard bot — can't drive Commander without this ticket landing.

Ticket #72 is explicit that the scope here is **minimum viable**, not feature-complete: three tools end-to-end to prove auth + scope + audit works, the remaining 10 tools scaffolded as `NotImplemented` errors, HTTP transport only. Stdio transport is a follow-up.

## Goals

1. Ship a runnable `./hydra mcp serve` subcommand (dispatched like the other non-chat subcommands under `scripts/hydra-*.sh`).
2. Refuse to start without a configured `authorized_agents[]` in `state/connectors/mcp.json`. Fail loud.
3. Serve JSON-RPC 2.0 over HTTP on a configurable port (default `8765`). Speaks the MCP verbs `initialize`, `tools/list`, `tools/call`, `ping`.
4. Bearer-token auth: caller sends `Authorization: Bearer <token>`; server SHA-256s and matches against `authorized_agents[].token_hash`. 401 on miss, 403 on scope mismatch.
5. Implement three tools end-to-end — `hydra.get_status` (read), `hydra.list_ready_tickets` (read), `hydra.pause` (admin). Scaffold the other 10 as handlers that return a structured `not-implemented` error — never silently succeed.
6. Append every call to `logs/mcp-audit.jsonl` with `{ts, caller_agent_id, tool, scope_check, refused_reason, input_hash}`. No request/response bodies.
7. T3 refusal is enforced at the handler layer for `hydra.merge_pr` even in the scaffolded stub — regardless of scope check, a T3 PR returns `{error: "t3-refused"}`. This matters because the stub lands today and we do not want a future caller to get a confusing `not-implemented` when the real answer is "refused on policy".
8. Wire into `infra/fly.toml` (`/mcp` route on `:8765`, keep `/health` on `:8080`) and `infra/entrypoint.sh` so the MCP surface is live on every Fly deploy.
9. Self-test: `mcp-server-starts` case spawns the server in a subprocess, sends `tools/list`, verifies all 13 tools come back.
10. Operator runbook: add a "Wiring up an external agent" section to `docs/phase2-vps-runbook.md`.

## Non-goals

- **Stdio transport.** Deferred to a follow-up ticket. The `--transport` flag is parsed and `stdio` returns a clean "not yet supported" error.
- **Rate limiting.** Phase 2. A coarse per-token cap is the eventual target; Phase 1 relies on the Fly VM's natural concurrency ceiling and the Fly reverse-proxy.
- **TLS / HTTPS termination.** The server binds `127.0.0.1` by default; Fly's `[[http_service]]` does the TLS. Do not expose `0.0.0.0` directly in this PR.
- **Implementing the remaining 10 tools.** They are scaffolded only. Follow-ups wire them one by one.
- **Commander-internal RPC.** The Phase 1 dispatch is **separate-process, state-file-reading**. The server reads `state/active.json`, `state/autopickup.json`, `state/budget-used.json`, `state/repos.json`, `logs/*.json` directly and writes the `PAUSE` sentinel for `hydra.pause`. No IPC to a running Commander process. Phase 2 spec will replace this with a proper in-process RPC (see "Risks" below).
- **Multi-tenant scaling.** Single-agent Phase 1. Nothing stops multiple authorized agents from being listed, but there is no quota or fairness beyond what the tool-contract already implies.

## Proposed approach

### Process model

`./hydra mcp serve` dispatches to `scripts/hydra-mcp-serve.sh` (same pattern as `scripts/hydra-status.sh`, `scripts/hydra-pause.sh`, etc.). The shell wrapper sources `.hydra.env`, validates prereqs (Python 3, `state/connectors/mcp.json` exists and has `authorized_agents`), then `exec`s the Python server.

The server itself is a single Python 3 script at `scripts/hydra-mcp-server.py`. Python is the lingua franca of the Fly image — `entrypoint.sh` already launches a Python `http.server` for `/health`. No extra runtime dependencies.

The server uses only the Python stdlib (`http.server`, `json`, `hashlib`, `threading`, `hmac`). No third-party deps. No `pip install` step in the Dockerfile. Spec **deliberately rejects** adding `uvicorn`/`fastapi`/`mcp`-python-sdk/`httpx` — the footprint is too large for a Phase 1 scaffold. We can migrate to the official `mcp` SDK in a follow-up once the contract is proven.

### Transport & wire protocol

- `--transport http` (only supported today) binds a `ThreadingHTTPServer` on `--bind 127.0.0.1:--port 8765`.
- `--transport stdio` prints a clean "stdio transport is a follow-up ticket; see docs/specs/2026-04-17-mcp-server-binary.md §Non-goals" message and exits 2.
- HTTP endpoint: `POST /mcp` with JSON-RPC 2.0 body. Any other path: 404. `GET /mcp`: 405. Body size cap: 64 KiB (coarse DoS mitigation).
- MCP handshake: supports the four JSON-RPC methods the MCP spec requires for a minimal server: `initialize`, `tools/list`, `tools/call`, `ping`. Any other method: standard JSON-RPC error `-32601 Method not found`.
- The `initialize` response advertises `protocolVersion`, `serverInfo`, and `capabilities.tools.listChanged=false` (we never live-change the tool set; restart to change).

### Auth + scope check

On every HTTP request:

1. Extract `Authorization: Bearer <token>`. No header → 401.
2. Compute `sha256(token).hexdigest()`. Compare against each entry in `authorized_agents[].token_hash` using `hmac.compare_digest`. No match → 401.
3. Look up the tool's required scope from `mcp/hydra-tools.json:tools[].scope`. If the matched agent's `scope` list doesn't contain the required scope → 403.
4. On `tools/call` for `hydra.merge_pr`: even before dispatching, check the PR's tier via the embedded tier map (Phase 1: static allowlist of known T3 paths from `policy.md` — see tier classifier below). T3 → return `{error: "t3-refused"}` in the JSON-RPC `result.content` shape, NOT as a JSON-RPC error (the tool contract says this is a structured refusal, not a protocol failure).
5. Every call — successful, 401, 403, t3-refused, not-implemented — is appended to `logs/mcp-audit.jsonl`. The audit log is the accountability trail.

### Tool dispatch

A single `TOOL_HANDLERS` dict maps tool names to Python callables. Three are implemented:

- `hydra.get_status`: reads `state/active.json` + `state/autopickup.json` + `state/budget-used.json` + `commander/PAUSE` sentinel (presence = paused). Composes the response shape from `mcp/hydra-tools.json`. Read-only.
- `hydra.list_ready_tickets`: reads `state/repos.json`, shells out to `gh issue list --assignee @me --state open --json number,title,labels,repository --limit N` for each enabled repo whose trigger is `assignee` (or `--label commander-ready` for label trigger). Filters out tickets labeled `commander-working`/`commander-pause`/`commander-stuck`. Returns `{tickets: [...]}`. The tier-guess column is populated by a very simple keyword classifier — same logic that will back `hydra.pick_up_specific`'s preflight refusal. For Phase 1 we just emit `"tier_guess": "unknown"` with a comment in the code.
- `hydra.pause`: atomically creates a `commander/PAUSE` sentinel file with the caller_agent_id and reason as its body. Idempotent — repeated pauses re-touch the file without error.

The other 10 tools (`pick_up`, `pick_up_specific`, `review_pr`, `merge_pr`, `reject_pr`, `answer_worker_question`, `resume`, `retro`, `get_log`, `kill_worker`) are registered in `TOOL_HANDLERS` but all point to `_handler_not_implemented(tool_name)` which returns a structured JSON-RPC error `-32001 NotImplemented` with a `data.follow_up_ticket` field pointing to the follow-up ticket number (to be filed). This means the tool contract is fully discoverable from `tools/list` today — clients see all 13 tools with schemas — but only three work.

**Exception:** `hydra.merge_pr` has an extra pre-check that runs BEFORE the not-implemented handler. If the PR is T3, it returns `{error: "t3-refused"}` in the MCP tool-result shape. This enforces the safety rail from day one, even on the stubbed handler, and prevents a confusing "not-implemented" response to a supervisor agent that was about to do the wrong thing anyway. See the ticket's acceptance criterion 7.

### Session lifecycle

Stateless. Every HTTP request is independently authenticated; there is no session cookie, no MCP `session_id`, no connection reuse tracking. `initialize` is idempotent — a client can re-send it at any time. This is simpler than the MCP spec's full session-oriented model but valid for HTTP transport, and it matches how the contract is currently written.

### Rate limiting

Phase 2. A sentence in the runbook and this spec. If the server is under load in Phase 1, the operator's mitigation is "pause via the agent-only interface" — which is the pause tool we're about to ship.

### Rollback

- `./hydra mcp serve` is additive — the existing chat path (`./hydra` launching `claude` under `tmux`) is unchanged. Removing the MCP server has no effect on Commander's core loop.
- `infra/fly.toml` changes add a second `[[http_service]]` block. Reverting the PR removes the `/mcp` route; the `/health` route is untouched.
- `infra/entrypoint.sh` launches the MCP server in the background with a `trap` on TERM. If it crashes, the container keeps running (only the `/health` server exiting triggers a container restart). This is deliberate: the MCP server is not core to Commander's loop, it's a sidecar.

### Alternatives considered

- **Alternative A: use the official `modelcontextprotocol/python-sdk`.** Clean, spec-compliant, handles stdio and HTTP+SSE correctly. Rejected for Phase 1 because adding a Python dep requires changes to the Dockerfile, a lock-file discipline Hydra doesn't have yet, and the SDK is young enough that the tool-contract schema format changes between minor versions. Stdlib-only keeps the blast radius tiny. Revisit when ticket #72 is done and we have the two-three most useful tools stabilized.
- **Alternative B: in-process RPC with Commander (named pipe or Unix socket).** This would be "the real answer" — Commander knows the current worker state directly, no file-reading races. Rejected for Phase 1 because Commander is a `claude` CLI session under `tmux` with no RPC surface today; adding one is a much bigger change than the ticket asks for. The ticket explicitly says "Realistic Phase 1 dispatch: the MCP server is a SEPARATE PROCESS that reads the same state files Commander reads". Phase 2 spec is where this gets revisited.
- **Alternative C: Node.js implementation.** There is good MCP tooling in the Node ecosystem. Rejected because the Fly image already has Python 3 and claims no Node runtime as a dependency — pulling Node in for this server would expand the image footprint for little gain.
- **Alternative D: only support stdio transport in Phase 1.** Simpler server, client launches it, no port management. Rejected because the ticket explicitly asks for HTTP (stdio is the follow-up), and because the value proposition of an agent-only interface is network-reachable: a cloud Commander that remote agents talk to. Stdio-only would re-introduce the "ssh into the box" problem this ticket is trying to fix.

## Test plan

Three layers, each independently verifiable:

### 1. Unit-ish: server starts cleanly + refuses bad config

- Run `./hydra mcp serve --transport http --port 8765` with an empty `authorized_agents` list → exits 1 with a clear error message, binds no port.
- Run it with a configured `authorized_agents` → logs "listening on 127.0.0.1:8765", does not exit.

### 2. Integration: self-test case `mcp-server-starts`

A new `kind: "script"` case in `self-test/golden-cases.example.json`:

1. Stages a tmpdir mirror of `state/connectors/mcp.json` with one test agent, token hash known.
2. Spawns the server on a random unused port in the background.
3. Posts `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` with `Authorization: Bearer <token>`.
4. Asserts the response has `result.tools` of length 13 (all tools in `mcp/hydra-tools.json` come back).
5. Posts `tools/call` for `hydra.get_status` → expects a valid `active_workers/today/paused/autopickup` object.
6. Posts `tools/call` with a wrong bearer → expects HTTP 401.
7. Posts `tools/call` for `hydra.pause` with a read-only scoped token → expects HTTP 403.
8. Posts `tools/call` for `hydra.merge_pr` simulating a T3 PR (fixture tier map) → expects the structured `{error: "t3-refused"}` response.
9. Kills the server. Asserts the audit log contains exactly the five calls made.

This is the case called out in the ticket's Acceptance criteria. Marked `kind: script` so it runs in the existing `./self-test/run.sh` harness without the SKIP-path executor (no worker subagent needed — just a Python subprocess).

### 3. Smoke: docs runbook section

Add an "Wiring up an external agent" section to `docs/phase2-vps-runbook.md` that walks an operator through:

- copy `state/connectors/mcp.json.example` → `.json`, fill in `authorized_agents[0].id` and `token_hash` (instructions for generating a token with `python3 -c 'import secrets; print(secrets.token_urlsafe(32))'` and SHA-256-ing it)
- on Fly: the MCP surface is already wired by `entrypoint.sh`; use `fly ssh console -C 'curl -H "Authorization: Bearer $T" localhost:8765/mcp ...'` to smoke-test from inside the VM
- on local: `./hydra mcp serve --transport http --port 8765` and `curl` from another terminal
- common failure modes: missing `authorized_agents` (server refuses to start), wrong token hash format (401 on every call), confusing `not-implemented` responses for unimplemented tools (expected — Phase 1 scope)

## Risks / rollback

- **Risk: token_hash comparison is timing-attack-weak.** Mitigation: use `hmac.compare_digest` explicitly, not `==`. Tested in the self-test.
- **Risk: the stateless HTTP approach means a malicious client with a valid token can DoS by spamming requests.** Mitigation: Phase 1 accepts this — the Fly VM is small (`shared-cpu-1x`, 512 MB) and the Fly reverse proxy has its own basic floods protection. Phase 2 adds a per-token rate limit in the server.
- **Risk: file-reading races.** The server reads `state/active.json` while Commander (a separate process) writes it. Mitigation: reads are single-shot `json.load` on an open-then-close; worst case is a read that returns stale-but-valid data or a `json.JSONDecodeError` that surfaces as a 500. Commander writes are atomic (write to tmp, rename). Good enough for Phase 1.
- **Risk: Fly.io's `[[http_service]]` only supports one `internal_port` per service block.** Mitigation: add a *second* `[[http_service]]` block for `/mcp` on `:8765` — Fly supports multiple `[[http_service]]` stanzas for distinct ports. Verified against the current `fly.toml` schema.
- **Risk: the scaffolded `not-implemented` tools confuse supervisor agents.** Mitigation: the JSON-RPC error includes a `data.follow_up_ticket` field and a clear `data.message` explaining that Phase 1 only ships three tools end-to-end; a client-side wrapper can distinguish "not wired yet" from "refused" by the error code (`-32001 NotImplemented` vs a structured `t3-refused` in the success path).

**Rollback:** if anything in Phase 1 misbehaves on Fly, the operator can `fly secrets set HYDRA_MCP_ENABLED=0` (env var the entrypoint honors to skip the MCP server background launch). Full rollback is a straight `git revert` of this PR's final commit — `/health` and the core Commander tmux session are untouched.

## Implementation notes

*(Fill in after the PR lands.)*
