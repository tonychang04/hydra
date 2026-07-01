---
status: draft
date: 2026-07-01
author: hydra worker (ticket #322)
---

# Commander owns review-gate label actuation (workers emit a verdict marker)

## Problem

The `pr-shepherd` state machine keys on review-gate **labels** to decide a PR's
next action (`scripts/pr-shepherd.sh:24-27,393-397`): no `commander-reviewed`
label → `needs-review-gate` → **re-spawn `worker-review`**; `commander-reviewed`
+ not-draft → `merge-ready`. The labels ARE the gate's memory.

But `worker-review` and `worker-validator` were instructed to apply those labels
themselves via `gh pr review` + `gh api .../labels`. Observed 4+ times in one
session (#307, #309, #314, #319, #321): the Claude Code auto-mode classifier
**BLOCKS the worker's PR write** — it reads "post a verdict to the PR" as an
unauthorized external publish and denies both the `gh pr review` comment and the
label POST. Every review/validator worker ended with "I could not apply the
label — please do it yourself."

Consequence: the labels never land from the worker. The loop only worked because
Commander merged on the verdict TEXT, bypassing labels. An autonomous autopickup
tick relying on the shepherd's label state would instead see "no
`commander-reviewed` label" and **re-spawn review endlessly** (wasted workers) or
mis-classify. Live proof of the drift: merged/closed issue #320 is still stuck at
label `commander-review` — it never advanced because the worker writes were
blocked.

Verified: **Commander's own context CAN apply labels via REST**
(`gh api --method POST .../labels` succeeds from Commander) where the worker
cannot. So the actuation belongs to Commander, post-worker-return.

## Goals / non-goals

**Goals:**
- A single, idempotent actuator (`scripts/apply-review-verdict.sh`) that maps a
  review-gate verdict to the correct label add(s) + superseded-label removal(s)
  via the REST API, mirroring the `apply-label-via-rest` skill.
- Workers stop attempting the classifier-blocked PR write and instead emit a
  machine-readable `*_VERDICT:` marker at the end of their report.
- Commander runs the actuator on the worker's marker after the worker returns —
  robust whether or not the worker was blocked (idempotent re-apply).
- The shepherd, given a `commander-reviewed` label applied by the actuator,
  reports `merge-ready` (not `needs-review-gate`) — no re-spawn loop.

**Non-goals:**
- Changing WHAT `worker-review` / `worker-validator` actually check. Only WHO
  applies the label and HOW the verdict is signaled changes.
- Auto-merging. The actuator only moves labels; the merge gate is unchanged.
- Making the worker's `gh pr review` comment land. The full structured review
  text is still returned to Commander in the worker report; posting it to the PR
  is out of scope (and is the thing the classifier blocks).

## Proposed approach

**`scripts/apply-review-verdict.sh <owner/repo> <pr> <verdict> [--dry-run]`** —
`verdict ∈ {reviewed, review-clean, validated, needs-fix, stuck, rejected}`. For
each verdict it knows an ADD set and a REMOVE (superseded) set of labels. It
lazily creates any label it is about to ADD (`gh label create … || true`, per the
`apply-label-via-rest` create-then-add idiom) then POSTs it; it DELETEs each
superseded label guarded with `|| true` (a 404 for an absent label is a safe
no-op). Re-running the same verdict is a no-op (POST of a present label returns
200; DELETE of an absent label 404s harmlessly). `--dry-run` prints the planned
transitions and mutates nothing (never invokes `gh`). Exit map mirrors
`merge-policy-lookup.sh`: `0` applied / `2` usage / `1` REST failure.

### Verdict → label mapping

| Verdict | ADD | REMOVE (superseded) |
|---|---|---|
| `reviewed` | `commander-reviewed` | `commander-review`, `commander-needs-fix` |
| `review-clean` | `commander-reviewed`, `commander-review-clean` | `commander-review`, `commander-needs-fix` |
| `validated` | `commander-validated` | — |
| `needs-fix` | `commander-needs-fix` | `commander-reviewed`, `commander-review-clean`, `commander-validated` |
| `stuck` | `commander-stuck` | — |
| `rejected` | `commander-rejected` | `commander-review`, `commander-reviewed`, `commander-review-clean` |

Design note (resolved ambiguity): a clean review must satisfy BOTH the shepherd
gate (which keys only on `commander-reviewed`) AND the `auto_if_review_clean`
merge policy (which keys on `commander-review-clean`). So `review-clean` adds
both — it is a strict superset of `reviewed`. Mapping the worker's `clean` marker
to `reviewed`-only would leave the shepherd loop half-fixed for the auto-merge
path; mapping it to `review-clean` fixes both. Only `commander-needs-fix` is a
new label (created lazily on first use); the rest already exist in the repo's
vocabulary (`commander-review`, `commander-reviewed`, `commander-review-clean`,
`commander-validated`, `commander-stuck`, `commander-rejected`).

### Worker marker → Commander verdict

Workers END their report with a machine-readable line instead of the blocked
write:

- `worker-review`  → `REVIEW_VERDICT: clean|needs-fix|blocked`
- `worker-validator` → `VALIDATION_VERDICT: pass|fail`

A SECURITY blocker → `REVIEW_VERDICT: blocked` (preserves the prior
security-blocker → `commander-stuck` semantics). Commander translates the marker
to a script verdict after the worker returns:

| Marker | Script verdict |
|---|---|
| `REVIEW_VERDICT: clean` | `review-clean` |
| `REVIEW_VERDICT: needs-fix` | `needs-fix` |
| `REVIEW_VERDICT: blocked` | `stuck` |
| `VALIDATION_VERDICT: pass` | `validated` |
| `VALIDATION_VERDICT: fail` | `stuck` |

### Alternatives considered

- **Alternative A — grant the worker the PR-write permission.** Would require
  loosening the auto-mode classifier / permission profile for every worker, a
  security regression, and it fights the classifier repeatedly rather than
  routing around it. Rejected.
- **Alternative B — Commander merges on verdict TEXT only, never labels (status
  quo).** Works for a human-driven session but breaks the autonomous shepherd,
  which is label-driven — the exact #320 drift. Rejected.
- **Alternative C — one label per verdict, no superseded-removal.** Simpler, but
  leaves stale interim labels (`commander-review`) on the PR, which is the #320
  bug. Rejected in favor of explicit supersede sets.

## Test plan

- `scripts/test-apply-review-verdict.sh` (hermetic — `gh` stubbed on PATH,
  capturing every REST call to a log file):
  - verdict → label mapping for each of the six verdicts (correct ADD + REMOVE).
  - idempotency: re-applying the same verdict issues the same calls, no error.
  - supersede logic: `reviewed` DELETEs `commander-review`; `needs-fix` DELETEs
    `commander-reviewed`.
  - `--dry-run` invokes `gh` zero times (log empty) and prints the plan.
  - usage error (missing args / bad verdict) → exit 2.
- Golden case `apply-review-verdict-mapping` in `self-test/golden-cases.example.json`.
- `scripts/validate-state-all.sh` → exit 0 (no state schema regressions).
- `bash .github/workflows/scripts/syntax-check.sh` → `syntax-check: OK` (this
  spec has valid frontmatter).

## Risks / rollback

- **Risk:** the mapping couples `review-clean` to two labels; a future merge
  policy that treats `commander-reviewed` and `commander-review-clean` as
  mutually exclusive would break. Mitigation: documented as a strict superset;
  the shepherd + `auto_if_review_clean` both only test for presence, not absence.
- **Risk:** lazy `gh label create` needs `gh` auth. In dry-run and in tests it is
  never called; in Commander's context `gh` is authenticated (same context that
  already POSTs labels).
- **Rollback:** revert the PR. The workers' prior label-write instructions were
  already non-functional (classifier-blocked), so reverting only removes the
  actuator + marker convention; it does not regress a working path.
