---
status: draft
date: 2026-04-17
author: hydra worker (issue #87)
---

# Upstream-supervisor MCP escalation client

Implements: ticket #87 (T2). Closes the dead-code gap where `state/connectors/mcp.json:upstream_supervisor.enabled=true` was defined but no code read it.

## Problem

`CLAUDE.md`'s "Three-tier decision protocol" describes Commander's escalation loop:

> When Commander can't resolve from memory → escalate to supervisor agent via `supervisor.resolve_question` → Commander `SendMessage`s the worker with the answer and appends the Q+A to `memory/escalation-faq.md`.

The config surface (`state/connectors/mcp.json.example:upstream_supervisor`) has existed since PR #52, and `docs/specs/2026-04-16-mcp-agent-interface.md` documents the handshake. PR #72 landed the **inbound** MCP server (`scripts/hydra-mcp-server.py`) so external agents can reach Hydra.

The **outbound** path — Commander as an MCP *client* calling a supervisor — was never implemented. When a worker returns a `QUESTION:` block with no memory match, only the legacy `commander-stuck` path runs today. That means the `upstream_supervisor.enabled=true` branch is dead code, and the autonomy principle ("the machine runs while the operator sleeps") still blocks on live operator attention for any genuinely novel worker question.

## Goals

- A standalone script (`scripts/hydra-supervisor-escalate.py`, Python 3 stdlib only) that:
  - Reads `state/connectors/mcp.json:upstream_supervisor`. If `enabled=false` or missing, exits 2 with a clear `not-configured` marker on stdout — Commander reads this as "fall through to legacy `commander-stuck`."
  - Reads a JSON question envelope from stdin: `{worker_id, question, context, options, recommendation, nearest_memory_match}`.
  - Resolves the bearer token via the `auth_token_env` env-var name (default `HYDRA_SUPERVISOR_TOKEN`). If config is enabled but the env var is missing, exit 1 with a clear error (never log the token value).
  - Opens a connection to `connect_url` (HTTP or stdio, matching the server's transport), authenticates with bearer token, calls `supervisor.resolve_question` with the envelope, and prints the response `{answer, confidence, human_involved}` as JSON on stdout.
  - Enforces `timeout_sec` (default 300). On timeout → exit 3 + `timeout` marker. Commander treats as `commander-stuck`.
  - A `--check` / dry-run mode that validates config + parses envelope + exits 0 without any network call. This is what CI self-tests use.
- A thin `CLAUDE.md` update to the "Three-tier decision protocol" pseudocode block: insert the `scripts/hydra-supervisor-escalate.py` invocation step with documented exit codes. No other section rearranged.
- Two self-test golden cases (`supervisor-escalate-disabled-path`, `supervisor-escalate-shape`) exercising the `enabled=false` exit-2 branch and the JSON envelope shape against the fixture contract. Runnable in CI with no network.

## Non-goals

- **Not implementing the supervisor agent itself.** That's the operator's `supervisor-mcp` binary; Hydra only calls it.
- **Not implementing retry / backoff logic on timeout.** Phase 2. A timeout → `commander-stuck`, and the operator can `retry #N` once the supervisor is back.
- **Not implementing multi-supervisor / failover.** Phase 2. One `upstream_supervisor` per mcp.json.
- **Not changing how workers emit `QUESTION:` blocks.** The worker contract is stable.
- **Not editing commander's operating loop beyond the CLAUDE.md pseudocode update.** The actual Python invocation integration at the commander-decision layer is covered by documentation in this PR; wiring the subprocess call into commander's Agent-tool dispatch flow belongs to a follow-up ticket tracked as "commander loop plumbing" (see Implementation notes).
- **Not adding source-field plumbing for `state/memory-citations.json`.** PR #70 already landed the schema with `source: operator|supervisor`. Commander populates that field when it appends to `escalation-faq.md` — covered in the CLAUDE.md "Memory hygiene" section, no new code needed in this PR.

## Proposed approach

### One Python script, three exit codes

Python 3 stdlib, matching `scripts/hydra-mcp-server.py`. No pip install step. Reasons:
- `scripts/hydra-mcp-server.py` already proves stdlib-only HTTP JSON-RPC is enough for Hydra's MCP needs.
- A shell wrapper would need `curl` + `jq` + subprocess timing, and all three are fragile (curl exit codes, jq version skew, `timeout` is not on macOS by default — see learnings-hydra.md ticket #74).
- Python gives us `signal.alarm` (POSIX, portable), `json.loads` with exceptions, and `urllib.request` for HTTP.

**Exit contract (authoritative — commander parses these):**

| Exit | Meaning | Stdout marker |
|---|---|---|
| 0 | Success — supervisor answered; response JSON on stdout | `{"answer": "...", "confidence": 0.x, "human_involved": bool}` |
| 1 | Configuration or runtime error (bad token env, bad URL, connection refused, malformed response) | `{"error": "<short>", "detail": "<no tokens>"}` |
| 2 | Not configured — `enabled=false` or config file missing | `{"error": "not-configured"}` |
| 3 | Timeout — supervisor did not respond within `timeout_sec` | `{"error": "timeout", "timeout_sec": N}` |
| 4 | Usage error (bad CLI flags, stdin not valid JSON) | Error text on stderr; stdout empty |

Why separate exit 2 (not-configured) from exit 1 (error): commander decides between "fall through to legacy `commander-stuck` silently" (exit 2) vs "something is wrong, surface to operator" (exit 1). Conflating them would make the legacy-operator experience noisier.

### CLI

```
hydra-supervisor-escalate.py [--check] [--config PATH]
  <stdin: JSON envelope>
  <stdout: JSON response or error>
```

- `--check` — validate config + parse envelope from stdin + exit 0 without any network call. For CI self-tests.
- `--config PATH` — override the config path. Default: `$HYDRA_MCP_CONFIG` falling back to `state/connectors/mcp.json`. Matches `scripts/hydra-mcp-server.py`.

Env vars:
- `HYDRA_MCP_CONFIG` — config path override (same as server).
- `HYDRA_SUPERVISOR_TOKEN` (or whatever `auth_token_env` names) — bearer token. Never logged.

### Transport matching

The config has `transport` and `connect_url`. Phase 1 supports HTTP only (matching the MCP server's own Phase 1 scope per `docs/specs/2026-04-17-mcp-server-binary.md`). `transport: stdio` returns exit 1 with a clear "stdio transport is a Phase 2 non-goal" message.

HTTP transport makes a single `POST` to `connect_url`:
- `Authorization: Bearer <token from env>`
- `Content-Type: application/json`
- Body: JSON-RPC 2.0 envelope wrapping `tools/call` with `name: supervisor.resolve_question` and `arguments: <envelope>`.
- Response: standard JSON-RPC result or error.

### Envelope JSON shape

Request (from commander → supervisor):
```json
{
  "worker_id": "w-7f3a",
  "question": "Should I rename the column or add a migration?",
  "context": "Worker found the ticket asks to add a field but the existing field is already what the ticket wants...",
  "options": ["rename-column", "add-new-field", "ask"],
  "recommendation": "add-new-field — safer, no migration needed",
  "nearest_memory_match": null
}
```

Response (from supervisor → commander):
```json
{
  "answer": "Add a new field. The old column name is referenced by three callers; renaming is T3.",
  "confidence": 0.85,
  "human_involved": false
}
```

Both shapes match `docs/specs/2026-04-16-mcp-agent-interface.md` verbatim.

### Alternatives considered

- **Bash + `curl` + `jq`.** Rejected: macOS lacks GNU `timeout`; `curl`'s `--max-time` exits different codes for read timeout vs connect timeout vs error; shell quoting of the envelope JSON is brittle for repo snippets with backticks. Python stdlib is cleaner and already the established pattern.
- **Put the escalation logic inline in commander's prompt.** Rejected: commander is a prompt-driven agent, not a subprocess runner. The subprocess boundary gives us exit codes commander can reason about declaratively ("if exit=2, legacy-stuck; if exit=0, parse stdout") instead of fragile prompt-level error handling.
- **Extend `scripts/hydra-mcp-server.py` with an outbound client mode.** Rejected: the server is a daemon; the client is a one-shot CLI. Mixing the two would complicate the single-file server. Separate script is more legible.
- **Use the `mcp` Python SDK.** Rejected: adds a pip-install step. The entire `scripts/*.py` convention in this repo is stdlib-only. Consistency wins.

### Security considerations

- Token is read from env var. Never logged — not in stderr, not in the audit log, not in exception traces (we catch and re-raise with sanitized messages).
- Config-file token_hash is for **inbound** auth (agents calling *into* Hydra). The outbound client uses a different token (the one the supervisor expects). The two token spaces are orthogonal; this PR does not leak one into the other.
- Scope granted to the supervisor is always `resolve_question` only (per `state/connectors/mcp.json.example:scope_granted`). We enforce this at read time: if the config lists anything other than `["resolve_question"]`, we reject with exit 1 + `scope-overreach` marker. Defense in depth against a misconfigured `mcp.json`.
- HTTP timeouts are set on both `connect` and `read` phases of the request. A hanging supervisor can't hang commander indefinitely.
- `--check` mode performs zero network I/O. Self-tests that don't mock a supervisor use `--check`.

## Test plan

Two self-test golden cases, both `kind: script`, both runnable in CI with no network:

### 1. `supervisor-escalate-disabled-path`

Setup: write a minimal `mcp.json` to a tmpdir with `upstream_supervisor.enabled=false`.

Steps:
1. `python3 scripts/hydra-supervisor-escalate.py --config <tmpdir>/mcp.json < <(envelope_json)` → expect exit 2, stdout contains `"not-configured"`.
2. `python3 scripts/hydra-supervisor-escalate.py --config <nonexistent> < <(envelope_json)` → expect exit 2, stdout contains `"not-configured"`.
3. `python3 scripts/hydra-supervisor-escalate.py --help` → exit 0, usage text present.
4. `python3 -c 'import ast; ast.parse(open("scripts/hydra-supervisor-escalate.py").read())'` → exit 0 (syntax).

### 2. `supervisor-escalate-shape`

Setup: write a minimal `mcp.json` with `upstream_supervisor.enabled=true` and a placeholder `connect_url` + `auth_token_env`.

Steps:
1. Set `HYDRA_SUPERVISOR_TOKEN=test-token`. Run with `--check` + valid envelope → exit 0, stdout contains `"check-ok"`.
2. Run with `--check` + malformed envelope (missing `worker_id`) → exit 4, stderr mentions `missing required field`.
3. Run without `HYDRA_SUPERVISOR_TOKEN` set (env enabled but no token) + valid envelope → exit 1, stdout contains `"token-missing"`.
4. Run with config listing `scope_granted: ["resolve_question", "run_arbitrary_code"]` → exit 1, stdout contains `"scope-overreach"`.

Both cases are appended to `self-test/golden-cases.example.json` at the END of the `cases[]` array (not inserted mid-array, to avoid conflicts with parallel workers #83 and #85 — see "Risks / rollback").

### Beyond self-tests

- Manual check: `./self-test/run.sh --case supervisor-escalate-disabled-path` exits 0.
- Manual check: `bash .github/workflows/scripts/syntax-check.sh` validates spec frontmatter + Python syntax.
- Manual check: `python3 -c 'import hydra_supervisor_escalate'` does not work (no `__init__.py`) but direct `python3 scripts/hydra-supervisor-escalate.py --check` does.

A live integration test (real supervisor server, real network) is **out of scope** — that belongs to a follow-up ticket once an operator has actually deployed a supervisor agent. This ticket validates the shape and the exit-code contract.

## Risks / rollback

- **Risk: dead code still dead.** The CLAUDE.md edit documents how commander should invoke the script, but the commander prompt is not a Turing-complete executor — whether commander actually calls the script on a `QUESTION:` block without a memory match depends on the prompt being read coherently by future sessions. Mitigation: the CLAUDE.md update is minimal and local to the existing "Three-tier decision protocol" section. Follow-up ticket tracks wiring the subprocess call into `.claude/agents/commander.md`-style operational scripts if/when that layer materializes.
- **Risk: outbound network call introduces a surveillance vector.** Sending the worker's `context` to an external supervisor is exactly the escalation's point, but operators should know. Mitigation: `upstream_supervisor.enabled=false` is the default in `mcp.json.example`. Operators must explicitly opt in. The CLAUDE.md update calls this out.
- **Risk: token leakage via error paths.** Mitigation: every `except` branch in the script re-raises with a sanitized message; the token is never interpolated into log lines. Self-test case covers the `token-missing` path; a future `scripts/security-review.sh` could grep for token substrings in captured stderr.
- **Risk: merge conflict with parallel worker edits to CLAUDE.md / golden-cases.** Worker #85 is editing "Scheduled autopickup" and worker #83 the commands table — both different sections. This PR edits only the "Three-tier decision protocol" pseudocode block. Golden-cases: all three workers append to the end of `cases[]`; additive concatenation is the conflict-resolver rule (see `escalation-faq.md` "Conflict resolution" section). If a true semantic conflict appears, worker-conflict-resolver escalates rather than guessing.
- **Rollback:** one Python script + one CLAUDE.md edit + two self-test cases + one spec. Revert the PR. No state/* mutations, no config changes, no existing-code modifications. Zero runtime impact because the commander loop doesn't invoke the script today (that's the follow-up).

## Implementation notes

To fill in after the PR lands. Things to capture:
- Did the exit-code contract stay stable as the commander loop integration landed?
- Was `timeout_sec=300` the right default, or did supervisors typically answer in <5s and we could drop it to 60?
- Did `scope_granted` enforcement catch any misconfigurations in practice?

### Follow-up tickets

- **Commander loop integration.** Actually call `hydra-supervisor-escalate.py` from the commander decision layer on a `QUESTION:` miss. Covers the `.claude/agents/` wiring if/when that layer lands. This ticket documents the contract; wiring the subprocess call is Phase 2 material.
- **stdio transport.** The Phase 2 MCP server will support stdio (per `docs/specs/2026-04-17-mcp-server-binary.md` §Non-goals). When it lands, add stdio-transport support here, gated on the server's capability.
- **Retry + backoff.** On transient network errors, a linear backoff retry (1x, 2x, 4x seconds, then `commander-stuck`) would reduce false-positive timeouts. Phase 2.
- **Mock supervisor fixture for end-to-end self-test.** A tiny stdio MCP server returning canned `resolve_question` answers, driven by the existing `self-test/fixtures/mcp-server/` pattern. Would exercise the full roundtrip (commander → script → mock supervisor → answer → commander) without real network.
