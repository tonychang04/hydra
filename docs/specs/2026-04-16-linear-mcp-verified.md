---
status: draft
date: 2026-04-16
author: hydra worker (issue #5)
---

# Verify + complete Linear MCP integration end-to-end

Implements: ticket #5 (Tier T2). Umbrella: #4.

## Problem

Hydra's Linear integration was **scaffolded but unverified** before this spec:

- `state/linear.example.json` existed as a template but missed fields Hydra actually needs at runtime (rate-limit budget, per-team state-name overrides, poll-interval override).
- `worker-implementation` and `worker-review` both declare `mcpServers: [linear]` in frontmatter, but there was no documented contract for WHICH Linear MCP tools they're allowed to call or WHAT shape they should expect back.
- `INSTALL.md` mentioned `claude mcp add linear` in two lines — no field reference, no troubleshooting, no smoke test.
- `USING.md` listed Linear as "Phase 2 preview" with a hand-wavy parity claim ("same flow as GitHub") — operators had no concrete mapping of GitHub-flow hooks to Linear-flow hooks.
- No fixture existed to verify Hydra's assumed Linear response shape before hitting a live workspace.

The practical consequence: an operator enabling the Linear trigger today would discover schema drift, missing state-name mapping, or auth failures only after Hydra tried to pick up a real ticket — well past the point where a dry-run should have caught it.

This ticket closes the gap as far as it can be closed **without** Linear credentials in the worker environment. Remaining live-workspace validation is captured as a checklist the operator runs once.

## Goals

- A Linear MCP tool contract (`docs/linear-tool-contract.md`) that pins the exact tools, argument shapes, and response fields Hydra depends on — so that a drift in Linear's real MCP surface shows up as a PR to ONE file instead of silent runtime breakage.
- `state/linear.example.json` carries every field Hydra reads at runtime, including `rate_limit_per_hour`, `state_name_mapping` for teams with custom states, and a `poll_interval_override_min` hook for future autopickup tuning.
- A `scripts/linear-poll.sh` helper with TWO modes: live (calls `claude mcp call linear ...`) and fixture (parses a canned JSON file). Both produce the same normalized output so Commander can consume one shape regardless of source.
- Fixture-backed self-test case `linear-mcp-contract` that runs in every `self-test` pass — no Linear credentials needed, catches normalization regressions.
- `INSTALL.md` and `USING.md` sections operators can follow without needing to read the tool contract doc.
- Clear "operator: validate end-to-end" postscript on the PR with an exact checklist.

## Non-goals

- Not writing an end-to-end test that hits a real Linear workspace. That requires credentials the worker doesn't have. Captured as operator validation steps instead.
- Not replacing the Linear MCP server with a Hydra-specific Linear adapter. Hydra stays on the published MCP server; this ticket just pins the contract.
- Not changing `worker-implementation.md` or `worker-review.md` subagent behavior — they already reference `linear` in their frontmatter. This ticket is scaffolding + contract + docs + tests, not agent prompt changes.
- Not implementing Linear-triggered autopickup directly. Autopickup's tick procedure already says "per the usual trigger in `state/repos.json` (assignee / label / linear)" — this ticket just makes the linear branch reliable for when that path is exercised.

## Proposed approach

**1. Pin the tool contract** (`docs/linear-tool-contract.md`): document the 4-5 Linear MCP tools Hydra actually calls (`linear_list_issues`, `linear_get_issue`, `linear_add_comment`, `linear_update_issue`, optional `linear_list_workflow_states`), with the exact arg/response shapes Hydra assumes. Flag every assumption explicitly — a maintainer with credentials walks the checklist once and either stamps the doc as verified OR opens a follow-up PR correcting the names/shapes.

**2. Harden `state/linear.example.json`** — add the fields that were missing:
- Top-level `rate_limit_per_hour` (default 60) — feeds the existing rate-limit preflight in the autopickup loop
- Top-level `poll_interval_override_min` (nullable) — reserved for tuning Linear polls separately from autopickup interval
- Per-team `state_name_mapping` object — accommodates teams that use custom state names (e.g. `Code Review` instead of `In Review`)
- Top-level `_mcp_server_name` / `_mcp_server_install` — self-documenting pointers so operators know which MCP server and install command to use

**3. Ship a `linear-poll.sh` wrapper** that encapsulates the `claude mcp call linear ...` pattern. Fixture mode means every unit of Linear logic can be tested without network. Env-var overrides (`HYDRA_LINEAR_TOOL_LIST`) let operators retarget tool names without patching the script — useful while the contract is still being validated.

**4. Fixtures under `self-test/fixtures/linear/`**:
- `mock-list-issues-response.json` — three issues across Todo / In Progress / Ready for Hydra so the normalization step exercises every state type
- `expected-trigger-filter.json` — pins the exact filter JSON shape Hydra builds for each trigger type
- `run.sh` — a shell unit test that validates `linear-poll.sh --fixture` parses the mock correctly

**5. Golden case `linear-mcp-contract`** in `self-test/golden-cases.example.json` — script-only, no worker spawn. Runs on every `self-test` pass. Catches JSON drift, script regression, missing `jq`, and any change to the contract that doesn't propagate to the fixture.

**6. Escalation FAQ entries** for the three most likely Linear-specific failure modes (tool-name mismatch, custom state names, auth expiry mid-session). When a worker hits these, Commander answers from memory without pinging the operator.

### Alternatives considered

- **Mock the Linear MCP server directly** (spin up a fake MCP process the worker talks to): higher fidelity but adds a runtime dependency (Python/Node MCP-shim) that the rest of Hydra doesn't need. Fixture-mode in the shell wrapper gives 80% of the value at 10% of the complexity.
- **Skip the contract doc, lean on the subagent frontmatter's `mcpServers: [linear]` to imply correctness**: this is what we had. It's what caused the problem this ticket is fixing.
- **Write a Python unit test harness for the Linear flow**: Hydra is intentionally a bash+jq repo. Adding Python for one integration wouldn't match the rest of the scripts/ directory. Keep shell-native.

## Test plan

All tests run locally, no Linear credentials needed:

1. `bash -n scripts/linear-poll.sh` — syntax clean (verified during authoring)
2. `scripts/linear-poll.sh --fixture self-test/fixtures/linear/mock-list-issues-response.json` — exits 0, emits normalized JSON with `count=3` and three expected identifiers
3. `bash self-test/fixtures/linear/run.sh` — assertions on states, labels, assignees, source field
4. `jq empty` on every JSON file (`state/linear.example.json`, `self-test/fixtures/linear/*.json`, `self-test/golden-cases.example.json`)
5. The `linear-mcp-contract` golden case runs under `self-test` and covers all of the above in one invocation

## Risks / rollback

- **Risk:** Operator enables `state/linear.json:enabled=true` without walking the `docs/linear-tool-contract.md` validation checklist → first live call breaks in a surprising way. **Mitigation:** INSTALL.md explicitly calls out the validation step and the status banner at the top of the contract doc reads "UNVERIFIED AGAINST A LIVE LINEAR WORKSPACE" in bold. No downstream change flips the enabled flag.
- **Risk:** Real Linear MCP tool names differ from Hydra's assumptions → every Linear-triggered ticket fails. **Mitigation:** env-var overrides in `linear-poll.sh` let operators retarget without a code patch while a doc-fix PR is in review. FAQ entry tells Commander to escalate rather than invent.
- **Risk:** Fixture drifts from reality over time as Linear evolves its MCP server. **Mitigation:** the golden case runs on every `self-test`; when Linear's MCP version bumps, validate and update the fixture in the same PR as the contract doc.
- **Rollback:** revert this commit. No runtime state mutates (the `.example.json` is just a template); worktrees / existing Linear integrations (there are none yet) keep working.

## Implementation notes

### What was verified without creds

- Shell syntax (`bash -n`) on `scripts/linear-poll.sh`
- `scripts/linear-poll.sh --fixture <mock>` parses correctly, flattens assignee/labels, preserves state names verbatim
- All JSON files are valid (`jq empty` clean)
- Fixture's three-issue variety exercises assignee trigger (first two issues), label trigger (`ready-for-hydra` on issues #1 and #3), and state trigger (`Ready for Hydra` on issue #3) code paths during normalization
- `state/linear.example.json` field additions don't break any existing consumer (no code reads the example file directly — it's pure template)

### What the operator MUST validate end-to-end before trusting production tickets

1. `claude mcp add linear` authenticates cleanly
2. `claude mcp list` shows the `linear` server
3. Actual Linear MCP tool names match `docs/linear-tool-contract.md` — if not, PR to fix the doc + the script env-var defaults
4. `linear_list_issues` returns the expected response shape (walk through each field in the contract)
5. `linear_update_issue` accepts whichever of `stateId` / `stateName` is declared primary
6. State transitions Todo → In Progress → In Review → Done work on a test issue via `linear_update_issue`
7. Posted comments preserve markdown
8. Assignee filter returns the operator's actual open Linear issues

Each box in `docs/linear-tool-contract.md:## Operator validation checklist` maps to one of the above. An operator who ticks all boxes and encounters no drift can then set `"enabled": true` in their `state/linear.json` and flip the first repo's `ticket_trigger` to `"linear"`.

### Open follow-up work (out of scope for this ticket)

- Once validated, update the status banner in `docs/linear-tool-contract.md` from "UNVERIFIED" to "Verified against linear-mcp@<version>". Track the Linear MCP server version in `memory/learnings-hydra.md`.
- Add a self-test case that exercises `linear-poll.sh` in live mode against a safe-to-call Linear workspace (gated on `HYDRA_LINEAR_SMOKE_TEAM_ID` env var, skipped if absent).
- If the real Linear MCP `list_issues` response paginates (cursor-based), wire pagination into `linear-poll.sh` — today we cap at `--first 50`, sufficient for a single poll tick but would miss a large backlog during initial adoption.
