---
status: implemented
date: 2026-06-07
author: hydra worker (#270, closes #265)
relates-to: docs/specs/2026-06-07-claudemd-router-file-map.md
---

# Commander command reference (full semantics)

## Problem

The `Commands you understand` table in `CLAUDE.md` is the single heaviest H2
section (it was 2407 chars at the start of #270). Most of its weight is in the
right-hand "You do" column, which carries full procedural semantics — flag
clamps, side-effect lists, exact script names, and spec pointers. Per the
CLAUDE.md scope rule (`memory/feedback_claudemd_bloat.md`: routing tables + hard
rails + one-line spec pointers only), that substance belongs in a spec, with
CLAUDE.md keeping a terse routing one-liner per command.

This spec is the authoritative expansion of every command row. CLAUDE.md's
`Commands you understand` table lists the trigger phrase + a terse action; when
the operator issues a command and the terse line is not enough, read the matching
row below.

## Command semantics

Each entry: **trigger** → what Commander does in full, including the exact script
and the governing spec.

| Trigger | Full behavior |
|---|---|
| `status` / `what's running` | Summarize `state/active.json` + recent `logs/<ticket>.json`. Include workers paused on a `QUESTION:` so the operator can answer them. |
| `pick up N` | Run the main spawn loop, spawning up to N `worker-implementation` agents subject to preflight + concurrency headroom. |
| `pick up #42` | Spawn one `worker-implementation` on ticket #42 (after tier classification; T3 → refuse). |
| `review PR #501` | Spawn one `worker-review` on PR #501. Never makes code changes. |
| `test discover <repo>` | Spawn `worker-test-discovery` against `<repo>` to find + document a working test procedure. |
| `retry #42` | Remove the `commander-stuck` label, re-spawn `worker-implementation` with the prior failure log threaded in as a hint. |
| `undo #501` | Revert a merged Commander PR. Verify main CI is green and the PR is < 72 h old (or get explicit confirmation), open a revert PR, label `commander-undo`, surface for merge. |
| `pause` / `resume` | Toggle the `commander/PAUSE` file (presence = paused; preflight refuses to spawn while present). |
| `autopickup every N min` | Enter scheduled auto-pickup. N is clamped to `[5,120]` (default 30). State in `state/autopickup.json`. See `docs/specs/2026-04-16-scheduled-autopickup.md`. |
| `autopickup off` | Set `state/autopickup.json:enabled=false`. In-flight workers keep running; only new pickups stop. |
| `resolve conflicts #A #B [...]` | Spawn `worker-conflict-resolver` on the named PR set; return the superseding PR link. One PR per spawn (see `memory/feedback_conflict_resolver_scope.md`). |
| `resolve all conflicts` | Survey open PRs for mutual / main conflicts, batch them, spawn one resolver per batch. |
| `kill <id>` | `TaskStop <id>`, update `state/active.json`, label the ticket `commander-stuck`. |
| `merge #501` | Tier-aware. Run `scripts/merge-policy-lookup.sh <owner>/<name> <tier>` and obey: T1 auto on CI green, T2 needs operator OK, T3 refuse (hardcoded `never`). `--queue` / `queue:*` routes to `gh pr merge --merge-queue --squash` with fallback (`docs/specs/2026-04-17-merge-queue.md`). Per-repo override via `state/repos.json:repos[].merge_policy` (`docs/specs/2026-04-17-per-repo-merge-policy.md`). |
| `reject #501 reason: ...` | `gh pr close` the PR and label it `commander-rejected`, recording the reason. |
| `quota` / `cost today` | Report tickets done + wall-clock minutes + rate-limit health from `state/quota-health.json` + `state/budget-used.json`. |
| `repos` | Show `state/repos.json`; edit the enabled-repo list on request. |
| `answer #42: <guidance>` | `SendMessage(worker_id, guidance)` to the paused worker, then append the Q+A to `memory/escalation-faq.md` so the next worker self-serves. |
| `compact memory` / `promote learnings` / `archive stale` | Run memory hygiene on demand: merge dups, archive stale entries → `memory/archive/`, draft skill-promotion PRs. See `memory/memory-lifecycle.md`. |
| `retro` | Run the weekly retro → `memory/retros/YYYY-WW.md`, then auto-file proposed edits. See `docs/specs/2026-04-16-retro-workflow.md`. |
| `self-test` / `self-test <id>` / `self-test --parallel` | Run the regression harness against golden closed PRs. See `self-test/README.md`. |
| `audit` | Spawn `worker-auditor` — files up to 3 `commander-ready` + `commander-auto-filed` issues. See `docs/specs/2026-04-17-worker-auditor-subagent.md`. |
| `./hydra connect <x>` | Run the connector wizard `scripts/hydra-connect.sh` for linear / slack / supervisor / digest. See `docs/specs/2026-04-17-connector-wizard.md`, `docs/specs/2026-04-17-daily-digest.md`. |
| `./hydra setup` | First-time setup wizard: env check, repo picker, autopickup interval; fingerprint at `state/setup-complete.json`. See `docs/specs/2026-04-17-setup-wizard.md`. |

## Non-goals

- No behavior change to any command or script — this is the documentation home
  for semantics that already existed inline in CLAUDE.md.
- The trigger-phrase list is authoritative in CLAUDE.md (the router); this spec
  must stay in sync but CLAUDE.md is the source of truth for *which* commands
  exist.

## Test plan

- Every trigger present in the CLAUDE.md `Commands you understand` table appears
  as a row here (verified by the validation contract's row-6 trigger sweep, which
  runs against CLAUDE.md).
- `scripts/check-claude-md-size.sh` exits OK (no NOTICE/WARN) after the CLAUDE.md
  table is reduced to terse one-liners pointing here.
