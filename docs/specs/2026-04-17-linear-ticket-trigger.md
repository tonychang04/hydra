---
status: draft
date: 2026-04-17
author: hydra worker (issue #140)
---

# Linear ticket trigger: actually poll a Linear team and pick up tickets

Implements: ticket #140 (Tier T2). Related: #5 (Linear MCP contract scaffolding,
landed 2026-04-16), #139 (setup wizard for Linear config, in flight).

## Problem

CLAUDE.md has documented a Linear ticket trigger for months:

> Operating loop step 3 — **linear**: via the `linear` MCP server, use the
> trigger (assignee/state/label) configured in `state/linear.json:teams[].trigger`.

In practice, **no code reads `state/linear.json`**. The scaffolding from #5
landed the pieces — `scripts/linear-poll.sh`, `docs/linear-tool-contract.md`,
`state/linear.example.json`, a golden self-test — but nothing glues them to
Commander's pickup loop. An operator who ran `./hydra connect linear` (via
#139) would find the poll script works in isolation, the config file
validates, and then nothing ever happens: the next autopickup tick keeps
running GitHub `gh issue list` calls and never even tries Linear.

That's "vapor" — documented behavior, no runtime path. #140 closes that gap.

## Goals

1. A `state/linear.json` config file is **schema-validated** on every
   Commander preflight, same path as every other `state/*.json`. Drift gets
   caught before a tick runs, not during.
2. A `scripts/linear-pickup-dispatch.sh` helper turns `(state/linear.json,
   per-team `linear-poll.sh` output)` into a normalized list of "ready"
   tickets, filtering out tickets already in a commander-managed state so the
   idempotency rule from CLAUDE.md Operating loop step 3 ("skip any issue
   already in a commander-managed state") is enforced mechanically, not by
   prose.
3. `worker-implementation` (and `worker-codex-implementation`) PRs link back
   to the originating Linear issue in the PR body, so the PR ↔ ticket link
   survives beyond the Linear state transition.
4. A **regression test** under `self-test/` proves the full pickup path:
   given a fixture Linear config + fixture poll output with 2 ready issues
   and 1 already-working issue, Commander dispatches exactly 2 candidate
   tickets. No live Linear MCP required.
5. CLAUDE.md gets a ONE-LINE pointer (operator's strict rule from #138 — no
   new inline procedure in CLAUDE.md).

## Non-goals

- **Writing back to Linear on PR merge.** That's a separate ticket. The
  existing `linear_add_comment` and `linear_update_issue` calls in
  `worker-implementation.md`'s "Ticket-source update" step already cover the
  pr_opened transition; merge-time writeback is a follow-up.
- **Linear webhook push.** Polling is fine for Phase 1. Push is Phase 2.
- **Multi-workspace support.** One Linear workspace per Hydra install.
  `state/linear.json` has a single top-level config block.
- **Changing the existing `linear-poll.sh` contract.** It already supports
  both live and fixture modes; we don't need to touch its normalization
  logic. We just add a thin layer above it.

## Proposed approach

### 1. `state/schemas/linear.schema.json`

Ship the JSON Schema ticket #139 was going to author. Since #139 hasn't
shipped yet and #140 needs the schema to enforce preflight, we author it
here. If #139 lands first with a conflicting schema, rebase; the contract is
simple enough that the diff will be one-to-one with the `state/linear.example.json`
shape.

`validate-state-all.sh` auto-discovers `state/schemas/*.schema.json` and
pairs each with `state/<basename>.json`, so zero wiring changes in the
validator: adding the schema makes `state/linear.json` (when present) a
first-class preflight input.

### 2. `scripts/linear-pickup-dispatch.sh`

A new helper script, same shell+jq dialect as everything else in `scripts/`.
Responsibilities:

1. Read `state/linear.json` (or `--config <path>` for tests).
2. For each team in `teams[]`: invoke `scripts/linear-poll.sh` with the
   team's trigger (or `--fixture <path>` in test mode).
3. Filter the poll output to drop tickets already in a
   **commander-managed state**. The four states in `state_transitions` —
   `on_pickup` / `on_pr_opened` / `on_pr_merged` / `on_stuck` — plus any
   per-team `state_name_mapping` overrides define the set.
4. Emit a JSON array on stdout: `[{team_id, repo, issue: {...}}, ...]`
   ready for Commander to consume. One entry per ready ticket per team.

Keeping this as a separate helper (instead of jamming it into
`linear-poll.sh`) preserves #5's contract: `linear-poll.sh` is a thin wrapper
over one MCP tool call, testable in isolation. Pickup dispatch is a Hydra
concern on top of that.

Exit codes:
- `0` — success (zero or more tickets)
- `1` — linear-poll.sh failed for at least one team (propagates upward)
- `2` — usage / config malformed / jq missing
- `3` — Linear MCP server not installed (propagates exit 3 from linear-poll.sh)

### 3. Worker PR body carries Linear URL

Update `.claude/agents/worker-implementation.md` and
`.claude/agents/worker-codex-implementation.md` so the PR-open step includes
a Linear URL reference in the PR body when the ticket source is Linear.

Format (per AC #4):

```
Closes LIN-123 — https://linear.app/org/issue/LIN-123/...
```

`Closes LIN-123` is inert on GitHub's close-on-merge parser, so this is
purely informational — the Linear issue is closed via the
`linear_update_issue` call on pr_merged (a separate path). The URL in the
body gives humans (and future Commander sessions reviewing closed PRs) a
direct click-through from the PR to the Linear ticket.

### 4. Regression test

New fixture directory `self-test/fixtures/linear-ticket-trigger/`:
- `linear-fixture-config.json` — a mock `state/linear.json` with one team.
- `poll-output-2-ready-1-working.json` — mock `linear-poll.sh` output:
  3 issues total, 2 in "Todo" (ready), 1 in "In Progress" (commander
  already working on it).
- `run.sh` — shell script that invokes
  `scripts/linear-pickup-dispatch.sh --config ... --fixture-poll ...`
  and asserts exactly 2 tickets come back, identifiers match.

Runnable standalone: `bash self-test/fixtures/linear-ticket-trigger/run.sh`.

A new **golden case** in `self-test/golden-cases.json` should be added as a
follow-up — the ticket explicitly asks us not to touch
`self-test/golden-cases.example.json` because the operator has a pending
edit. The report on this PR notes the golden case text for the operator to
add when they reconcile their pending edit.

### 5. CLAUDE.md pointer (one-line)

Operating loop step 3 already lists `linear` as a trigger mode. No inline
procedure added; one sentence pointing at
`scripts/linear-pickup-dispatch.sh` and this spec is enough.

### Alternatives considered

- **Inline the dispatch logic into Commander's system prompt.** Rejected:
  tested prose is a contradiction in terms. Shell scripts + golden self-tests
  is how every other Hydra ticket-source code path works (see
  `scripts/hydra-issue.sh` for GitHub, or the rescue-worker suite). Consistency
  wins.
- **Skip the new dispatch helper; make `linear-poll.sh` filter
  commander-managed states inline.** Rejected: `linear-poll.sh` is the
  documented MCP tool wrapper (see #5's contract doc). Adding Hydra-specific
  filter logic inside it would muddy the "retargetable wrapper" property —
  an operator with a different MCP install would have to fork the script to
  keep polling while disabling the filter. The dispatch layer is orthogonal.
- **Use Linear labels for commander-managed state instead of workflow
  states.** Rejected: Linear's data model treats states as a proper state
  machine (`type: unstarted | started | completed | canceled`), labels as
  free-form. The existing scaffolding (state_transitions, state_name_mapping)
  already commits to states. Adding a label dimension would be a bigger
  change than #140's scope.

## Test plan

Local, no Linear credentials needed:

1. `bash -n scripts/linear-pickup-dispatch.sh` — syntax clean
2. `jq empty state/schemas/linear.schema.json` — valid JSON schema
3. `scripts/validate-state-all.sh` — existing validator now covers
   `state/linear.json` if present (without a file, skip-as-missing — no
   false fail)
4. `bash self-test/fixtures/linear-ticket-trigger/run.sh` — new regression
   test: 3 fixture issues → 2 ready tickets dispatched
5. Existing `bash self-test/fixtures/linear/run.sh` — unchanged, still green
6. `scripts/linear-pickup-dispatch.sh --help` — prints usage cleanly
7. `scripts/linear-pickup-dispatch.sh` without args + without `state/linear.json`
   — exits 0 with an empty array (operator who hasn't set up Linear isn't
   blocked)

## Risks / rollback

- **Risk:** `state/schemas/linear.schema.json` conflicts with the schema #139
  authors. **Mitigation:** the contract is the exact shape of
  `state/linear.example.json`, which #139 also consumes — if there's drift,
  fix the schema in one line. The PR for #140 links to this risk in its
  body so #139's rebase reviewer sees it.
- **Risk:** A Linear MCP response-shape change silently breaks the filter
  logic (e.g. `state.name` renamed to `state.label`). **Mitigation:** the
  existing `self-test/fixtures/linear/mock-list-issues-response.json`
  pins the shape. Any Linear MCP version bump that drifts the shape breaks
  the existing golden case `linear-mcp-contract` before it reaches
  `linear-pickup-dispatch.sh`.
- **Risk:** Operator has `state/linear.json:enabled=false` (default from
  `state/linear.example.json`) but still flips a repo's `ticket_trigger` to
  `linear`. Today: poll runs anyway, could fail loudly on missing team_id.
  **Mitigation:** `linear-pickup-dispatch.sh` checks `enabled` first and
  exits 0 with an empty array if the top-level flag is false. Explicit
  behavior beats implicit failure.
- **Rollback:** revert the commit. The new schema, helper script, and
  fixtures are all additive — no existing state is mutated. Workers that
  never see a Linear-triggered ticket are unaffected.

## Implementation notes

- **Coordination with #139:** #139 authors the setup wizard
  (`./hydra connect linear`) that writes a real `state/linear.json`. It
  explicitly owns `state/schemas/linear.schema.json` in its ticket body.
  #140 races against #139 because we need the schema to enforce preflight;
  if #140 lands first, #139 rebases (one-to-one diff); if #139 lands first,
  #140 drops that file from its PR. The `linear-pickup-dispatch.sh` helper
  and `worker-implementation.md` updates are independent of #139.
- **Coordination with #138:** #138 trims CLAUDE.md. The one-line pointer
  added here fits the "one-line pointers only" rule. If #138 lands first
  and reshapes the "Operating loop" section, #140 rebases onto the new
  structure (the pointer moves, content stays one line).
- **No CLAUDE.md section rewrite.** This ticket ADDS a one-sentence pointer
  to the existing step 3 bullet. It does NOT add a new section, expand the
  existing section, or document Linear-specific procedures inline.
