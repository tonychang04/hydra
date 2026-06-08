---
status: draft
date: 2026-06-01
author: hydra worker
---

# Cloud side-effect tracking: cleanup checklist + `commander-live-state` label + `state/live-resources.json`

## Problem

Surfaced by the 2026-05-21 dogfood (ticket #189): a `worker-implementation` run
created a **real InsForge project + deployment + test users** while implementing
MCP Sentinel end-to-end. The Commander review gate (`worker-review`) only inspects
the **git diff** — it has zero visibility into **live cloud residue**: provisioned
projects, deployments, storage buckets, seeded rows, test users, EC2/compute, API
keys. A worker can therefore leave costly or risky live state that **no PR review
catches**, the PR merges clean, and the residue persists indefinitely (cost,
security surface, quota exhaustion) with nobody tracking it.

This is a P1 safety/observability gap: Hydra's review mechanism is diff-bound, but
the side-effects of agent work are not all in the diff. Nothing today records
"this ticket spun up live infra" so Commander cannot audit or tear it down.

## Goals / non-goals

**Goals:**

1. A **cloud-cleanup checklist** that `worker-implementation` follows when a ticket
   provisions live cloud resources: record what was created, clean up ephemeral
   test data before opening the PR, and declare what intentionally persists.
2. A `commander-live-state` label Commander applies to tickets/PRs that provision
   live resources, so the review gate runs a **teardown/verification step** before
   the PR is surfaced for merge, and so persisted residue is greppable later.
3. A machine-readable ledger — `state/live-resources.json` + a Draft-07 schema at
   `state/schemas/live-resources.schema.json` — so Commander can audit and tear
   down live state. The schema MUST make `scripts/validate-state-all.sh` pass (every
   `state/*.json` has a matching schema; this is preflight).

**Non-goals:**

- **Automated teardown.** This spec adds *tracking + a human/agent verification
  step*, not an auto-`terraform destroy`. Tearing down live infra is destructive and
  stays a deliberate, logged action — never an automatic one. (Matches the hard
  safety rail: Commander never runs destructive ops unprompted.)
- **A cloud inventory crawler.** We do not poll InsForge/AWS APIs to discover
  orphaned resources. The ledger is populated by the worker that created the
  resource (the only actor that reliably knows what it made), not by reconciliation
  against a provider.
- **Changing the diff-based review.** The evidence/security gates in `worker-review`
  are untouched; this adds one *additional* gate that only fires on
  `commander-live-state` PRs.
- **Secrets handling.** The ledger records resource *identifiers and handles*
  (project ref, bucket name, deployment URL), never tokens/keys — those stay out of
  state files per the hard safety rail.

## Proposed approach

Three additive pieces, each modeled on an existing Hydra pattern so this follows
the repo's conventions rather than inventing new ones.

### 1. Cloud-cleanup checklist — `worker-implementation.md`

Add a "Cloud side-effects (live-resource hygiene)" section to
`.claude/agents/worker-implementation.md`, structured exactly like the existing
"Docker isolation for parallel workers" section (both are worker rules for managing
*external side-effects* that don't show up cleanly in a diff). The section tells the
worker:

- **Detect**: if implementing/testing the ticket provisions any live cloud resource
  (InsForge project/deployment/bucket/function, seeded DB rows, test users, EC2 /
  compute, externally-billable API key), the ticket is *live-state-bearing*.
- **Record**: append an entry to `state/live-resources.json` (one entry per
  resource) capturing `kind`, `provider`, `identifier`, the `ticket`, `created_at`,
  a `disposition` (`ephemeral-cleaned` | `persists` | `pending-teardown`), and a
  short `notes`. **Never** record secrets — identifiers/handles only.
- **Clean up** ephemeral test data (test users, seeded rows, throwaway buckets)
  *before* opening the PR; mark those entries `ephemeral-cleaned`.
- **Declare persistence**: anything that intentionally persists (e.g. a demo
  deployment the ticket is about) is marked `persists` with a one-line justification.
- **Signal Commander**: emit a `LIVE_RESOURCES: <n> recorded (<k> persist)` marker
  in the final report so Commander knows to apply the `commander-live-state` label.
  This mirrors the existing `MEMORY_CITED:` / `QUESTION:` marker convention workers
  already use to signal Commander.

### 2. `commander-live-state` label — Commander + review gate

- **Routing (CLAUDE.md):** one line under the existing "Applying labels" section
  pointing at this spec. CLAUDE.md is near its size ceiling, so the *procedure* lives
  here in the spec; CLAUDE.md only holds the pointer (per the CLAUDE.md scope rule).
- **Application:** Commander applies `commander-live-state` to the ticket and PR when
  a worker emits a `LIVE_RESOURCES:` marker (or the ledger gained entries for that
  ticket). Label application uses the **REST API**
  (`gh api --method POST /repos/<owner>/<repo>/issues/<n>/labels -f "labels[]=commander-live-state"`),
  not `gh pr edit --add-label` (GraphQL Projects-classic deprecation), consistent
  with the existing label rule.
- **Review gate teardown-verification step (`worker-review.md`):** when reviewing a
  PR carrying `commander-live-state`, the reviewer adds a **Live-resource teardown**
  row to its review comment: read this ticket's `state/live-resources.json` entries,
  verify every `ephemeral-cleaned` entry is justified and every `persists` entry has
  a stated reason, and **block** (request-changes) if a resource is `pending-teardown`
  with no plan or if the ledger is empty despite the label. This is the verification
  that the diff-only gate cannot do.

### 3. `state/live-resources.json` + schema

- `state/schemas/live-resources.schema.json` — Draft-07, top-level required key
  `resources` (array of resource entries), matching the shape the other schemas use
  (e.g. `memory-citations.schema.json` keys an object; we use an array because the
  ledger is an append-only list). Each entry requires
  `kind, provider, identifier, ticket, created_at, disposition`; `disposition` is an
  enum (`ephemeral-cleaned` | `persists` | `pending-teardown`); `notes` optional.
  `additionalProperties: true` at the top level for forward-compat, matching the
  house style.
- `state/live-resources.json.example` — a tracked, populated example (two entries:
  one `ephemeral-cleaned`, one `persists`) so contributors see the shape and the
  bulk validator has a fixture to point at. The **live** `state/live-resources.json`
  is runtime state, added to `.gitignore` like the other live state files
  (`active.json`, `budget-used.json`, …).
- Because `validate-state-all.sh` validates `state/<name>.json` (skipping it if
  absent) and the live file is gitignored, the test plan validates the **example**
  explicitly via `scripts/validate-state.sh` to prove the schema accepts a real
  document; the bulk run proves the schema is well-formed and skips the (absent)
  live file gracefully — exactly how `linear` / `autopickup` already behave.

### Alternatives considered

- **Alternative A — put the checklist in CLAUDE.md.** Rejected: CLAUDE.md is at ~89%
  of its size ceiling and the scope rule forbids inlining procedures; the worker
  checklist belongs in the worker agent file (where the Docker-isolation analog
  already lives), and the Commander-side routing is a one-liner + spec pointer.
- **Alternative B — auto-teardown on merge.** Rejected (a non-goal): destroying live
  infra automatically is exactly the class of destructive action Hydra's hard rails
  forbid doing unprompted. Track + verify now; teardown stays a deliberate action.
- **Alternative C — object-keyed ledger (like memory-citations).** Considered;
  rejected in favor of an array because the ledger is an append-only event log with
  no natural unique key (the same `identifier` could legitimately recur across
  tickets), and an array reads more naturally for "what did we provision".

## Test plan

One concrete check per goal:

1. **Schema is valid + accepts a real document (Goal 3):**
   `scripts/validate-state.sh --schema state/schemas/live-resources.schema.json state/live-resources.json.example`
   exits 0. A deliberately-broken doc (missing `disposition`, or a bad enum value)
   fails under the ajv path — spot-checked during implementation.
2. **Bulk preflight still green (Goal 3 / preflight invariant):**
   `scripts/validate-state-all.sh` exits 0 (the new schema is well-formed; the absent
   live `state/live-resources.json` is skipped gracefully, same as other gitignored
   state files). Output pasted into the PR.
3. **Worker checklist is present + actionable (Goal 1):** grep
   `.claude/agents/worker-implementation.md` for the new "Cloud side-effects" section;
   it names the `state/live-resources.json` ledger, the `disposition` values, the
   pre-PR cleanup step, and the `LIVE_RESOURCES:` marker.
4. **Label routing + review gate wired (Goal 2):** CLAUDE.md contains the
   `commander-live-state` pointer line under "Applying labels"; `worker-review.md`
   contains the Live-resource teardown-verification step gated on the label; both
   reference this spec.

This is a docs/state/config change (no executable Hydra code path), so the relevant
verification is schema validation + preflight + presence/grep of the instruction
text, not a `self-test/` golden case. If a future PR makes Commander *act* on the
ledger programmatically, that PR should add a golden case.

## Risks / rollback

- **Risk: workers under-report.** A worker might provision a resource and forget to
  record it. Mitigation: the checklist makes recording a pre-PR step and the
  `LIVE_RESOURCES:` marker is part of the final report; the review gate blocks a
  `commander-live-state` PR with an empty ledger. Residual risk is a worker that
  neither records nor gets labeled — this spec narrows but cannot fully close that
  (a cloud crawler would, and is a deliberate non-goal for now).
- **Risk: ledger drift / stale entries.** The ledger is append-only and never
  auto-pruned; `persists` entries accumulate. Acceptable for v1 — it is an audit log,
  and Commander can compact it during memory hygiene if it grows. Not load-bearing
  for correctness.
- **Risk: schema too strict breaks preflight.** Mitigated by `additionalProperties:
  true` at top level and by validating the example before committing.
- **Rollback:** pure additive change (new spec, new schema, new example, gitignore
  line, doc sections, one CLAUDE.md line). Revert the PR's commits; no migration, no
  runtime state depends on it yet. Removing the `commander-live-state` label is a
  no-op REST delete.

## Implementation notes

(Fill in after the PR lands.)
