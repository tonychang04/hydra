---
status: draft
date: 2026-05-23
author: hydra worker (ticket #221)
---

# PR Shepherd v1.1 — fix cross-repo orphan false-negative + ticket-join PR#≠issue# mismatch

## Problem

Two correctness bugs in `scripts/pr-shepherd.sh` (PR Shepherd v1, spec
`docs/specs/2026-05-23-pr-shepherd.md`), both surfaced by Codex during the #218
review and filed as ticket #221. The shepherd's whole purpose is to catch an
ORPHANED PR (an open PR with no matching worker in `state/active.json`) so it
gets re-attached to the Commander loop. A false-negative — silently treating an
orphan as tracked — defeats that purpose (pillar P1, observability).

### Bug 1 — cross-repo orphan false-negative

`state/active.json` is global across all repos. The orphan-matching `worker_filter`
admits a worker as a match for THIS repo's PR via three conditions:

```jq
map(select(
  ($repo == "")                                       # (1a) global admission
  or (.repo == $repo)                                 # (1) exact slug — correct
  or ((.repo // "" | split("/") | last) == $repo_name)# (1b) loose basename match
))
```

Two of these are wrong:

- **(1a) global admission.** When `--repo` is not passed (`$repo == ""`), ALL
  workers across ALL repos are kept. A worker on `otherowner/hydra` tracking
  branch `hydra/commander/106` then "claims" `tonychang04/hydra` PR #106 → the
  orphan is silently missed.
- **(1b) loose basename match.** Even with `--repo tonychang04/hydra` set, a
  worker whose `repo` is `otherowner/hydra` matches because both basenames are
  `hydra`. Cross-owner same-named repos collide.

Reproduced empirically (both vectors mark a genuinely-orphaned PR as
`orphaned=false`).

### Bug 2 — fallback ticket-join compares PR number against worker ISSUE numbers

The pre-2026-04-17 branchless back-compat path in `is_orphan` joins on the wrong
number:

```bash
is_orphan() {
  local branch="$1" num="$2"          # $num is the PR NUMBER (.number)
  ...
  if [[ -n "$num" ]] && printf '%s\n' "$worker_tickets" | grep -Fxq -- "$num"; then
    echo "false"; return              # compares PR# against ISSUE#s
  fi
```

`$worker_tickets` are extracted from worker `.ticket` fields = **issue numbers**.
`$num` is the **PR number**. For real Hydra PRs, PR# ≠ issue#, so:

- **False-negative:** a real orphaned PR whose number doesn't coincide with any
  tracked issue is correctly flagged — but a genuinely-tracked branchless worker
  whose issue lives in the PR's branch is **missed** (the join never fires on the
  right key).
- **False-positive:** when a PR number happens to equal an unrelated tracked
  issue number, the PR is falsely "claimed".

The v1 self-test fixture masks this by using PR# == issue# (101==101).

The spec's documented contract (v1 spec, "Inputs") is: *"the issue number the PR
closes equals the worker's ticket number … The PR's headRefName for Hydra PRs
ends in `/<ticket>`."* The fix is to derive the issue number from the PR's
**branch** (`headRefName` trailing `/<N>`), not from the PR number.

Only the branchless back-compat path is affected; the primary branch-equality
join is correct and unchanged.

## Goals / non-goals

**Goals:**

- Tighten orphan matching to strict one-repo-per-invocation: drop the `$repo == ""`
  global admission and the loose basename match. A worker is admitted as a match
  only when its repo **actually corresponds** to the target repo (exact slug, or
  a `local_path` whose tail is the exact `owner/name` slug).
- Resolve the target repo to a concrete `owner/name` early (live: `gh repo view`;
  the offline self-test passes `--repo` explicitly). If the repo cannot be
  resolved while orphan matching is requested, emit a warning and match **no**
  workers (everything surfaces as an orphan — the safe, false-positive direction;
  never a silent false-negative).
- Fix the fallback ticket-join to extract the issue number from the PR's branch
  (`headRefName` trailing `/<N>`) and join that against worker ticket numbers,
  instead of joining the PR number.
- Add/extend self-test cases that FAIL before the fix and PASS after, proving the
  false-negative is now caught.

**Non-goals:**

- No change to the classification contract (states/precedence), the `--json`
  envelope shape, the human report format, or the v1 thread/CI logic.
- No mutation (still read-only). No touching `scripts/rescue-worker.sh` (#219 is
  concurrent). No change to the live wire-in docs beyond what these fixes require.

## Proposed approach

### Bug 1 — strict repo scoping

1. After arg parsing, resolve `repo` to a concrete `owner/name`:
   - already set via `--repo` → use as-is;
   - else in live mode → `gh repo view --json nameWithOwner` (same call the
     thread path already uses);
   - else (mock with no `--repo`, or resolution fails) → leave empty.
2. Replace the `worker_filter` admission with strict correspondence:
   ```jq
   map(select(
     ($repo != "")
     and (
       (.repo == $repo)                                  # exact slug
       or ((.repo // "") | endswith("/" + $repo))        # local_path tail == owner/name
     )
   ))
   ```
   No `$repo == ""` branch (when repo is empty the select yields nothing → no
   worker matches → all PRs orphaned, the safe direction) and no basename match.
3. When `repo` is empty and an `active.json` exists, print a one-line warning so
   the operator knows matching was skipped (read-only, non-fatal).

### Bug 2 — branch-derived issue join

In `is_orphan`, derive the issue number from the branch instead of using `$num`:

```bash
is_orphan() {
  local branch="$1"
  # primary join: exact branch equality with a tracked worker branch
  if [[ -n "$branch" ]] && printf '%s\n' "$worker_branches" | grep -Fxq -- "$branch"; then
    echo "false"; return
  fi
  # fallback join (pre-2026-04-17 branchless workers): the issue number is the
  # trailing /<N> of the PR's branch, NOT the PR number. Compare that against
  # worker ticket numbers.
  local issue_from_branch=""
  [[ "$branch" =~ /([0-9]+)$ ]] && issue_from_branch="${BASH_REMATCH[1]}"
  if [[ -n "$issue_from_branch" ]] && printf '%s\n' "$worker_tickets" | grep -Fxq -- "$issue_from_branch"; then
    echo "false"; return
  fi
  echo "true"
}
```

The PR number is no longer used for orphan matching at all. The caller drops the
`$number` argument to `is_orphan`.

### Alternatives considered

- **Bug 1: keep basename match but also compare owner.** Rejected — active.json
  `repo` may be a bare `local_path` with no owner segment, so owner comparison
  isn't always possible. The `endswith("/owner/name")` tail rule is strict and
  works for both the slug form and a local checkout whose path ends in the slug;
  a bare-basename path is intentionally NOT matched (we can't prove which owner
  it belongs to, and a false-positive orphan is safer than a false-negative).
- **Bug 2: parse the issue from the PR body / `closingIssuesReferences`.**
  Rejected for v1.1 — would add a per-PR GraphQL call; the branch tail is already
  the documented Hydra convention (`hydra/commander/<ticket>`) and needs no extra
  call. Can be added later as a refinement.

## Test plan

Extend `self-test/fixtures/pr-shepherd/run-smoke.sh` (offline `--gh-mock` seam,
no network) with cases that FAIL before the fix and PASS after:

1. **Cross-repo, `--repo` set, owner differs (Bug 1b).** A worker on
   `otherowner/hydra` tracking branch `hydra/commander/103`; with
   `--repo tonychang04/hydra`, PR #103 must be `orphaned=true`.
2. **Cross-repo, basename collision is rejected (Bug 1b).** Same as above but
   asserted as a dedicated case.
3. **Local_path tail still matches (no regression).** A worker whose `repo` is
   `/Users/x/repos/tonychang04/hydra` (tail == slug) still matches its PR.
4. **Fallback join false-positive rejected (Bug 2).** A branchless worker
   tracking issue #999; a PR #999 whose branch is `hydra/commander/42` must be
   `orphaned=true` (the PR is NOT issue 999).
5. **Fallback join true-positive (Bug 2).** A branchless worker tracking issue
   #42; a PR #777 whose branch is `hydra/commander/42` must be `orphaned=false`
   (matched by branch→issue).

The default fixture invocation gains an explicit `--repo tonychang04/hydra` so
strict matching has a concrete repo (the workers are already on that slug). The
empty-state and existing matrix assertions are preserved.

Run locally: `bash self-test/fixtures/pr-shepherd/run-smoke.sh` (prints
`SMOKE_OK`).

## Risks / rollback

- **Risk: orphan false-positives** for legitimately-tracked workers whose
  `active.json` `repo` is a bare basename path. Mitigation/accepted: a
  false-positive (re-attaching / surfacing a PR that's actually tracked) is a
  cheap no-op-ish redundancy; the bug being fixed is the dangerous direction
  (silently missing an orphan). The shepherd is read-only.
- **Risk: requiring a resolvable repo** changes behavior when `--repo` is omitted
  and `gh repo view` fails. Mitigation: warn + match no workers (safe direction),
  never crash.
- **Rollback:** read-only, additive to one script + its fixture + this spec.
  Revert the commits.
