---
name: apply-label-via-rest
description: |
  Apply, remove, or create GitHub labels on PRs and issues via the REST API
  (`gh api --method POST /repos/<owner>/<repo>/issues/<n>/labels`). Use for
  every Hydra label transition (`commander-review`, `commander-review-clean`,
  `commander-rescued`, `commander-stuck`, `commander-superseded`, etc.).
  NEVER use `gh pr edit --add-label` — it hits the GraphQL Projects (classic)
  path and fails on most repos with a deprecation error. Covers add, remove,
  create-then-add, idempotency, and the exact error signature. (Hydra)
---

# Apply labels via the REST API (never `gh pr edit --add-label`)

## Overview

`gh pr edit --add-label <name>` dispatches through GraphQL, whose response
path touches Projects (classic) — a deprecated feature. It fails with:

```
GraphQL: Projects (classic) is being deprecated in favor of the new Projects
experience, see: https://github.blog/changelog/2024-05-23-sunset-notice-projects-classic/.
(repository.pullRequest.projectCards)
```

The REST endpoint `/repos/<owner>/<repo>/issues/<n>/labels` is unaffected and
works identically for PRs — PRs are issues in GitHub's data model (same number
space, same endpoint). This skill pins the exact invocations so workers stop
re-discovering the footgun mid-ticket.

## When to Use

- Any Hydra label transition on a PR: `commander-ready`, `commander-working`,
  `commander-review`, `commander-review-clean`, `commander-reviewed`,
  `commander-stuck`, `commander-rescued`, `commander-rejected`,
  `commander-skill-promotion`, `commander-superseded`, `commander-undo`,
  `commander-auto-filed`, `commander-retro`.
- Plain issues too — keeps one mental model and matches every agent spec.
- Creating a new label the repo doesn't have yet (see "Create-then-add").

Skip when reading labels — `gh pr view --json labels` is fine; the
deprecation only bites on writes.

## Process / How-To

**Add** (idempotent — re-adding returns 200 with the current label set):

```bash
gh api --method POST /repos/<owner>/<repo>/issues/<n>/labels \
  -f "labels[]=<label-name>"
```

`<n>` is the PR *or* issue number. Repeat `-f "labels[]=..."` for multiple
labels in one call. The `labels[]=` bracket syntax is required.

**Remove** (404 if not attached — tolerate with `|| true` when sweeping):

```bash
gh api --method DELETE \
  /repos/<owner>/<repo>/issues/<n>/labels/<label-name>
```

URL-encode spaces in the name as `%20`. Most Hydra labels are kebab-case
ASCII, so this rarely bites.

**Create-then-add** (add returns `422 "Label does not exist"` if missing):

```bash
gh label create <name> --repo <owner>/<repo> --color <6-hex> \
  --description "<desc>" || true
gh api --method POST /repos/<owner>/<repo>/issues/<n>/labels \
  -f "labels[]=<name>"
```

`gh label create` errors `already exists` on re-run — `|| true` it.

## Examples

### Good — worker-review applies `commander-review-clean`

```bash
gh api --method POST /repos/tonychang04/hydra/issues/501/labels \
  -f "labels[]=commander-review-clean"
```

Exits 0, returns the JSON label array. Matches the canonical line in
`.claude/agents/worker-review.md` and `scripts/promote-citations.sh`.

### Good — create a new label, then attach

```bash
gh label create commander-canary --repo tonychang04/hydra \
  --color 5319E7 --description "Canary label for a pilot workflow" || true
gh api --method POST /repos/tonychang04/hydra/issues/501/labels \
  -f "labels[]=commander-canary"
```

### Good — remove `commander-working` after opening the PR

```bash
gh api --method DELETE \
  /repos/tonychang04/hydra/issues/501/labels/commander-working
```

### Bad — the footgun this skill prevents

```bash
gh pr edit 501 --add-label commander-review-clean
# GraphQL: Projects (classic) is being deprecated in favor of the new Projects
# experience, ... (repository.pullRequest.projectCards)
```

Worker hits the deprecation error, retries, fails again, escalates as
`commander-stuck` — every step avoidable by the REST call above.

## Verification

Every label-write in this repo uses the REST form: grep
`gh api --method POST /repos/.*/labels` under `.claude/agents/`,
`scripts/promote-citations.sh`, `docs/phase2-vps-runbook.md`. A new worker
that uses `gh pr edit --add-label` hits the deprecation on first run.

## Related

- CLAUDE.md § "Applying labels" — authoritative one-liner this expands on.
- `.claude/agents/worker-review.md`, `.claude/agents/worker-conflict-resolver.md`,
  `scripts/promote-citations.sh` (`apply_label()`) — canonical callers.
- `memory/escalation-faq.md` — check here when a `gh` label call fails.
