---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 154
tier: T2
---

# Enable GitHub merge queue + switch Commander to `--merge-queue`

**Ticket:** [#154 — Enable GitHub merge queue + switch Commander merge procedure](https://github.com/tonychang04/hydra/issues/154)

## Problem

Commander's current `merge #N` path uses `gh pr merge <N> --squash`, which merges one PR at a time with no coordination between concurrent landings. Observed 2026-04-17 during a 4-PR parallel drop: after #149 merged, the other three PRs (#147, #148, #151) all went `CONFLICTING` because each had added an independent one-line pointer to `CLAUDE.md`. Commander had to spawn `worker-conflict-resolver` twice. This is O(n²) rebasing for additive changes that should serialize trivially.

GitHub's native merge queue is designed for exactly this: each PR lands on top of the previous merged state, GitHub rebases + runs required checks + merges in order, fully hands-off. `gh pr merge --merge-queue` has been the CLI surface since gh 2.39.

`tonychang04/hydra` currently has neither branch protection nor required status checks on `main` (verified: `gh api /repos/tonychang04/hydra/branches/main/protection` returns 404). Both need to land in this ticket — merge queue requires branch protection + required checks.

## Goals

1. Branch protection on `main` with required status checks (the existing CI workflows) and merge queue enabled.
2. Merge queue settings: squash-merge only, required reviews `0` (Commander reviews via label, not GitHub-review), min-group-size `1`, max-group-size `5` (matches `budget.json:phase1_subscription_caps.max_concurrent_workers`), wait-timeout 10 min.
3. Per-repo opt-in via `state/repos.json:repos[].merge_queue_enabled` (default `false`). Commander uses `--merge-queue` only when set to `true` on that repo. Other repos (InsForge/*) keep legacy behavior until explicitly opted in.
4. Commander's `merge #N` path switches to `gh pr merge <N> --merge-queue --squash` for queue-enabled repos, with a fallback to the current ready-then-squash flow (`gh pr merge <N> --squash --auto`) if `--merge-queue` fails.
5. `scripts/merge-policy-lookup.sh` grows an optional `--queue` mode: returns `queue:<policy>` when the repo has `merge_queue_enabled: true` AND the effective policy is `auto` / `auto_if_review_clean`; otherwise returns the plain policy string. Commander reads this to decide which `gh pr merge` flag to use.
6. A reproducible rollout: exact `gh api` calls documented here so the operator (and future Hydra-managed repos) can apply the same configuration atomically after the PR merges.
7. Regression test covering the new `--queue` mode of `merge-policy-lookup.sh` and the `merge_queue_enabled` schema addition.

## Non-goals

- **Enabling merge queue on InsForge/* repos.** Separate per-repo ticket after this lands. The default for `merge_queue_enabled` is `false` so unrelated repos keep working.
- **Changing required-review-count.** Commander's label-based review (`commander-review-clean`) is the intentional gate; GitHub review count stays 0. Merge queue doesn't need a reviewer.
- **CODEOWNERS.** Out of scope. Commander reviews via the worker-review subagent, not via owners files.
- **Rewriting `hydra-mcp-server.py:_handler_merge_pr`.** That handler is still a Phase-1 stub; when the real merge dispatch lands (follow-up ticket), it will consume `merge-policy-lookup.sh --queue`. Contract documented here; implementation deferred.
- **Executing the `gh api` enable call from within the PR.** Enabling merge queue is a policy rollout, not an implementation step. The PR SPECS the rollout; the operator EXECUTES the enable call after merging this PR (via `scripts/enable-merge-queue.sh`).

## Proposed approach

### Schema (`state/schemas/repos.schema.json`)

Add an optional boolean field:

```jsonc
{
  "merge_queue_enabled": {
    "type": "boolean",
    "description": "Optional per-repo opt-in. When true, `merge #N` prefers `gh pr merge --merge-queue --squash`. Default false (legacy ready-then-squash flow). Requires the repo's main branch to have branch protection + required status checks + a merge queue configured via `scripts/enable-merge-queue.sh`. See `docs/specs/2026-04-17-merge-queue.md`."
  }
}
```

Additive and optional — existing `repos.json` entries validate unchanged.

### Lookup CLI (`scripts/merge-policy-lookup.sh --queue`)

New optional flag. When passed, the lookup:

1. Runs the usual resolution (T3 → `never`; repo entry → object/legacy/default fall-through).
2. If the resolved policy is `auto` or `auto_if_review_clean` AND the repo entry has `merge_queue_enabled: true`, prints `queue:<policy>` on stdout (e.g. `queue:auto`, `queue:auto_if_review_clean`).
3. Otherwise prints the plain policy (`auto` / `auto_if_review_clean` / `human` / `never`).

Exit codes unchanged from existing contract. No `--queue` flag = current behavior (backward compatible).

Rationale: a single deterministic CLI output is enough for Commander to branch between `--merge-queue --squash` and the legacy `--squash --auto` flow, without growing a second script. The `queue:` prefix is obvious under `grep` and won't collide with any legal policy value (none contain colons).

### Commander procedure change (`CLAUDE.md`)

One-line pointer update on the `merge #N` row: the table entry gains "queue-mode when `scripts/merge-policy-lookup.sh --queue` returns `queue:*`" and a ref to this spec. All detail (fallback, error handling, the `--merge-queue` semantics) lives here.

Effective Commander flow for `merge #N`:

```
policy = merge-policy-lookup.sh <owner>/<name> <tier> --queue
case policy in
  queue:auto)                        gh pr merge <N> --merge-queue --squash ;;
  queue:auto_if_review_clean)        # same, gated by commander-review-clean label present
                                     gh pr merge <N> --merge-queue --squash ;;
  auto)                              gh pr merge <N> --squash --auto ;;
  auto_if_review_clean)              # label check, then:
                                     gh pr merge <N> --squash --auto ;;
  human)                             # surface to operator, do not merge
                                     ;;
  never)                             refuse with reason ;;
esac
```

Fallback: if `gh pr merge --merge-queue` exits non-zero (queue not configured, required checks not passing yet, PR not in a queueable state), log `MERGE_QUEUE_FALLBACK: <reason>` to the ticket log and retry with `gh pr merge <N> --squash --auto`. The fallback prevents "merge queue half-rolled-out on one repo" from blocking all Commander merges on that repo. This matches AC #5.

### Rollout helper (`scripts/enable-merge-queue.sh`)

One-shot convenience wrapper around `gh api` that applies branch protection + required checks + merge queue config to a repo. Safety guarantees:

- `--dry-run` is the default. Actually applying requires `--apply`.
- Refuses to run without confirming `gh api /repos/<slug>` returns 200 AND `gh api /user --jq .login` returns a user with admin on the repo.
- Prints the exact `PUT` bodies it will send before touching anything.
- Never force-overwrites existing branch protection; if protection already exists, exit 2 and ask the operator to review and merge manually.

Usage:

```
scripts/enable-merge-queue.sh <owner>/<name> [--apply] [--max-group-size N] [--wait-timeout M]
```

Defaults: `--max-group-size 5`, `--wait-timeout 10` (minutes).

Exit codes:

- `0` — dry-run completed OR `--apply` succeeded
- `1` — gh unavailable / auth failure / repo not found
- `2` — branch protection already exists (operator must reconcile manually)
- `3` — required status checks not discoverable (no CI workflows on default branch yet)

### Exact API calls (the payload)

Two PUTs in order. Both idempotent under normal conditions; `enable-merge-queue.sh` wraps both.

**1. Branch protection on `main`** (`PUT /repos/{owner}/{repo}/branches/main/protection`):

```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": []
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false,
  "required_linear_history": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
```

`contexts: []` means "no required status checks hard-coded in protection"; the merge queue's `required_status_checks` below is what actually gates entries. `required_pull_request_reviews: null` keeps GitHub review count at 0 (Commander's label is the review). `required_linear_history: true` forces squash/rebase-only — matches the squash-only merge queue setting.

Equivalent `gh api` invocation:

```bash
gh api --method PUT /repos/tonychang04/hydra/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": []},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false,
  "required_linear_history": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
```

Expected response: `200 OK` with the protection object echoed back.

**2. Merge queue configuration** (`PUT /repos/{owner}/{repo}/branches/main/protection` — merge queue fields live on the same endpoint in the REST API; via the web UI they appear under the "Require merge queue" toggle).

The REST surface for merge queue is currently evolving; as of this spec the reliable path is via the branch protection payload above **plus** setting merge queue via the "update branch protection" endpoint's `required_status_checks` with the contexts of the CI workflows:

```bash
# After step 1, list CI workflow run names to populate required-contexts.
gh api /repos/tonychang04/hydra/actions/workflows --jq '.workflows[] | select(.state=="active") | .name'
# For each active workflow context, PATCH required_status_checks to include it.
gh api --method PATCH /repos/tonychang04/hydra/branches/main/protection/required_status_checks \
  --input - <<'JSON'
{
  "strict": true,
  "contexts": ["<workflow-context-1>", "<workflow-context-2>"]
}
JSON
```

Then enable the merge queue via the repo-level graphql/REST surface (as of gh 2.39, the CLI supports `gh pr merge --merge-queue` once the queue is turned on in repo Settings → Branches → Branch protection rules → Merge queue). The REST endpoint for turning on the queue:

```bash
gh api --method POST /repos/tonychang04/hydra/rulesets \
  --input - <<'JSON'
{
  "name": "hydra-main-merge-queue",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {
      "type": "merge_queue",
      "parameters": {
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN",
        "max_entries_to_build": 5,
        "max_entries_to_merge": 5,
        "merge_method": "SQUASH",
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 10
      }
    }
  ]
}
JSON
```

Expected response: `201 Created` with the ruleset object. Rulesets are the modern GitHub surface for merge queue config and supersede the older "legacy branch protection" UI. This ensures the queue is created atomically with the desired group-size and wait-timeout settings.

Documentation: https://docs.github.com/en/rest/repos/rules — ruleset API reference.

### Commander fallback semantics

When `merge_queue_enabled: true` but `gh pr merge --merge-queue` fails, Commander MUST:

1. Log `MERGE_QUEUE_FALLBACK: <stderr excerpt>` to `logs/<ticket>.json` under a new `merge_queue_fallback` key.
2. Retry with `gh pr merge <N> --squash --auto`.
3. On the second failure, surface to the operator (do NOT retry a third time — that's the existing "workers stuck 2+ times" safety rail extended to merge actions).

This prevents partial rollouts (queue misconfigured, CI check renamed, etc.) from blocking Commander across an entire repo. The fallback is explicit and logged so the operator can spot the drift.

### Per-ticket log field

`logs/<ticket>.json` gains an optional `merge_method` field with values `merge-queue`, `ready-squash`, or `manual`. Populated by Commander after a successful merge so retro and citations can track which path actually ran. Schemaless addition (the active log schema already accepts extra keys).

## Test plan

1. **Schema validation:** `scripts/validate-state.sh state/repos.json` passes with the new optional field (absent in current repos.json — backward-compat). Add a unit test fixture at `self-test/fixtures/merge-policy/repos-queue-enabled.json` with `merge_queue_enabled: true` and validate.
2. **`--queue` mode regression:** `self-test/fixtures/merge-policy/run.sh` (new) exercises every combination:
   - `merge_queue_enabled: true` + T1 auto → `queue:auto`
   - `merge_queue_enabled: true` + T2 auto_if_review_clean → `queue:auto_if_review_clean`
   - `merge_queue_enabled: true` + T3 → `never` (hard safety rail still wins)
   - `merge_queue_enabled: false` + T1 auto → `auto` (legacy)
   - missing `merge_queue_enabled` + T1 auto → `auto` (default)
   - `merge_queue_enabled: true` + T1 human → `human` (queue only applies when policy is auto*)
3. **Default behavior unchanged:** existing `repo-merge-policy-override` self-test case (in `golden-cases.example.json`, untouched) still passes.
4. **`enable-merge-queue.sh --dry-run`** prints the exact `PUT` and `POST` bodies above without making network calls. Verified by grepping the dry-run output for the expected JSON fields.
5. **Manual verification after operator runs `--apply`:**
   - `gh api /repos/tonychang04/hydra/branches/main/protection` returns 200 with `required_linear_history: true`.
   - `gh api /repos/tonychang04/hydra/rulesets` lists the `hydra-main-merge-queue` ruleset.
   - `gh pr merge <test-pr> --merge-queue --squash` succeeds on a throwaway PR (operator smoke test).

## Risks / rollback

| Risk | Mitigation |
|---|---|
| Merge queue misconfiguration blocks all merges on hydra | `merge_queue_enabled` defaults `false`; rollout is explicit; fallback path returns Commander to legacy squash. |
| Rulesets API surface changes before this ships | `enable-merge-queue.sh --dry-run` is the default. Operator verifies payload before `--apply`. If the API has drifted, the dry-run output is the thing to update. |
| Required status checks don't match active workflows | `enable-merge-queue.sh` exits 3 if no workflows discovered; the operator is told to list workflow names and pass them explicitly. |
| `gh pr merge --merge-queue` unsupported in the operator's `gh` version | Fallback to `--squash --auto` kicks in automatically, logged as `MERGE_QUEUE_FALLBACK`. Operator sees the log note and upgrades `gh`. |
| Force-push to main blocked even for emergency Commander operations | Intentional. `git push --force` on main is already a Commander hard rail; merge queue formalizes it at the server. Emergency override requires the operator to manually disable the ruleset via Settings. |
| A queued PR is stuck waiting for a check that never arrives | `check_response_timeout_minutes: 60` in the ruleset. Past 60 min, GitHub drops the PR from the queue and Commander's normal PR-stuck watchdog surfaces it to the operator. |

**Rollback:** revert the `scripts/enable-merge-queue.sh` PR and run the inverse `gh api` calls:

```bash
gh api --method DELETE /repos/tonychang04/hydra/rulesets/<ruleset_id>
gh api --method DELETE /repos/tonychang04/hydra/branches/main/protection
```

Then flip `merge_queue_enabled: false` (or remove the key) on each affected repo entry in `state/repos.json`.

## Rollout plan

1. **Merge this PR.** No runtime behavior change — `merge_queue_enabled` is absent from every repo entry, so the `--queue` mode returns the legacy string and Commander uses the existing `--squash --auto` path.
2. **Operator runs `scripts/enable-merge-queue.sh tonychang04/hydra --dry-run`** to verify the payload matches the current GitHub API surface, then `--apply` to configure branch protection + merge queue on `tonychang04/hydra`.
3. **Operator edits `state/repos.json`** on the Commander host to flip `"merge_queue_enabled": true` on the hydra entry. `scripts/validate-state.sh state/repos.json` must still pass.
4. **Next `merge #N` on a hydra PR** uses `--merge-queue --squash`. First one is the operator's smoke test.
5. **For InsForge/* repos:** the operator repeats steps 2–3 per-repo once the queue is battle-tested on hydra. Separate follow-up tickets if anything repo-specific surfaces (e.g. CI workflow renames).

**What this PR explicitly does NOT change:** existing Commander behavior for repos without `merge_queue_enabled: true`. Default is safe.
