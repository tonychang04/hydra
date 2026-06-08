---
status: draft
date: 2026-06-08
author: hydra worker (ticket #267)
---

# Decision Record — durable, human-reviewable WHY for Commander decisions

## Problem

Hydra observes **outcomes** but not **reasoning**. When Commander classifies a
tier, picks a ticket, routes to a subagent, scopes a fix, or decides
surface-vs-auto-merge, the rationale lives only in the **ephemeral agent
transcript**. The durable artifacts answer *what happened*:

- `logs/<ticket>.json` — outcome summary (ticket, PR, tier, files, tests, cost).
- `logs/traces/<ticket>.jsonl` — worker session trace, *how a worker got there*
  (`docs/specs/2026-05-21-worker-session-trace.md`, #197).
- `scripts/build-board.sh`, `scripts/build-daily-digest.sh`,
  `scripts/autopickup-tick.sh` — current-state surfaces.

None of them answer **"why did Commander do X?"** A human auditing Hydra cannot,
from the committed artifacts alone, reconstruct *why* PR #501 surfaced for human
merge instead of auto-merging, *why* ticket #312 was classified T2, or *why* a
worker was escalated. The operator said it directly (2026-06-08): "human needs
to know WHY something happened and what your decisions are."

This is the **P1 (observability/safety)** pillar, which is the weakest today.

## Goals

1. A **Decision Record**: an append-only, human-readable log where Commander
   records every consequential decision as one structured entry —
   `logs/decisions/<YYYY-MM-DD>.jsonl` (one JSON object per line, daily file).
2. A **writer helper** `scripts/record-decision.sh` (flags **or** JSON stdin)
   that appends a **schema-validated** entry, so Commander and scripts record
   decisions uniformly.
3. A **reader** `scripts/decisions.sh [<subject> | --since <date>]` that prints
   the decision(s) + rationale for a ticket/PR/worker — answers "why did
   Commander do X?".
4. **One real producer wired end-to-end**: `scripts/autopickup-tick.sh`'s
   merge-surface step already computes the reason (`t3-never` / `safety-rail` /
   `policy-<x>`); behind an opt-in flag it emits a `merge-surface` decision
   entry per merge-ready PR, proving the loop works on real computed data.
5. **Surfaced**: a short "Recent decisions" section in `scripts/build-board.sh`
   and the daily digest.
6. A JSON schema + validation wired into `scripts/validate-state-all.sh`, plus a
   RED→GREEN fixture demonstrating the writer rejecting a malformed entry.
7. A documented **seam** for the sibling Approval Record (#268) via a nullable
   `approval_ref` field — defined here, *not implemented* here.

## Non-goals

- **The approval workflow (#268).** We define the `approval_ref` field and
  document the seam; we do not build human-gated approval capture.
- **Auto-wiring every decision point.** We ship the writer + reader + format +
  schema + **one** working producer (`merge-surface`, the highest-stakes,
  already-computed reason) + seeded fixtures for two more types
  (`tier-classify`, `escalate`) so the format is concrete. Broad wiring of
  ticket-pick / subagent-route / scope / rescue / gc / pause is a follow-up
  (Commander emits those from its operating loop using the same helper).
- **Changing existing log/trace behavior.** This is purely **additive**. No edit
  to `logs/<ticket>.json` or `logs/traces/*.jsonl` formats.
- **A UI / decision viewer.** `scripts/decisions.sh` + jq are the v1 read path.
- **Rotation / retention.** Decisions are gitignored runtime under `logs/`
  (`.gitignore` already has `logs/*` with `!logs/.gitkeep`), sharing that
  directory's lifecycle. Committed examples live under `self-test/fixtures/`.

## Survey (current state, cited)

- **Outcome log**: `logs/<num>.json` per `.claude/agents/worker-implementation.md`
  ("Append to `$COMMANDER_ROOT/logs/<num>.json`…"). Sample fixture:
  `self-test/fixtures/cost-attribution/logs/196.json`.
- **Session trace** (#197): `docs/specs/2026-05-21-worker-session-trace.md`
  establishes the conventions this spec REUSES: append-only JSONL under `logs/`,
  a bash+jq writer (`scripts/trace-append.sh`) that builds the line with jq and
  `>>`-appends, a jq-based reader (`scripts/trace-analyze.sh`), a committed
  fixture under `self-test/fixtures/`, and a standalone `scripts/test-*.sh`.
- **Merge-surface reason** is already computed in `scripts/autopickup-tick.sh`
  (the merge-surfacing block): each merge-ready PR gets a `classification`
  (`surface-for-human` | `auto-merge-eligible`), a `reason` (`t3-never` |
  `policy-never` | `policy-human` | `safety-rail` | `policy-<auto>` |
  `policy-unknown`), and a `policy`. The tick is **REPORT-ONLY** — it never
  mutates Commander state — so the producer is **opt-in** (`--record-decisions`)
  and writes only to the additive decision log, never to `state/`.
- **Surfaces**: `scripts/build-board.sh` renders fixed-order `## <Section>`
  blocks via `render_section_from_rows`; `scripts/build-daily-digest.sh` composes
  a single capped paragraph from non-empty clauses.
- **Schema + validation**: every `state/*.json` has `state/schemas/*.schema.json`
  and `scripts/validate-state-all.sh` validates them. JSONL is line-delimited, so
  the schema describes **one entry** (one line), validated per-line by the
  writer (the bulk validator validates `state/*.json` objects; the per-line
  entry schema is enforced at write time by `record-decision.sh`).
- **Script conventions** (followed): `set -euo pipefail`, `--help`/usage,
  documented exit codes, flags-or-stdin, jq for JSON construction. Models:
  `scripts/trace-append.sh`, `scripts/parse-citations.sh`, `scripts/state-put.sh`.
- **Test conventions**: `scripts/test-trace.sh` / `scripts/test-promote-citations.sh`
  — plain bash, `say/ok/bad` helpers, pass/fail counter, `mktemp` fixtures.
  CI runs `bash -n` on every `scripts/*.sh` and frontmatter-checks specs
  (`scripts/preflight-syntax.sh`).
- **Verify-first contract** (#255): `validation-contract.md` at the **worktree
  root**, validated by `scripts/validate-contract.sh`. Committed for Hydra's own
  tickets. This ticket dogfoods it.

## Decision Record format

`logs/decisions/<YYYY-MM-DD>.jsonl` — newline-delimited JSON, one object per
line = one decision. Daily file (mirrors `memory/digests/<date>.md` /
retro-by-week cadence and keeps any one file small). The directory is
auto-created on first write.

Entry field contract:

| field | required | type | meaning |
|---|---|---|---|
| `ts` | yes | string | ISO-8601 UTC timestamp, second precision (e.g. `2026-06-08T18:30:00Z`). Decision time. |
| `decision_type` | yes | enum | One of `tier-classify`, `ticket-pick`, `subagent-route`, `scope`, `merge-surface`, `escalate`, `rescue`, `gc`, `pause`. |
| `subject` | yes | string | The thing decided about — ticket/PR/worker ref (e.g. `tonychang04/hydra#501`, `worker-abc123`). |
| `decided` | yes | string | What was chosen (e.g. `surface-for-human`, `T2`, `worker-implementation`). |
| `why` | yes | string | Rule/policy clause + concrete evidence (e.g. `policy.md T2: touches >1 module; scripts/x.sh:12`). |
| `alternatives` | no | array | Rejected options, each `{option, why_rejected}`. Absent/empty allowed (some decisions are forced). |
| `confidence` | no | enum | `low` / `medium` / `high`. How sure Commander was. |
| `what_would_reverse` | no | string | The new fact that flips this decision (e.g. "if the PR drops the auth-path edit"). |
| `approval_ref` | no | string\|null | **Seam for #268.** Link/ref to an approval record when the decision was human-gated; `null` (or absent) otherwise. Defined here, populated by #268. |

`decision_type` mirrors the consequential decision points named in CLAUDE.md's
operating loop + safety/merge sections. The minimal viable schema requires the
five always-known fields (`ts`, `decision_type`, `subject`, `decided`, `why`);
the rest are optional so a forced/low-context decision is still recordable.

## Proposed approach

### Writer — `scripts/record-decision.sh` (active append, jq-built)

**Decision: an active append helper, mirroring `scripts/trace-append.sh`.** The
caller (Commander, or `autopickup-tick.sh`) invokes it at the decision point.
Same rationale as the trace spec: there is no machine-readable transcript on
disk to extract from post-hoc; the active helper records the real decision at
the moment it's made, degrades safely (a missing call = a missing entry, never a
crash), and is pure bash+jq with no daemon/backend.

- **Input (two modes):**
  - **Flags:** `--type <decision_type>` `--subject <s>` `--decided <d>`
    `--why <w>` (the four required-beyond-`ts`); plus optional `--confidence`,
    `--what-would-reverse`, `--approval-ref`, repeatable
    `--alternative '<option>::<why_rejected>'`.
  - **JSON stdin:** `--json` reads a complete entry object from stdin (for
    scripts that already have a jq object, e.g. the tick).
- `ts` is generated (ISO-8601 UTC) if not present in the input.
- Builds the object with jq, **validates** it against the entry schema (required
  fields present + non-empty; `decision_type` / `confidence` in their enums),
  then `>>`-appends one line to `logs/decisions/<today>.jsonl`. `--decisions-dir`
  (default `$HYDRA_DECISIONS_DIR` → `./logs/decisions`) and `--date <YYYY-MM-DD>`
  (default today, test seam) override placement.
- **Exit codes:** `0` ok (line appended); `1` invalid entry (validation failed,
  nothing written); `2` usage error.

### Reader — `scripts/decisions.sh [<subject>] [--since <date>]`

- No arg: print all decisions across the available daily files (most recent
  first), human-readable.
- `<subject>` (e.g. `#501`, `tonychang04/hydra#501`, `worker-abc`): filter to
  entries whose `subject` matches (substring + `#N` normalization, so `#501`
  matches `tonychang04/hydra#501`).
- `--since <YYYY-MM-DD>`: only files/entries on or after that date.
- `--json`: machine output (array of entries). Default: a readable block per
  entry (`<ts> [<type>] <subject> → <decided>` then indented `why` /
  `alternatives` / `confidence` / `what_would_reverse`).
- `set -euo pipefail`, `--help`, `--decisions-dir`. Exit `0` (found or empty),
  `2` usage/missing-dir-with-explicit-path.

### Producer wiring — `autopickup-tick.sh` merge-surface (opt-in)

The tick's merge-surface block already produces, per merge-ready PR, the exact
tuple a `merge-surface` decision needs: `subject` (PR ref), `decided`
(`classification`), `why` (`reason` + `policy`), `tier`. Behind a new
`--record-decisions` flag (default OFF, preserving the tick's report-only
default and all existing test expectations), after a PR's `classification` /
`reason` / `policy` are resolved, the tick calls `record-decision.sh --json`
with a `merge-surface` entry:

- `subject` = `<slug>#<number>`
- `decided` = `<classification>`
- `why` = human sentence built from `reason` + `policy` + `tier` (e.g.
  `t3-never: T3 is never auto-merge-eligible (safety rail)`).
- `what_would_reverse` = reason-specific (e.g. for `safety-rail`: "if the PR
  stops touching a safety-rail path").
- `approval_ref` = `null` (the #268 seam).

This writes ONLY to the additive `logs/decisions/` log — never to `state/` — so
the tick stays report-only with respect to Commander state. When the flag is
off, behavior is byte-identical to today.

### Surfaces

- **Board** (`build-board.sh`): a `## Recent decisions (<n>)` section after the
  worker sections, listing the last few entries (newest first) as a table
  (`When | Type | Subject | Decided | Why`). Best-effort: if the decisions dir
  is absent/empty, render `_none_` (same convention as empty worker sections).
  Reads via `scripts/decisions.sh --json` to stay DRY.
- **Digest** (`build-daily-digest.sh`): a `decisions recorded N` clause when
  today's file has entries (joins into the existing comma-separated clause list,
  honoring the char cap).

### Schema + validation

- `state/schemas/decision-entry.schema.json` — Draft-07 schema for **one entry
  object** (one JSONL line). Required: `ts`, `decision_type`, `subject`,
  `decided`, `why`. Enums for `decision_type` / `confidence`. `approval_ref`
  nullable.
- The bulk `scripts/validate-state-all.sh` validates `state/*.json` files (whole
  objects); JSONL lines are validated per-line by `record-decision.sh` at write
  time (the gate that matters). We add a self-test fixture that runs the writer
  against a malformed entry and asserts rejection (RED→GREEN).

## Data flow

```
Commander / tick --(record-decision.sh --type merge-surface --subject #501 ...)--> logs/decisions/<date>.jsonl
operator         --(decisions.sh #501)----------------------------------------------> "why #501 surfaced" (human)
build-board.sh   --(decisions.sh --json | tail)---------------------------------------> "## Recent decisions" on the board
build-daily-digest.sh --(count today's entries)--------------------------------------> "decisions recorded N" clause
```

## Test plan

- **`scripts/test-record-decision.sh`** (standalone bash, model =
  `scripts/test-trace.sh`):
  - flags mode appends a valid line; line is valid JSON with required keys.
  - JSON-stdin mode appends a valid line.
  - **RED→GREEN**: a malformed entry (missing `why`; bad `decision_type` enum;
    empty `subject`) is REJECTED (exit 1, nothing written) — then a corrected
    entry is ACCEPTED (exit 0, one line).
  - `ts` auto-generated when absent; `--date` seam controls the target file.
- **`scripts/test-decisions.sh`** (reader): seed a tmp dir with 2-3 entries;
  assert no-arg lists all, `<subject>` filters (incl. `#N` normalization),
  `--since` filters by date, `--json` is a valid array.
- **`self-test/fixtures/decision-record/`**: committed `sample-decisions.jsonl`
  (one entry per seeded type: `tier-classify`, `merge-surface`, `escalate`) +
  `run.sh` offline driver delegating to the two test scripts and asserting the
  reader output against the fixture.
- **Producer round-trip**: run `autopickup-tick.sh --record-decisions` with the
  gh-mock seam over a fixture merge-ready PR set; assert a `merge-surface` entry
  lands in the decisions dir with the computed reason. With the flag OFF, assert
  no entry is written (no behavior change).
- **Schema**: `scripts/validate-state-all.sh` stays green (no NEW failures vs the
  pre-existing `state-schemas`/ajv baseline).
- **Surfaces**: `scripts/test-build-board.sh` stays green; add a case that the
  board renders a "Recent decisions" section when the dir has entries.
- **CI**: `scripts/preflight-syntax.sh` exit 0 (spec frontmatter + all scripts).
- **Self-test**: `self-test/run.sh --kind script` — no NEW failures.
- **Dogfood**: `validation-contract.md` at worktree root passes
  `scripts/validate-contract.sh`.

## Risks / rollback

- **Risk: producer wiring changes tick behavior.** Mitigated: the producer is
  behind `--record-decisions` (default OFF); with the flag off the tick is
  byte-identical, and it writes only to the additive log, never `state/`.
- **Risk: decision dir absent breaks surfaces.** Mitigated: board/digest treat a
  missing/empty dir as `_none_` / no clause (fail-soft, same as empty worker
  sections).
- **Risk: schema drift between the entry schema and what the writer emits.**
  Mitigated: the writer validates against the schema-mirrored required/enum
  rules at write time, and the self-test fixture exercises both accept + reject.
- **Risk: committed runtime.** Mitigated: `logs/decisions/` is gitignored via
  the existing `logs/*` rule; the only committed JSONL is the fixture under
  `self-test/fixtures/`.
- **Rollback:** the feature is additive + opt-in. Reverting the producer flag (or
  the whole PR) leaves all existing logs/traces/surfaces untouched.

## Seam for #268 (Approval Record)

The `approval_ref` field is the documented join point. A human-gated decision
(e.g. an operator-approved T2 merge) will, under #268, write an **approval
record** and set this decision entry's `approval_ref` to that record's id/link.
Until #268 lands, `record-decision.sh` accepts `--approval-ref` (passthrough)
and the tick emits `null`. No approval *workflow* is built here.
