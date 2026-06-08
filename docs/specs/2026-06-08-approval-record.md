---
status: draft
date: 2026-06-08
author: hydra worker (ticket #268)
---

# Approval Record — durable who/when/why for every human-gated decision

## Problem

Human approval in Hydra is **ephemeral**. When the operator merges a surfaced
T2/T3 PR through GitHub, says "yes" in chat, or approves a safety-rail diff,
Hydra records **nothing** about WHO approved, WHEN, or WHY. There is no approval
audit trail. The operator asked it directly (2026-06-08): "is there a right
human approval or observability process?"

For a machine whose safety model is "surface risky things for human sign-off"
(T2/T3 merges, escalated `QUESTION:`s, safety-rail changes, rescue-surfaces),
the approval itself must be a **durable, auditable artifact** — not a transient
chat message. A human auditing Hydra cannot, from the committed/runtime state
alone, answer "was approval obtained for #N, by whom, why?".

This is the **P1 (observability/safety)** pillar, the weakest today
(`memory/project_north_star.md`). It pairs with the **Decision Record** (#267,
PR #269), which records WHY Commander made each decision. The Decision Record
already defines the seam: a nullable `approval_ref` field on each decision entry,
"defined here, populated by #268". This ticket populates that seam.

## Goals

1. An **Approval Record**: a durable, queryable `state/approvals.json` keyed by
   subject (ticket/PR ref), recording the **current** approval status of every
   human-gated subject — `awaiting` / `approved` / `rejected` — and, for each
   recorded action, the durable tuple `{decision, approver, ts, reason,
   decision_ref}`.
2. A **writer helper** `scripts/approve.sh` that records an approval action
   (`--approve` / `--reject` / `--await`) for a subject, with `--by <who>` and
   `--reason "..."`, writing a **schema-validated** entry. Append-only history is
   preserved per subject (a later action never erases an earlier one).
3. A **reader** `scripts/approvals.sh [<subject>] [--status <s>]` that answers
   "was approval obtained for #N, by whom, why?" from state alone.
4. **Linked**: the Decision Record's `approval_ref` seam links a surfaced
   decision to its approval entry; the approval action's `decision_ref` links
   back to the Decision Record entry (the two halves of one audit trail).
5. A JSON **schema** (`state/schemas/approvals.schema.json`) wired into
   `scripts/validate-state-all.sh`, plus a **RED→GREEN fixture** demonstrating the
   writer rejecting a malformed action (e.g. an approval with no approver).

## Non-goals

- **Auto-gating every surface point in code.** This ticket ships the durable
  record + writer + reader + schema + the `decision_ref` linkage. Wiring
  `autopickup-tick.sh`'s merge-surface block to *consult* approvals before
  classifying a PR merge-ready, and editing CLAUDE.md's merge/escalation
  operating procedure to *require* `approve.sh` before surfacing "ready for your
  merge", are **follow-ups** — and, for CLAUDE.md, owned by a different in-flight
  ticket (see Coordination). We define the data + tooling + linkage so those
  follow-ups are trivial. (Mirrors #267's "one producer wired, broad wiring is a
  follow-up" scoping.)
- **A PR-comment / Slack approval hook.** The ticket lists these as optional
  ("and/or"). The durable record + CLI writer is the v1 capture path; a
  PR-comment/Slack bridge that shells out to `approve.sh` is a clean follow-up
  once the record exists.
- **Changing the supervisor-escalation response shape.** The ticket's item 4
  (adding `confidence` / `human_involved` / `source` to
  `hydra-supervisor-escalate.py` + escalation-faq) is explicitly "Optional". The
  `source` provenance field already exists on citations
  (`state/schemas/memory-citations.schema.json`); extending the escalation
  client is out of scope here and tracked as a follow-up. We keep this ticket
  focused on the durable approval record, its highest-value deliverable.
- **A UI / approval dashboard.** `scripts/approvals.sh` + jq are the v1 read
  path, mirroring `scripts/decisions.sh`.
- **Rotation / retention.** `state/approvals.json` is runtime state under
  `state/` (gitignored like the other `state/*.json` runtime files); a committed
  `state/approvals.example.json` documents the shape.

## Survey (current state, cited)

- **Decision Record (#267, PR #269)** establishes the conventions this spec
  REUSES and the seam it fills:
  - `logs/decisions/<date>.jsonl` append-only entries via `scripts/record-decision.sh`
    (flags **or** `--json` stdin), validated-before-write (invalid → exit 1,
    nothing written), read by `scripts/decisions.sh`.
  - `state/schemas/decision-entry.schema.json` defines `approval_ref`:
    `{"type": ["string","null"], "description": "Seam for the Approval Record
    (#268) ... Defined here, populated by #268."}`. **This ticket is that
    population.**
  - Script conventions: `set -euo pipefail`, `--help`/usage, documented exit
    codes, flags-or-stdin, jq for JSON construction.
  - Test conventions: standalone `scripts/test-*.sh`, plain bash, `say/ok/bad`
    helpers, pass/fail counter, `mktemp` fixtures (model: `scripts/test-trace.sh`,
    `scripts/test-record-decision.sh`).
- **State file convention**: every runtime `state/<name>.json` is **gitignored**
  (`.gitignore` lines 7-19); a committed `state/<name>.example.json` documents
  the shape; `state/schemas/<name>.schema.json` is committed.
  `scripts/validate-state-all.sh` iterates `state/schemas/*.schema.json` and, for
  each `<base>.schema.json`, validates `state/<base>.json` **if present** (else
  `∅ skip`). So a runtime-gitignored `state/approvals.json` is validated when it
  exists and skipped on a fresh clone — identical to `active.json` /
  `memory-citations.json`. The **example** file is the committed artifact a
  reviewer reads; the test validates it against the schema.
- **`approval_ref` shape choice**: #267 stores `approval_ref` as an opaque
  string. We make `approve.sh` mint a stable key `approval:<subject-key>` (e.g.
  `approval:tonychang04/hydra#501`) that is also the `state/approvals.json` key,
  so a Decision Record entry's `approval_ref` round-trips: `decisions.sh #501`
  shows `approval_ref: approval:tonychang04/hydra#501`, and `approvals.sh #501`
  resolves it.
- **Surfaces** (`scripts/build-board.sh`): renders fixed-order `## <Section>`
  blocks via `render_section_from_rows`, `_none_` when empty. The board
  integration (an "Awaiting approval" section) is left to the CLAUDE.md/tick
  follow-up (it's owned by another ticket; see Coordination) so this PR touches
  only files it owns.

## Approval Record format

`state/approvals.json` — a single durable JSON object. Top-level `approvals` is
a map keyed by **subject key** (a normalized `<owner>/<repo>#<n>` or
`worker-<id>` ref). Each value holds the subject's **current** status plus an
**append-only `history`** of every action ever recorded for it, so the latest
decision is O(1) to query while no prior decision is ever lost.

```jsonc
{
  "approvals": {
    "tonychang04/hydra#501": {
      "subject": "tonychang04/hydra#501",
      "status": "approved",                 // awaiting | approved | rejected
      "current": {                          // the latest action (mirror of history[-1])
        "decision": "approved",             // approved | rejected | awaiting
        "approver": "tonychang04",          // who (required for approved/rejected)
        "ts": "2026-06-08T18:30:00Z",       // when (ISO-8601 UTC, second precision)
        "reason": "review clean, CI green, T2 within policy",   // why
        "decision_ref": "merge-surface:tonychang04/hydra#501"   // link to Decision Record (nullable)
      },
      "history": [
        { "decision": "awaiting",  "approver": null, "ts": "2026-06-08T18:00:00Z", "reason": "surfaced for human merge", "decision_ref": "merge-surface:tonychang04/hydra#501" },
        { "decision": "approved",  "approver": "tonychang04", "ts": "2026-06-08T18:30:00Z", "reason": "review clean, CI green, T2 within policy", "decision_ref": "merge-surface:tonychang04/hydra#501" }
      ]
    }
  }
}
```

### Action field contract (one `history[]` entry, also `current`)

| field | required | type | meaning |
|---|---|---|---|
| `decision` | yes | enum | `approved` / `rejected` / `awaiting`. The action taken. |
| `approver` | conditional | string\|null | WHO. **Required** (non-empty) for `approved`/`rejected`; `null` for `awaiting` (no human yet). |
| `ts` | yes | string | WHEN. ISO-8601 UTC, second precision (`2026-06-08T18:30:00Z`). |
| `reason` | yes | string | WHY. Non-empty rationale. |
| `decision_ref` | no | string\|null | Link to the Decision Record entry this approves (e.g. `merge-surface:<subject>`). Mirror of #267's `approval_ref`. |

### Per-subject object

| field | required | type | meaning |
|---|---|---|---|
| `subject` | yes | string | The normalized subject key (echoes the map key). |
| `status` | yes | enum | `awaiting` / `approved` / `rejected` — equals `current.decision`. |
| `current` | yes | object | The latest action (the action contract above). |
| `history` | yes | array | Append-only list of every action, oldest first (length ≥ 1). |

## Proposed approach

### Writer — `scripts/approve.sh` (active append, jq-built)

Mirrors `scripts/record-decision.sh`: an active helper invoked at the
approval moment by Commander (or a future PR-comment/Slack bridge). Pure
bash + jq, no daemon/backend. Records ONE action and degrades safely.

- **Usage:**
  `approve.sh <subject> --approve --by <who> --reason "..." [--decision-ref <r>]`
  `approve.sh <subject> --reject  --by <who> --reason "..." [--decision-ref <r>]`
  `approve.sh <subject> --await            --reason "..." [--decision-ref <r>]`
  - `<subject>`: `#501`, `tonychang04/hydra#501`, or `worker-abc`. Normalized to a
    subject key (`#501` → resolved against `--repo <owner>/<name>` or
    `$HYDRA_DEFAULT_REPO`; a bare `#N` with no repo context stays `#N`).
  - Exactly one of `--approve` / `--reject` / `--await` (maps to `decision`).
  - `--by <who>` required for `--approve`/`--reject`; rejected for `--await`.
  - `--reason "..."` required (non-empty) for all three.
  - `--decision-ref <r>` optional; default `null`. The helper does NOT invent
    one (the caller passes the Decision Record ref).
  - `--approvals-file <p>` (default `$HYDRA_APPROVALS_FILE` → `./state/approvals.json`),
    `--now <iso8601>` (test seam; default `date -u`).
- **Behavior:** read existing `state/approvals.json` (or start from
  `{"approvals":{}}` if absent), build the action object with jq, **validate** it
  (required fields per the contract; enum membership; approver presence rule;
  ts shape), then: append to that subject's `history`, set `current` = the
  action, set `status` = `decision`. Atomic write (temp file + `mv`), single
  writer. **Mints `approval:<subject-key>`** and prints it on stdout so the
  caller can pass it as the Decision Record's `approval_ref`.
- **Exit codes:** `0` recorded; `1` invalid action — well-formed invocation
  whose *content* fails write-time validation (e.g. a malformed `--now`
  timestamp), nothing written; `2` usage error — wrong invocation (missing
  required `--by`/`--reason`, two decision flags, `--await --by`, unknown arg),
  nothing written. Both `1` and `2` reject and write nothing; the split is
  "bad value" vs "bad invocation".

### Reader — `scripts/approvals.sh [<subject>] [--status <s>]`

- No arg: print every subject's current status (most-recently-acted first),
  human-readable: `<status> <subject> — by <approver> at <ts>: <reason>`.
- `<subject>`: filter to that subject (with `#N` normalization, so `#501`
  matches `tonychang04/hydra#501`); print its `current` plus its full `history`.
- `--status awaiting|approved|rejected`: filter to subjects in that state (e.g.
  `approvals.sh --status awaiting` = the human work queue).
- `--json`: machine output. Default: readable blocks.
- `set -euo pipefail`, `--help`, `--approvals-file`. Exit `0` (found or empty),
  `2` usage / missing explicit file.

### Linkage to the Decision Record (#267)

The two records form one audit trail and reference each other by stable string
keys (no shared runtime dependency — either can be read alone):

```
record-decision.sh --type merge-surface --subject #501 ... --approval-ref "$(approve.sh #501 --await --reason 'surfaced')"
approve.sh #501 --approve --by tony --reason 'clean' --decision-ref "merge-surface:tonychang04/hydra#501"
```

- A Decision Record entry's `approval_ref` = `approval:<subject-key>` →
  resolvable by `approvals.sh`.
- An approval action's `decision_ref` = the Decision Record subject/type ref →
  resolvable by `decisions.sh`.

Neither script imports the other; the link is data, so each degrades
independently (a missing approval just leaves `approval_ref: null`, exactly the
#267 default).

### Schema + validation

- `state/schemas/approvals.schema.json` — Draft-07 schema for the whole
  `state/approvals.json` object: `approvals` map → per-subject object (`subject`,
  `status` enum, `current` action, `history` array of actions). The **action**
  sub-schema requires `decision` (enum), `ts` (UTC pattern), `reason`
  (non-empty); `approver` is `string|null`; `decision_ref` is `string|null`. The
  approver-presence rule (required for approved/rejected, null for awaiting) is
  enforced at **write time** by `approve.sh` (the gate that matters), the same
  split #267 uses for its per-line entry rules.
- Wired into the existing bulk `scripts/validate-state-all.sh` automatically (it
  globs `state/schemas/*.schema.json`). A committed
  `state/approvals.example.json` is validated against the schema in the test.

## Data flow

```
Commander       --(approve.sh #501 --await  --reason 'surfaced')------> state/approvals.json  (status: awaiting)
operator says OK--(approve.sh #501 --approve --by tony --reason 'clean')-> state/approvals.json  (status: approved)
operator audit  --(approvals.sh #501)----------------------------------> "approved by tony at T: clean" + full history
human queue     --(approvals.sh --status awaiting)---------------------> every subject still needing sign-off
Decision Record --(approval_ref: approval:tonychang04/hydra#501)--------> approvals.sh resolves who/when/why
```

## Test plan

`scripts/test-approve.sh` (standalone bash, model = `scripts/test-record-decision.sh`):

- **Writer — happy paths**
  - `--await --reason` creates the subject with `status:awaiting`,
    `current.approver:null`, `history` length 1, `approval:<key>` printed.
  - `--approve --by --reason` on the same subject appends history (length 2),
    sets `status:approved`, `current.approver` = who.
  - `--reject --by --reason` sets `status:rejected`.
  - `--decision-ref` lands on the action; absent → `null`.
  - `--now` seam controls `ts`; ts is ISO-8601 UTC second precision.
  - `<subject>` normalization: `#501` and `tonychang04/hydra#501` resolve to the
    same key given `--repo`.
- **Writer — RED→GREEN gate (malformed → error, nothing written)**
  - `--approve` with no `--by` → exit 2 (usage: required input missing), file unchanged.
  - empty `--reason` → exit 2 (usage), file unchanged.
  - `--await` **with** `--by` → exit 2 (usage: await takes no approver).
  - two of `--approve/--reject/--await` → exit 2 (usage).
  - malformed `--now` timestamp → exit 1 (invalid action: content gate), file unchanged.
  - then a corrected `--approve --by --reason` → exit 0, history grows by one.
- **Schema**
  - `state/approvals.example.json` validates against
    `state/schemas/approvals.schema.json` via `scripts/validate-state.sh`
    (minimal path; strict path when ajv present).
  - a fixture with a `current` missing `reason` FAILS validation (RED) and the
    valid example PASSES (GREEN).
- **Reader**
  - `approvals.sh #501` prints status + history; `--status awaiting` filters;
    `--json` emits parseable JSON; empty file → exit 0, no crash.
- **Integration syntax**: `bash -n` clean on all new scripts (CI parity via
  `scripts/preflight-syntax.sh`).

## Risks / rollback

- **Risk: schema picked up by bulk validator breaks preflight on a malformed
  runtime file.** Mitigation: `state/approvals.json` is gitignored (no committed
  runtime file), so a fresh clone skips it (`∅ skip`); the committed
  **example** is what the test validates. Same posture as every other state file.
- **Risk: divergence from #267's `approval_ref` string contract.** Mitigation:
  `approve.sh` mints exactly `approval:<subject-key>` (a plain string), which is
  what #267's nullable-string field accepts; round-trip is asserted in the
  linkage section, not assumed.
- **Risk: scope creep into CLAUDE.md / tick wiring (owned elsewhere).**
  Mitigation: this PR touches ONLY the new approval script(s), its state
  file/schema/example, the spec, `.gitignore`, and the test. CLAUDE.md merge/
  escalation procedure changes and tick/board consultation are explicit
  follow-ups (see Coordination), noted in the PR body.
- **Rollback:** purely additive (new files + one `.gitignore` line). Reverting
  the PR removes the record + tooling with no effect on existing flows; the
  `approval_ref` field on #267 stays `null` exactly as it is today.

## Coordination

- **Owns:** `scripts/approve.sh`, `scripts/approvals.sh`,
  `scripts/test-approve.sh`, `state/approvals.example.json`,
  `state/schemas/approvals.schema.json`, this spec, the `.gitignore` line.
- **Does NOT touch (owned by other in-flight work):** `CLAUDE.md` (merge/
  escalation operating procedure that would *require* `approve.sh` before
  surfacing "ready for your merge" — a separate CLAUDE.md PR is in flight;
  routing noted in the PR body only), `scripts/autopickup-tick.sh` (PR #266),
  `scripts/build-board.sh` / `scripts/build-daily-digest.sh` (the #267 Decision
  Record PR #269 is editing those; the "Awaiting approval" board section is a
  follow-up to avoid a merge conflict), `worker-*.md`, `README.md`.
