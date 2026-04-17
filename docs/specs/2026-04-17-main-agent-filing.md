---
status: draft
date: 2026-04-17
author: hydra worker (issue #143)
---

# Main Agent ticket-filing via MCP (`hydra.file_ticket`)

Implements: ticket #143 (T2).

## Problem

Today the shortest path from "human notices something" to "Commander is on it"
looks like:

1. Human is in conversation with their **Main Agent** (a Claude Code session on
   their laptop). They describe a bug or a small feature request.
2. Human pops out of that conversation, opens a browser, loads
   `github.com/<owner>/<repo>/issues/new`, transposes what they just said into a
   title + body, assigns to themselves, submits.
3. Hydra's next autopickup tick sees the ticket and spawns a worker.

Step 2 is ~90 seconds of friction that drops small ideas on the floor. The MCP
server already exists (`./hydra mcp serve`, tool contract at
`mcp/hydra-tools.json`) — it has `hydra.pick_up_specific`, `hydra.get_status`,
`hydra.list_ready_tickets`, `hydra.pause`, etc. It does **not** have a way to
*file* a ticket.

The goal of this ticket is to collapse that gap to ~3 seconds: Main Agent
listens, offers to file, calls **one** MCP tool, Commander creates the GitHub
issue and the autopickup tick handles it from there.

## Goals / non-goals

**Goals:**

- New MCP tool `hydra.file_ticket` accepting `{repo, title, body, proposed_tier?,
  labels?, auto_pickup?}`, returning `{issue_number, issue_url, will_autopickup,
  reason?}`.
- Tool requires scope `spawn` (same auth model as `hydra.pick_up`). Read-only
  agents cannot file tickets.
- Validation: repo must be enabled in `state/repos.json`; `title + body` ≥ 20
  chars combined (anti-spam); `proposed_tier=T3` is filed but auto-refused.
- Filing shells out to `gh issue create --repo <slug> --title ... --body ...
  --label commander-auto-filed --label commander-ready [--label <user_labels>]`.
- Per-agent rate limit: max 10 `hydra.file_ticket` calls per hour per
  `authorized_agents[].id`. Exceeding returns a JSON-RPC error equivalent to
  HTTP 429. Counter persisted in `state/mcp-rate-limit.json` with schema
  `state/schemas/mcp-rate-limit.schema.json`.
- Tool schema registered in `mcp/hydra-tools.json`; human-readable section
  added to `docs/mcp-tool-contract.md`.
- Regression test under `self-test/fixtures/mcp-file-ticket/` that stages an
  auth agent, mocks `gh issue create`, and asserts both the success shape and
  that the 11th call in an hour is rate-limited.

**Non-goals:**

- **Filing into Linear.** Linear file-ticket is an out-of-scope follow-up;
  gets trivial once #140 (Linear trigger) and this ticket both land.
- **Filing into arbitrary repos not in `state/repos.json`.** We refuse. The
  enabled-repo list is the trust boundary.
- **Auto-title generation from a voice memo.** Phase 2.
- **Fan-out to multiple repos in one call.** One call = one issue.
- **Triggering an immediate pickup bypassing the autopickup tick.** We queue
  (append to the next tick's candidate list); we don't spawn synchronously. The
  return value says `will_autopickup: true` so the caller knows.

## Proposed approach

### One tool, one source of truth

The MCP layer already has a dispatch pattern: every tool has a handler function
in `scripts/hydra-mcp-server.py` keyed off `TOOL_HANDLERS`, each tool's scope
and input schema live in `mcp/hydra-tools.json`, and the human-readable
contract lives in `docs/mcp-tool-contract.md`. We add one entry to each:

**Handler (`scripts/hydra-mcp-server.py`).** A new `_handler_file_ticket(params,
agent) -> dict`:

1. Read `params = {repo, title, body, proposed_tier?, labels?, auto_pickup?}`.
2. Validate repo against `state/repos.json` (must have `enabled=true`). If the
   slug is not listed, raise `_ValidationError("repo-not-enabled: <slug>")`.
3. Validate `len(title) <= 120` and `len(title) + len(body) >= 20`. Otherwise
   `_ValidationError("title+body must be ≥ 20 chars combined")` or
   `_ValidationError("title exceeds 120 chars")`.
4. Check the per-agent rate limit in `state/mcp-rate-limit.json`. If the caller
   has ≥ 10 calls in the current rolling 60-minute window, raise
   `_RateLimitError(retry_after_sec, limit=10, window_sec=3600)`. Otherwise
   record this call.
5. Assemble the label list: `["commander-auto-filed", "commander-ready"] +
   (params.get("labels") or [])`. De-dupe.
6. If `proposed_tier == "T3"`, append a prefix line to the body:
   `_Filed as T3 — Commander will not pick up automatically; operator must
   resolve manually._\n\n`. Do NOT include `commander-ready` for T3 — replace
   with `commander-stuck` so autopickup skips it.
7. Shell out to `gh issue create` (subprocess, 30s timeout, check=False). Parse
   the stdout URL; extract `issue_number` from the URL tail.
8. Determine `will_autopickup`:
   - `false` if `proposed_tier == "T3"` (refused path).
   - `false` if `params.get("auto_pickup", True) == False`.
   - `false` if the caller passes `auto_pickup=true` but the repo's merge
     policy or commander is paused (best-effort — we inspect `commander/PAUSE`).
   - `true` otherwise. (We don't actually need to mutate state here — the
     existing autopickup tick already picks up labeled `commander-ready` issues
     on its next run. Our job is just to surface what will happen.)
9. Return `{issue_number, issue_url, will_autopickup, reason?}` where `reason`
   is set iff `will_autopickup=false` and explains why.

**Tool schema entry (`mcp/hydra-tools.json`).** Follows the existing style —
name, description, scope, input_schema (JSON Schema draft-07), output_schema,
example_request, example_response.

**Doc section (`docs/mcp-tool-contract.md`).** Follows the pattern already in
the file — a `### hydra.file_ticket` heading with Scope, Use cases, Tradeoffs,
Input, Output.

### Rate limiter: rolling window, file-backed

The rate-limit store is simple and embarrassingly small — 10 calls/hour/agent
is the only constraint. We store per-agent timestamp lists and evict anything
older than 3600 seconds on every read:

```json
{
  "_description": "Per-agent rate-limit state for MCP tools that file GitHub issues. Rolling 60-minute window. Commander evicts timestamps older than the window on every read.",
  "limits": {
    "file_ticket": {
      "window_sec": 3600,
      "max_calls": 10
    }
  },
  "agents": {
    "<agent_id>": {
      "file_ticket": ["2026-04-17T12:34:56Z", "2026-04-17T12:50:01Z"]
    }
  }
}
```

The schema `state/schemas/mcp-rate-limit.schema.json` enforces this shape.
Concurrent writers are handled with the same pattern as
`logs/mcp-audit.jsonl` (a threading.Lock protecting the read-modify-write).

**Why rolling window instead of fixed bucket?** A fixed bucket (reset every
hour on the hour) is trivially gamed — file 10 at 1:59, 10 more at 2:00. The
rolling window forces a genuine 10-per-hour ceiling. Implementation cost is
the same (one list per agent; evict old entries on every read).

### Subprocess vs. GitHub REST

We shell out to `gh issue create` rather than call the GitHub REST API
directly. Three reasons:

1. **Auth parity with every other Hydra script.** `gh` already handles the
   operator's GitHub auth; calling REST directly would require us to reach for
   `$GITHUB_TOKEN` and duplicate the auth flow.
2. **Observability.** `gh issue create` is what every other Hydra script uses
   to open PRs and file `worker-auditor` tickets; any `gh` auth issue hits them
   all at once rather than creating a surprise MCP-only failure mode.
3. **No new dependency.** The MCP server is stdlib-only today. Adding
   `requests` or urllib REST glue just for this one tool would be out of
   proportion.

Tradeoff: `gh` subprocess startup is ~80ms on a warm cache, maybe 300ms cold.
That's well under any reasonable MCP tool timeout (we use 30s as a cap).

### Alternatives considered

- **Bypass the autopickup tick — spawn a worker directly on file.** Tempting
  — it'd shave the tick latency off the human's path. Rejected because it
  bypasses the preflight sequence (PAUSE check, concurrency cap, daily cap,
  rate-limit health) that is the whole point of the autopickup tick. Filing a
  ticket and immediately spawning gets us inconsistent behavior when N Main
  Agents file concurrently and exceed `max_concurrent_workers`. The tick is
  already the right bottleneck; we just add to the candidate pool.
- **Reuse `hydra.pick_up_specific` to implicitly create the ticket.** Looked
  tempting from a "minimize surface" angle but muddles two concepts —
  `pick_up_specific` is "spawn on a known ticket" and should remain so.
  Filing is a separate operation with its own auth and validation shape.
- **Per-IP rate limit instead of per-agent.** Rejected: the agent identity is
  the accountability unit (`authorized_agents[].id`), and the MCP server is
  loopback by default so every agent shares the same IP. Agent-scoped is
  right.
- **Skip rate limiting entirely.** Rejected: filing a ticket is a mutation
  into someone else's GitHub repo. A misbehaving or malicious Main Agent (or a
  bug in one) could flood the issue tracker. 10/hour is generous for humans
  and tight for runaway loops.

## Test plan

The canonical regression is `self-test/fixtures/mcp-file-ticket/run.sh` —
modeled on `self-test/fixtures/mcp-server/run.sh`. It:

1. Stages a fixture `state/connectors/mcp.json` with two agents: one with
   `spawn` scope, one read-only.
2. Stages a fixture `state/repos.json` with one enabled repo (`test-owner/test-repo`).
3. Stages a `bin/gh` shim on the PATH that writes its arguments to a log file
   and prints a canned issue URL — so the assertion can check "handler passed
   the right args to gh" without actually hitting GitHub.
4. Starts `scripts/hydra-mcp-server.py` on a random free port with
   `HYDRA_MCP_CONFIG` pointing at the fixture config.
5. Asserts:
   - `file_ticket` with the spawn agent + a valid repo → returns
     `{issue_number: 42, issue_url, will_autopickup: true}`; the `gh` shim log
     has `--label commander-auto-filed --label commander-ready`.
   - `file_ticket` with the read-only agent → HTTP 403 (scope denied).
   - `file_ticket` with `repo: "unknown-owner/unknown-repo"` → JSON-RPC
     structured error `repo-not-enabled`.
   - `file_ticket` with `title: "x", body: "y"` (6 chars total) → JSON-RPC
     structured error about min length.
   - `file_ticket` with `proposed_tier: "T3"` → `will_autopickup: false`, the
     issue body contains the T3 prefix, labels include `commander-stuck` not
     `commander-ready`.
   - 11th `file_ticket` in a row with the spawn agent → JSON-RPC 429-equivalent
     error with `retry_after_sec` populated.

**Unit-ish Python check.** A lightweight Python-only test path that imports
handler functions directly and runs the validation branches (no server start,
no subprocess). Lives in `self-test/fixtures/mcp-file-ticket/validation.py`,
invoked from the same `run.sh`.

For ticket #143 specifically we treat the `run.sh` integration test as the
authoritative check — it exercises the full auth + scope + validation + rate
limit loop end-to-end against a real server on a real socket.

## Risks / rollback

**Risk: file flood from a buggy Main Agent loop.** Biggest concrete failure
mode — a Main Agent in a runaway loop starts filing the same ticket 100 times.
Mitigation: the 10/hour/agent rate limit caps the blast radius at 10 tickets
before the next limit resets. An operator noticing the flood can revoke the
agent's token via `scripts/hydra-mcp-register-agent.sh --rotate <agent-id>`,
and the existing `commander-auto-filed` label makes the bulk-close trivially
scriptable: `gh issue list --label commander-auto-filed --state open --json
number,createdAt | jq '... | select(.createdAt > "...")' | xargs -I{} gh issue
close {}`.

**Risk: title or body contains shell metacharacters.** We pass title/body as
`gh issue create --title <str> --body <str>` args. `subprocess.run` with a list
argument does NOT go through the shell — metacharacters are fine. We do still
truncate title at 120 chars and body at ~32 KiB (MCP body cap of 64 KiB already
bounds the whole request).

**Risk: race on `state/mcp-rate-limit.json`.** Multiple MCP server processes
(unlikely in Phase 1; one per Commander session) or multiple threads in a
single server could race the read-modify-write. Mitigation: same threading.Lock
pattern as the audit log. For multi-process we rely on the fact that Phase 1
runs one MCP server; Phase 2's move to a managed SDK handles the distributed
case at the SDK layer.

**Risk: tool-contract drift** between `mcp/hydra-tools.json` and
`docs/mcp-tool-contract.md`. Same pre-existing risk as every other tool in the
file; same mitigation — a "JSON is authoritative" disclaimer is already in
`docs/mcp-tool-contract.md`. We add the doc section in the same PR as the JSON
entry, so the two land in lockstep.

**Rollback:** single-file changes in `scripts/hydra-mcp-server.py`, one entry
in `mcp/hydra-tools.json`, one section in `docs/mcp-tool-contract.md`, one new
schema file, one new state file. Revert the PR. The rate-limit state file is
write-only by the server; no consumer relies on it persisting, so deleting it
is safe.

## Implementation notes

(Fill in after the PR lands. Things to capture: whether the rate-limit
threshold of 10/hour turned out right in practice, whether Main Agent's UX
needed any friction to prevent accidental double-filing, whether the
`commander-auto-filed` label helped with the bulk-close path for a real
flood event, whether we need to also rate-limit other spawn-scoped tools.)

### Follow-up tickets to file once this lands

- **Linear file-ticket.** Trivial once #140 lands — same tool, Linear-backed
  repos dispatch to Linear MCP instead of `gh`.
- **Main Agent prompt/skill snippet.** A tiny skill that a Main Agent can
  source to offer "file this as a Hydra ticket" proactively when the human
  describes a bug. Out of scope here because it's Main Agent-side, not
  Commander-side.
- **Rate-limit observability.** A `scripts/mcp-rate-limit-status.sh` for
  operators to inspect current usage. Probably ships alongside the
  `mcp-audit-tail.sh` that was already flagged as a follow-up in the MCP
  agent-interface spec.
