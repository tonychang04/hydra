---
status: implemented
date: 2026-04-17
author: hydra worker (#138)
---

# Auto-dispatch: `worker-test-discovery` on repeat "test procedure unclear"

## Problem

The `worker-test-discovery` subagent exists so workers never have to re-discover how to test a repo. When a `worker-implementation` returns with `QUESTION: test procedure unclear` (or close variant), Commander used to wait for the operator to type `test discover <repo>` before dispatching discovery. That ties a routine trigger to a human, which contradicts the "machine runs while operator sleeps" guarantee.

This spec formalizes the auto-dispatch trigger — when the same repo trips the phrase twice in a row, Commander spawns `worker-test-discovery` itself before the next retry of the original ticket.

## Goals

- Commander detects repeated "test procedure unclear" questions and dispatches `worker-test-discovery` without operator involvement.
- Original ticket gets parked (`commander-pause`) and resumed once the discovery PR lands.
- Budget-safe: the auto-dispatched discovery counts against `max_concurrent_workers`; preflight failures defer rather than bypass.
- Trigger phrase narrow enough to avoid false positives on other test-shaped questions ("which framework should I add?" is still an escalation).

## Non-goals

- Running this logic on `worker-review` or other worker types. Only `worker-implementation` failures count.
- Auto-merging the discovery PR. The normal review-gate still applies; operator still merges T2+.
- Retroactive re-discovery on already-landed tickets.

## Proposed approach

### Trigger detection

Scan the last two completed `logs/<ticket>.json` entries for the same `repo` where the worker was `worker-implementation`. If both end in `result: paused-on-question` with question text matching the regex `/test procedure unclear/i`, the trigger has fired.

"Same repo, consecutive across any two tickets" is the key constraint — two different tickets on `repo-a` trigger it, but a ticket on `repo-a` followed by a ticket on `repo-b` does not, even if both say "test procedure unclear". The signal is repo-specific (test infra lives per-repo).

### Sequencing

1. Commander detects the 2x trigger during its normal post-tick scan.
2. Preflight check (same as any spawn): if `max_concurrent_workers` would be exceeded, defer to the next tick — do NOT bypass preflight. The original ticket stays paused.
3. Spawn `worker-test-discovery` on the target repo. Same worktree conventions as the interactive `test discover <repo>` command.
4. Park the original ticket: label `commander-pause`, comment on the ticket explaining why (link to the discovery PR once opened).
5. Discovery PR opens → normal Commander review gate runs.
6. Once discovery PR is merged (or ready-for-merge with operator surfaced), resume the original ticket via the normal `retry #<n>` path. The newly-landed `TESTING.md` (or updated `CLAUDE.md` testing section) is visible to the next `worker-implementation` via its Step 0 orient.

### Budget interaction

The auto-dispatched `worker-test-discovery` is a normal worker for budget purposes. If preflight fails, defer (next tick, next operator command, or next retry attempt will try again). Never spawn past the cap.

### Trigger scope

The exact phrase "test procedure unclear" is the detection key. Variants the rule does NOT catch (these still escalate to operator):

- "which test framework should I add?" — this is a scope/design question, not a discovery-gap question
- "how do I run the integration tests specifically?" — narrow, one-off; operator answer is cheaper than discovery
- "tests are failing on main" — failure signal, not a discovery-gap; root-cause investigation first

Workers emit "test procedure unclear" when their Step 0 orient (CLAUDE.md, AGENTS.md, README.md, `memory/learnings-<repo>.md`) gave them nothing actionable. That's the discovery-gap signal.

### Alternatives considered

- **Alternative A — trigger on a single occurrence.** Rejected: one-off questions can come from any number of causes (worker fatigue, partial docs). Two in a row on the same repo is a much cleaner "the repo itself has a doc gap" signal.
- **Alternative B — trigger on any "test"-related question.** Rejected: false-positive rate too high; discovery runs would starve real ticket throughput.
- **Alternative C — put the detection in a separate scheduler.** Rejected: the 2x detection fits inside Commander's normal post-tick scan; a separate scheduler is extra surface area for no behavioral gain.

## Test plan

- Golden case documented: `test-discovery-dormant-to-active` in `self-test/golden-cases.example.json`, kind `worker-subagent`. Currently SKIP'd pending the `worker-implementation` SKIP-path executor (ticket #15 follow-up). Once that executor lands, the case exercises: two fixture log files with matching phrase → Commander dispatches `worker-test-discovery` → parks original ticket.
- Trigger-phrase unit test (follow-up): a dedicated `scripts/test-auto-dispatch-trigger.sh` could grep fixture log JSONs and assert the detection predicate. Out of scope for this spec — documented as follow-up so we don't ship detection logic without a test once the SKIP-path lands.

## Risks / rollback

- **Risk: false positive starves a ticket.** If a ticket is paused by this rule erroneously, the operator can use the normal `retry #<n>` path to un-park it; the discovery PR can be closed unmerged if it's genuinely off-target.
- **Risk: the trigger phrase drifts in worker prompts and the detection regex goes stale.** Mitigation: the phrase is narrow-by-design. If we want to broaden it, that's a spec revision with a golden case update.

**Rollback:** delete or comment out the detection block in Commander's post-tick scan. The feature is additive; disabling it returns to interactive-only dispatch.

## Implementation notes

- The rule is documented in `CLAUDE.md` as a pointer section. Full detection/sequencing/budget rules live here.
- First execution is currently wired only at Commander's decision layer. The `test-discovery-dormant-to-active` golden case documents the expected artifact.
