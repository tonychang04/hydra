---
status: draft
date: 2026-04-17
author: hydra worker (ticket #83)
---

# worker-auditor subagent: periodic codebase scan vs north-star, auto-file drift tickets

## Problem

CLAUDE.md opens with Commander's directional goal: *"every ticket, every question, every failure should make you slightly less dependent on the human."* Today Commander is purely reactive. It picks up tickets the operator filed; it does not pro-actively surface gaps between what its own framework docs promise and what the codebase actually ships.

Concrete examples of drift already sitting in-repo that no one filed a ticket for:

- CLAUDE.md's "Scheduled retro" section says *"auto-run every Monday 09:00 local"* — nothing in `state/autopickup.json` or the `/loop` invocation wires this up. The retro is still operator-invoked.
- CLAUDE.md's "Memory hygiene" section says *"After every 10 completed tickets … draft skill PRs for promotion-ready entries"* — no counter in `state/` currently tracks "completed tickets since last hygiene pass"; the `compact memory` command exists but nothing triggers it automatically.
- CLAUDE.md's "Auto-dispatch: worker-test-discovery" section marks itself with *"only wired at the commander decision layer"* — a behavioral claim with no enforcement.

These are the kind of gaps a human eventually notices and files by hand. If we delegate the noticing to a subagent that runs on command (and, later, on a schedule), the self-improvement loop closes without additional operator labor.

Ticket #9 was an earlier, broader take on this idea; it also tried to give the auditor permission to propose CLAUDE.md edits directly. Self-modification of framework files is a separate, riskier conversation (mostly blocked by this session's permission denylist anyway). **This spec is deliberately narrower:** the auditor reads, files GitHub issues, and does nothing else.

PR #65 was a prior in-progress attempt that closed with conflicts 2026-04-17; scope sprawled. This ticket re-narrows to the scaffold.

## Goals / non-goals

**Goals:**

1. A new subagent type `worker-auditor` at `.claude/agents/worker-auditor.md` with a tool allowlist that makes code edits impossible — only `gh issue create` is a write action.
2. A new label `commander-auto-filed` that the operator can filter on to see (or dismiss) bot-filed tickets.
3. A new operator-invoked command `audit` documented in CLAUDE.md's commands table.
4. A template at `docs/templates/auto-filed-issue.md` defining the skeleton body every filed issue uses — so auditor output is consistent, easily reviewable, and easy to compare across invocations.
5. A self-test fixture case `worker-auditor-dry-run` that documents the expected Q+A shape for a future live executor run. SKIPped today (same blocker as the other `worker-subagent`-kind cases — see #15 follow-up).

**Non-goals (explicit, for future PR scope discipline):**

- **No detection rules shipped in v1.** The subagent system prompt describes the categories it looks for (north-star-claim-vs-code-reality drift), but the concrete grep patterns, jq queries, or line-citation heuristics are not in this PR. Those arrive one-by-one as operators notice specific gap shapes. Ship scaffold first, tune later.
- **No scheduled invocation.** Operator-invoked `audit` is enough for v1. The retro cron piggyback and the `post-merge-audit` hook mentioned in the ticket are follow-ups.
- **No audit of other repos.** Restrict to Hydra-meta loop for now. Filing issues on `insforge-repo/*` has a different trust profile and can wait.
- **No CLAUDE.md self-editing.** The auditor NEVER proposes direct edits to framework files (CLAUDE.md, policy.md, budget.json). If a gap requires a framework edit, the auditor files an ISSUE describing the gap — the fix is still authored by a regular `worker-implementation` after operator triage.

## Proposed approach

A new subagent definition following the existing `.claude/agents/worker-review.md` shape: short frontmatter with `isolation`, `maxTurns`, `skills`, `disallowedTools`; a short system prompt describing inputs, flow, and hard rules.

The key architectural decisions:

1. **Write capability is surgically limited.** Frontmatter sets `disallowedTools: [Edit, Write, NotebookEdit, WebFetch, WebSearch]`. The only write action available is `Bash` scoped to `gh issue create` (and the read-only `gh` subcommands used for dedup). A worker that physically cannot call `Edit` or `Write` cannot, by construction, touch the codebase.

2. **Self-limit to ≤3 issues per invocation.** Hard cap in the system prompt, enforced by counting before each `gh issue create`. Default N=3 is deliberate: the auditor is meant to drip-feed findings, not flood the inbox. If N needs tuning, a future PR bumps the default in the subagent definition.

3. **Dedup against open issues via substring match on title.** Before filing, the worker runs `gh issue list --state open --json number,title` and refuses to file if any existing title contains a substring ≥12 chars matching the new title (after normalizing whitespace+case). This catches the common case where the auditor re-discovers a gap the operator already filed. Non-rigorous on purpose — the operator closes false-dedup-matches by hand.

4. **Auto-tier per policy.md.** The worker classifies each finding inline: docs-only gap → T1 (`tier-1` label), source-gap → T2 (`tier-2`), security/compliance gap → T3 (`tier-3`). This isn't a new policy — it's the same classifier Commander uses on incoming tickets, moved earlier in the pipeline.

5. **Every filed issue cites evidence.** The issue body (rendered from `docs/templates/auto-filed-issue.md`) MUST include a "Source:" line with the CLAUDE.md line number(s) or log file path that motivated the filing. No anonymous robot-complaints.

6. **Labels applied on create.** Every auto-filed issue gets `commander-ready` AND `commander-auto-filed`. The first tells Commander to work it on the next pickup tick; the second lets the operator filter (`gh issue list --label commander-auto-filed`) or bulk-close (`gh issue list --label commander-auto-filed --json number -q '.[].number' | xargs -I{} gh issue close {}`) if the auditor's signal-to-noise ratio disappoints.

Workflow end-to-end:

```
Operator types "audit"
  ↓
Commander spawns worker-auditor subagent
  ↓
Worker reads CLAUDE.md + logs/*.json + memory/retros/*.md
Worker reads open issues → dedup set
Worker identifies ≤3 drift gaps
  ↓
For each gap:
  - Classify tier per policy.md
  - Render docs/templates/auto-filed-issue.md with Problem/Evidence/Proposed-fix/Tier/Source
  - gh issue create --title "..." --body "..." --label commander-ready,commander-auto-filed,tier-<N>
  ↓
Worker reports list of filed issue numbers to Commander, exits
  ↓
Commander surfaces to operator: "worker-auditor filed #X, #Y, #Z. Review with `gh issue view <n>`."
```

### Alternatives considered

- **Alternative A: Put the logic inline in Commander's own system prompt.** Instead of a subagent, Commander itself does the auditor pass as part of the `audit` command. Cost: pollutes Commander's context with auditor-specific logic; Commander is the decision layer, not the execution layer — per the existing architecture (`.claude/agents/` for heads, CLAUDE.md for the body). Also loses the `disallowedTools` safety gate, since Commander's tool scope is broader than a subagent's. Rejected.

- **Alternative B: Give the existing `worker-review` subagent an "audit mode" flag.** One less file to maintain; less subagent-type proliferation. Cost: muddies `worker-review`'s job ("review an existing PR"). Auditor is a different workflow (scan-not-review) with different inputs (repo, not PR) and different outputs (new issue, not review comment). Conflating them would force both subagents' system prompts to carry each other's rules. Rejected.

- **Alternative C: Cron-style scheduled audit from day 1.** Wire up the retro-cron piggyback now, skip the operator-invoked path. Cost: we don't yet know the auditor's false-positive rate. Shipping it scheduled before we've seen a dozen manual invocations risks the auditor flooding the issue tracker on its first weekly run. Phase it: ship operator-invoked now, add schedule after the auditor has earned trust on the manual path.

## Test plan

For v1 SCAFFOLD (this PR):

- **Syntax/shape check:** `.claude/agents/worker-auditor.md` has well-formed YAML frontmatter; `disallowedTools` includes `Edit`, `Write`, `NotebookEdit`, `WebFetch`, `WebSearch`. Covered by the existing `ci: syntax + spec-presence + self-test + conflict-markers` workflow.
- **Spec presence check:** `docs/specs/2026-04-17-worker-auditor-subagent.md` exists and is referenced by the PR body. Same CI workflow.
- **Label creation:** `gh label create commander-auto-filed --color "6f42c1" --description "..."` succeeds (lazy-create pattern; if label already exists, `gh label create` errors and we ignore it).
- **Template renders:** `docs/templates/auto-filed-issue.md` exists and contains all required placeholders (`{{PROBLEM}}`, `{{EVIDENCE}}`, `{{PROPOSED_FIX}}`, `{{TIER}}`, `{{SOURCE}}`).
- **Self-test case schema-valid:** `worker-auditor-dry-run` case in `self-test/golden-cases.example.json` parses as valid JSON (covered by `jq empty` in the self-test CI).

For v1 BEHAVIOR (deferred until the worker-subagent SKIP-path executor from #15 lands):

- **Dry-run assertion:** Given a fixture repo containing a known drift pattern (e.g. "CLAUDE.md says retro runs Monday 09:00 but no cron exists"), spawning `worker-auditor` should produce exactly one `gh issue create` call matching the template, labeled `commander-ready`, `commander-auto-filed`, and `tier-1` or `tier-2`.
- **Self-limit assertion:** Given a fixture with >3 known drifts, the auditor files exactly 3 (not more).
- **Dedup assertion:** Given a fixture where one of the expected findings already has an open issue with a matching title, the auditor files only the remaining N-1 findings.
- **No-write assertion:** After the worker exits, `git status` in the worktree shows zero modified files. (The worktree is unchanged; the only side-effect is on the issue tracker.)

The self-test case's `assertions` block documents each of the above. When the runner can execute worker-subagent cases, flipping `_skip_reason` to null turns the case live — no changes to the case JSON otherwise.

## Risks / rollback

- **Risk: auditor floods the issue tracker.** Mitigated by the hard ≤3 cap + dedup-by-title. If the operator still sees noise, `gh issue list --label commander-auto-filed --json number -q '.[].number' | xargs -I{} gh issue close {} --reason "not planned"` clears the slate in one command. The label exists precisely so this rollback is trivial.
- **Risk: auditor files issues that duplicate intent but not title.** E.g. "retro scheduler missing" already filed by operator as "scheduled retro not wired up". Dedup won't catch this. Accepted — the cost is one close-as-duplicate action from the operator. Better than a false-negative that makes the auditor miss a real gap.
- **Risk: auto-tiering produces wrong tier.** Worker follows the same policy.md that Commander uses; if a mis-tier happens, the operator re-labels. No production impact because T2+ PRs are human-gated on merge anyway.
- **Risk: self-modification.** The `disallowedTools` frontmatter makes it structurally impossible for the auditor to edit CLAUDE.md or any other file. If a future PR loosens that allowlist, reviewers should block.

**Rollback:**
1. Revert this PR's commit — removes the subagent definition, the label is cosmetic-only (no config depends on it).
2. Optionally `gh label delete commander-auto-filed` to strip it from the repo.
3. No state-file migration needed. The auditor doesn't write to `state/`.

## Implementation notes

(Fill in after the PR lands. Note anything surprising, template-rendering gotchas, dedup false-positive patterns observed in the first few manual runs.)
