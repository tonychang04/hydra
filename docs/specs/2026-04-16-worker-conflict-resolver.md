---
status: implemented
date: 2026-04-16
author: hydra worker (commander/hydra-7)
---

# worker-conflict-resolver subagent

## Problem

When N parallel `worker-implementation` workers each open PRs against the same repo, they routinely touch the same additive surfaces — the CLAUDE.md commands table, the Worker types table, `self-test/golden-cases.example.json`, `memory/escalation-faq.md`. Each PR merges clean against `main` at open time, but by the time the second PR is ready the first has landed, and the second now has a textbook additive conflict.

Today the human Commander (the operator) resolves these by hand: pull both branches, take both rows, dedupe, commit, open a replacement PR, label the source PRs superseded. It's mechanical, deterministic, and it happens often enough to be annoying — every parallel batch of 2+ PRs touching memory or CLAUDE.md generates at least one. The machine is supposed to run while the operator sleeps, but merge bookkeeping wakes them up.

The signal that forced this spec: ticket #7 was explicitly filed after repeated manual additive merges across the last ~10 parallel Commander batches.

## Goals

- A new `worker-conflict-resolver` subagent in `.claude/agents/` that takes a list of PR numbers and produces a single superseding merge PR
- Deterministic resolution for additive conflicts (table rows, appended sections, JSON array elements) — no semantic judgment
- Hard stop + escalation via `QUESTION:` block for anything ambiguous (same-line edits, delete-vs-modify, key collisions with different values)
- Two Commander commands wired into the commands table: `resolve conflicts #A #B [#C ...]` (explicit list) and `resolve all conflicts` (survey + batch)
- Memory FAQ entry codifying the additive-vs-semantic rules so future workers stay consistent with them
- A self-test fixture documenting the expected behavior on a canonical additive conflict (two rows added to the same CLAUDE.md commands table)

## Non-goals

- **Not** implementing a `gh` wrapper or shell script that Commander uses to spawn the resolver. The subagent prompt is the deliverable; scripting is a follow-up ticket.
- **Not** auto-merging the superseding PR. Normal Commander review gate + human merge policy still applies (T2+).
- **Not** handling multi-way semantic merges. If anything is semantic, escalate — period.
- **Not** changing the policy tier of any source PR. The resolver inherits the highest tier in the set (but that's Commander's classification to make at spawn time).
- **Not** a real-PR exercise path yet. This PR ships the subagent DEFINITION; actual spawn-and-test against live conflicting PRs is a follow-up once real conflicts occur.

## Proposed approach

A standard Claude Code subagent definition at `.claude/agents/worker-conflict-resolver.md` with the usual frontmatter (`isolation: worktree`, `memory: project`, `maxTurns: 40`, `color: purple`). The body of the subagent is the procedural prompt — fetch each PR branch, create a merge branch off `main`, merge in numeric order, classify every conflict region against an explicit allow-list of additive patterns, validate with `bash -n` / `jq empty` / markdown-table-column-count, open a draft superseding PR, label source PRs `commander-superseded`.

The deterministic-vs-semantic split is the key design decision. The allow-list of "additive = safe to auto-resolve" is deliberately narrow: (a) markdown table rows added on both sides; (b) new sections appended to the same file by both sides; (c) new elements added to the same JSON array by both sides; (d) new keys added to the same JSON object by both sides (if they collide on the same key with different values, STOP). Everything else — same-line edits, delete-vs-modify, renames, key-value collisions — is semantic and escalates. The memory FAQ entry makes this list the source of truth so future edits to the resolver stay aligned.

Ordering: PRs are merged in numeric PR-number order (lowest first). When both sides added table rows, we keep both in numeric-PR order. This is arbitrary but deterministic and matches the operator's existing manual convention.

### Alternatives considered

- **Alternative A: full auto-resolver with conflict-type inference.** Let the worker infer from context whether a conflict is "safe." Rejected because this is exactly where data gets lost — a worker that thinks it's being clever about semantic conflicts is the failure mode we're explicitly preventing. Narrow allow-list is the point.
- **Alternative B: bash script in `scripts/` that does the merge deterministically, no LLM involved.** Tempting because the work is mechanical. Rejected because (i) the `QUESTION:` escalation path is LLM-shaped and we want the same escalation UX, (ii) labeling + commenting PRs via `gh` is easier to express in a prompt than a shell script with error handling, (iii) a follow-up ticket can ship the shell wrapper once we see real patterns — don't prematurely optimize.
- **Alternative C: have `worker-implementation` detect and resolve its own merge conflicts.** Rejected because it couples two concerns (implement vs merge), inflates `worker-implementation`'s prompt, and makes the escalation path ambiguous (which worker is stuck, the implementer or the merger?). Dedicated subagent is cleaner.

## Test plan

- YAML frontmatter in `.claude/agents/worker-conflict-resolver.md` parses (eyeball check; keys match `worker-implementation.md` shape)
- `jq empty self-test/golden-cases.example.json` still passes after adding the new case
- `jq empty` on any new JSON fixtures passes
- New self-test case `conflict-resolver-additive` (kind: `worker-subagent`, SKIP in current runner — mirrors `test-discovery-dormant-to-active`) documents the expected artifact: a merged PR containing both added table rows, no dupes
- Fixture directory `self-test/fixtures/conflict-resolver/` contains base + two diffs + expected resolution + a documented semantic-conflict example (what NOT to auto-resolve)
- Memory FAQ entry under "Conflict resolution" codifies the categorization rules

End-to-end exercise (live PRs) is explicitly a follow-up — requires real conflicting PRs to exist, and Commander-side plumbing to invoke the resolver. Documented below.

## Risks / rollback

- **Risk:** the resolver's "additive" classifier misclassifies a semantic conflict as additive and silently merges. **Mitigation:** narrow allow-list (four explicit patterns, everything else escalates), mandatory `jq empty` / `bash -n` / table-column-count validation. **Rollback:** the superseding PR is a separate commit — if it's wrong, close it and the source PRs are still open.
- **Risk:** both sides added the same row with trivially different whitespace; the resolver keeps both, creating a near-duplicate. **Mitigation:** the prompt says "deduplicate rows that are byte-for-byte identical" — if operators see trivial-diff dupes slipping through, tighten to trim+compare. Low urgency.
- **Risk:** `gh pr create` fails due to branch-protection on main. **Mitigation:** the superseding branch is `commander/merge-<pr1>-<pr2>-...`, not a protected branch; PR opens as draft.
- **Rollback:** revert `.claude/agents/worker-conflict-resolver.md` + the three CLAUDE.md rows. No state file changes. Source PRs (labeled `commander-superseded`) can be unlabeled manually if the resolver's output is rejected.

## Implementation notes

The spawn-and-test path needs real conflicting PRs to exercise end-to-end. The self-test case is SKIP'd in the current runner (mirrors `test-discovery-dormant-to-active`'s SKIP status) pending either (a) a `worker-subagent`-kind executor in `self-test/run.sh`, or (b) a live pair of conflicting PRs manufactured for the test.

Follow-up tickets:
- `scripts/resolve-conflicts.sh` wrapper that Commander can invoke directly (shell-level equivalent of the resolver prompt for cases where the conflict is 100% additive and a human can skim the diff)
- Commander-side plumbing for `resolve all conflicts` — the survey step (`gh pr list --state open` + test-merge each pair) is non-trivial and belongs in its own ticket once we have real volume
- Live self-test case once parallel conflict patterns accumulate and a repeatable fixture can be checked in
