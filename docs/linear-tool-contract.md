# Linear MCP Tool Contract (what Hydra depends on)

Status: **UNVERIFIED AGAINST A LIVE LINEAR WORKSPACE.** See the "Operator validation" section at the bottom — every tool name, every field shape, and every filter below MUST be validated by an operator with Linear credentials before Hydra's Linear path can be trusted on production tickets.

This document defines the EXACT Linear MCP surface Hydra assumes so that:

1. A maintainer with Linear creds can line up this file against their real `claude mcp list` output and fix any drift in one PR.
2. Hydra's `worker-implementation` / `worker-review` subagents (which declare `mcpServers: [linear]` in frontmatter) have an unambiguous reference for what they are allowed to call.
3. `scripts/linear-poll.sh` and any future Linear tooling Hydra ships has one place to look for canonical argument/response shapes.

If the real Linear MCP tool names or response shapes differ from what's below, fix THIS file first, then propagate to `state/linear.example.json`, `scripts/linear-poll.sh`, and `self-test/fixtures/linear/*.json` — in that order.

---

## Assumptions

All field/tool names below are **Hydra's assumed names**. They are consistent with how other MCP servers in the ecosystem (github, notion) name analogous operations, but Linear's published MCP server may differ. Any name prefixed with `linear_` is a guess; the real server may use bare names (`list_issues`) or a different prefix.

Wherever ambiguous, the code SHOULD be keyed off a small wrapper (see `scripts/linear-poll.sh`) that can be retargeted by changing one constant rather than grepping the repo.

---

## Tools Hydra calls

### 1. `linear_list_issues` — poll for ready tickets

Hydra calls this at each autopickup tick (and on operator-issued `pick up` / `pick up N`) to find tickets matching the configured trigger.

**Args (assumed shape):**

```json
{
  "filter": {
    "team":     { "id":   "<linear-team-id>" },
    "assignee": { "email": "me" },
    "state":    { "name": "Todo" },
    "labels":   { "name": { "in": ["ready-for-hydra"] } }
  },
  "first": 50
}
```

- At most ONE of `assignee` / `state` / `labels` is populated per call — determined by `state/linear.json:teams[].trigger.type`.
- `team.id` is always required.
- `first` caps response size (Hydra never needs more than `budget.json:phase1_subscription_caps.daily_ticket_cap` per poll).

**Returns (assumed shape):**

```json
{
  "issues": [
    {
      "id":          "<linear-internal-uuid>",
      "identifier":  "ENG-123",
      "title":       "Short human title",
      "description": "Full markdown body of the issue",
      "url":         "https://linear.app/<org>/issue/ENG-123/...",
      "state":       { "id": "<state-id>", "name": "Todo", "type": "unstarted" },
      "assignee":    { "id": "<user-id>", "email": "operator@example.com", "name": "Operator" },
      "team":        { "id": "<team-id>", "key": "ENG", "name": "Engineering" },
      "labels":      [{ "id": "<label-id>", "name": "ready-for-hydra" }],
      "priority":    3,
      "createdAt":   "2026-04-16T10:00:00Z",
      "updatedAt":   "2026-04-16T10:05:00Z"
    }
  ]
}
```

Hydra only reads: `id`, `identifier`, `title`, `description`, `state.name`, `assignee.email`, `labels[].name`. Everything else is nice-to-have and ignored if missing.

### 2. `linear_get_issue` — refresh a single issue

Used when a worker needs the latest body / state after the poll (e.g. the operator edited the ticket mid-flight).

**Args:** `{ "id": "<linear-internal-uuid>" }` OR `{ "identifier": "ENG-123" }`.

**Returns:** same single-issue shape as `linear_list_issues[].issues[i]`.

### 3. `linear_add_comment` — post status back to the Linear issue

Used on:
- `worker_started` (if `state/linear.json:comment_on.worker_started` is true) — Hydra posts "Hydra worker started. Branch: `commander/<repo>-<id>`. Worktree created."
- `pr_opened` — "Draft PR opened: <github-url>. Commander review gate running next."
- `pr_merged` — "PR merged. Closing Linear issue."
- `worker_stuck` — "Hydra worker stuck. Manual review needed. Last error: <short>."
- `question_asked` — "Hydra paused and asked the operator: <question>. Will resume once answered."

**Args:**

```json
{
  "issueId": "<linear-internal-uuid>",
  "body":    "<markdown comment body>"
}
```

**Returns:** `{ "comment": { "id": "...", "url": "..." } }` — Hydra ignores the return on success and only notices failures (non-zero exit from the MCP call).

### 4. `linear_update_issue` — transition issue state

Used on the same lifecycle hooks as comments (pickup / pr_opened / pr_merged / stuck). The mapping from lifecycle-hook to target state name comes from `state/linear.json:state_transitions` (with optional per-team overrides in `teams[].state_name_mapping`).

**Args:**

```json
{
  "id":      "<linear-internal-uuid>",
  "stateId": "<target-state-id>"
}
```

OR, if the MCP server accepts state by name:

```json
{
  "id":        "<linear-internal-uuid>",
  "stateName": "In Review"
}
```

Hydra prefers `stateId` when available (the real MCP call can be wrapped to resolve `stateName → stateId` via a cached lookup from the first `linear_list_issues` response). If only `stateName` is supported, that's fine too — `scripts/linear-poll.sh` abstracts the call.

**Returns:** updated issue object (same shape as `linear_get_issue`). Hydra ignores on success.

### 5. (Optional) `linear_list_workflow_states` — state-id cache warmup

Used ONCE per team per session to build the `stateName → stateId` map. Skipped entirely if the Linear MCP server accepts state-by-name on `linear_update_issue`.

**Args:** `{ "teamId": "<linear-team-id>" }`.

**Returns:** `{ "states": [{ "id": "...", "name": "Todo", "type": "unstarted" }, ...] }`.

---

## Error handling Hydra expects

- **Auth failure** (e.g. expired OAuth, missing scope): the MCP call exits non-zero with a stderr message containing `auth` or `unauthorized`. `scripts/linear-poll.sh` detects that substring and prints the exact `claude mcp add linear` re-auth instruction.
- **Rate limiting**: Linear's API enforces per-key request limits. If the MCP call fails with a 429-equivalent, Hydra treats it like a GitHub rate-limit — increments `state/quota-health.json` and (for autopickup) counts toward the 2-strike auto-disable. The per-hour budget is `state/linear.json:rate_limit_per_hour` (default 60; tune downward for workspaces with tight limits).
- **Unknown state name**: if `state_transitions.on_pr_opened` is "In Review" but the team has no such state, `linear_update_issue` fails. Hydra surfaces one message to the operator: `"Linear state 'In Review' not found on team <team_id>. Configure state_name_mapping in state/linear.json."` — and does NOT retry.

---

## Operator validation checklist

Before considering the Linear path production-ready in your Hydra install, verify each of the following against your real Linear MCP server:

- [ ] `claude mcp list` shows `linear` as an installed server
- [ ] `claude mcp call linear <tool> '{}'` with a deliberately empty args blob returns a sensible error (proves the channel works)
- [ ] The ACTUAL tool names match this doc (or this doc gets updated in a follow-up PR)
- [ ] `linear_list_issues` response has at minimum `id`, `identifier`, `title`, `description`, `state.name`
- [ ] `linear_update_issue` accepts whichever of `stateId` / `stateName` this doc declares as primary
- [ ] `linear_add_comment` preserves markdown formatting (links, code blocks)
- [ ] A test issue assigned to you is returned by the configured assignee filter
- [ ] Transitioning a test issue through "In Progress" → "In Review" → "Done" via `linear_update_issue` works and is visible in the Linear web UI

If any box above fails to check, open a follow-up ticket referencing this document and DO NOT enable the Linear trigger for production repos in `state/repos.json`.

---

## Why this doc exists as an explicit contract

Hydra's worker subagents can call the Linear MCP directly. That's convenient for the agent loop but dangerous for the framework — if the tool shapes drift silently, workers will emit malformed calls and Hydra will look broken in mysterious ways. By pinning the contract here, any Linear MCP update that breaks the contract shows up as a PR to THIS file (easy to review), not as a distributed-edit across three agents and a shell script.

Think of this as Hydra's "SPI for Linear": change this interface deliberately, not by accident.
