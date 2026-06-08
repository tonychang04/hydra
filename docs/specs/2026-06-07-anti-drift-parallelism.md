---
status: proposed
date: 2026-06-07
author: hydra worker
ticket: 257
tier: T2
---

# Anti-drift parallelism: pre-spawn file-overlap detection auto-serializes conflicting tickets

**Ticket:** [#257 — Anti-drift parallelism](https://github.com/tonychang04/hydra/issues/257)
**Implements:** this spec.

## Problem

Hydra parallelizes ticket workers by **count** — Commander spawns up to
`budget.json:phase1_subscription_caps.max_concurrent_workers` workers, each in its
own worktree → a draft PR. Coordination between those concurrent workers is
**manual**: the slim spawn prompt carries a hand-written "Coordinate-with hints"
line (`docs/specs/2026-04-17-slim-worker-prompts.md`), and the
`worker-conflict-resolver` cleans up *after the fact* when PRs collide.

Factory Missions rejected broad parallelism for exactly this reason — "agents
conflict, duplicate work, and drift." This session proved the risk concretely:
multiple candidate tickets wanted to touch the same files
(`scripts/autopickup-tick.sh`, `self-test/golden-cases.example.json`,
`CLAUDE.md`). Collisions were avoided **only because Commander manually
sequenced** the spawns. That manual gate is:

- **Non-deterministic** — it depends on the operator/Commander noticing the
  overlap by eye before spawning.
- **Lossy** — when it's missed, two workers edit the same file in parallel, then
  the conflict-resolver (or a human) has to untangle it, often after wasted work
  (the "duplicate work, and drift" failure mode).
- **Unscalable** — the more tickets in a batch, the more pairwise overlaps a
  human has to reason about (O(n²) by hand).

There is a stub already acknowledging this gap. `docs/specs/2026-04-17-slim-worker-prompts.md`
§ "Out of scope" lists: *"Auto-generating the Coordinate-with hints from
`state/active.json` … automation is a follow-up (`scripts/active-overlap-hint.sh`
stub candidate)."* This ticket is the deterministic version of that follow-up,
applied to the **candidate batch** (pre-spawn) rather than to already-running
workers.

## Goals

- A **pre-spawn helper** `scripts/plan-parallel-batch.sh` that, given a candidate
  batch of tickets, estimates each ticket's likely **file/path footprint** and
  partitions the batch into:
  - a **parallelizable set** — tickets whose footprints are mutually disjoint
    (safe to spawn concurrently), and
  - **serialized groups** — tickets whose footprints overlap (must run
    one-at-a-time, in ticket-number order).
- **Deterministic + offline-testable.** Same input → same output, no network, no
  Claude. Footprint estimation is a transparent keyword/grep heuristic over the
  ticket's title + body, not an LLM call.
- **Structured output** — JSON (machine-readable, for the tick/spawn path) AND a
  human-readable report (for the operator), exactly like
  `scripts/autopickup-tick.sh` and `scripts/pr-shepherd.sh`.
- **Report-only.** The helper RECOMMENDS a partition; it does **NOT** spawn,
  merge, label, or mutate any state. Commander actuates (the same
  report-don't-mutate discipline the tick follows).
- **Complements (does not replace) `worker-conflict-resolver`.** This is the
  *preventive* gate (avoid the collision before it happens); the conflict-resolver
  is the *curative* one (merge the collision after it happens). Both stay.
- Wired as a **recommendation** into the spawn/tick path: documented in CLAUDE.md
  (≤ 1 pointer line, offset by a trim) so Commander runs it before a multi-spawn.

## Non-goals

- **Actuation.** The helper never spawns workers, never writes the
  coordinate-with line into a prompt, never edits `state/active.json`. Commander
  reads the recommendation and decides. (Same split as the tick.)
- **Perfect footprint prediction.** A keyword/grep heuristic cannot know the
  exact files a worker will touch — only a worker reading the code knows that.
  The heuristic is intentionally **conservative**: when in doubt it predicts a
  *broader* footprint (more likely to serialize), because a false serialize costs
  some parallelism, while a false parallelize costs a conflict + rework. We bias
  toward the cheaper error.
- **Replacing the conflict-resolver.** Overlaps the heuristic misses still get
  caught downstream by `worker-conflict-resolver`. This is defense-in-depth, not a
  replacement.
- **LLM-based footprint inference.** Out of scope — non-deterministic and
  un-offline-testable. A future ticket could add an optional `--explore` mode that
  shells out to a real grep over a checked-out repo, but v1 is title/body-only +
  an optional explicit footprint override per ticket.
- **Reworking the self-test harness or golden-cases format.** The fixture lives
  under `self-test/fixtures/anti-drift-parallelism/` and runs standalone. We
  *append* one new `script`-kind golden case
  (`anti-drift-parallelism-partition`) to `self-test/golden-cases.example.json`
  so the partition logic is covered by the existing self-test runner — an
  additive entry only, no change to the file's schema, no edits to pre-existing
  cases, and no change to how the runner consumes the file.

## Proposed approach

### Input

The helper reads a **candidate batch** as JSON (a file via `--file`, or stdin):

```json
{
  "tickets": [
    { "number": 301, "title": "Add --json flag to status command",
      "body": "...mentions scripts/status.sh..." },
    { "number": 302, "title": "Fix autopickup tick interval guard",
      "body": "...edits scripts/autopickup-tick.sh..." },
    { "number": 303, "title": "Document the tick in CLAUDE.md",
      "body": "...edits scripts/autopickup-tick.sh and CLAUDE.md..." }
  ]
}
```

Optional per-ticket `"footprint": ["path/a", "path/b"]` lets a caller supply an
explicit footprint (e.g. from a real grep/Explore), which **overrides** the
heuristic for that ticket. This keeps the helper deterministic while leaving a
seam for a richer caller later.

This shape is a **subset** of `gh api /repos/.../issues` output (`number`,
`title`, `body`), so Commander can pipe `gh` JSON straight in with a small `jq`
projection — no bespoke format.

### Footprint estimation (deterministic heuristic)

For each ticket, derive a set of predicted paths from `title + " " + body`:

1. **Explicit-path extraction (primary signal).** Regex-match tokens that look
   like repo paths: `[A-Za-z0-9_./-]+\.(sh|md|json|py|js|ts|yml|yaml|toml)` and
   bare well-known top-level files (`CLAUDE.md`, `policy.md`, `budget.json`).
   These are the strongest signal — a ticket that names `scripts/foo.sh` will
   almost certainly touch it.
2. **Directory keywords (secondary signal).** Map keyword → directory bucket so a
   ticket that says "the autopickup tick" but doesn't spell the path still lands
   in the right bucket. Buckets are coarse on purpose (conservative):
   - `tick`/`autopickup` → `scripts/autopickup-tick.sh`
   - `self-test`/`golden`/`fixture` → `self-test/`
   - `claude.md`/`routing`/`commander rules` → `CLAUDE.md`
   - `spec`/`docs` → `docs/specs/`
   - `memory`/`learnings`/`citation` → `memory/`
   - `schema`/`state file` → `state/`
   - `worker`/`agent`/`subagent` → `.claude/agents/`
   - `skill` → `.claude/skills/`
   The keyword→bucket table is a single associative array at the top of the
   script (one place to extend).
3. **Normalization.** Lowercase for matching; dedupe; a directory bucket and an
   explicit file under it are treated as overlapping (prefix match — see below).

If a ticket yields an **empty** footprint (no path tokens, no keywords), it is
flagged `footprint_source: "none"` and treated as **conservatively
parallel-unsafe ONLY against other empty-footprint tickets is NOT assumed**;
instead an empty footprint is reported as `unknown` and the ticket is placed in
its **own singleton serialized group** with a `warning` — Commander should write
a coordinate-with hint by hand for it. (We do not silently parallelize an
unknown; we do not silently serialize it against everything either — we surface
it. This is the report-only contract: make the gap visible, don't guess.)

### Overlap = prefix-aware set intersection

Two tickets **overlap** if any path in one is a prefix of (or equal to) a path in
the other, treating a bucket like `self-test/` as a directory prefix. So
`self-test/` overlaps `self-test/fixtures/foo/run.sh`, and
`scripts/autopickup-tick.sh` overlaps `scripts/autopickup-tick.sh`. Plain file
paths overlap only on equality. This makes the coarse directory buckets do their
conservative job: a "touches self-test" ticket serializes against a specific
self-test file ticket.

### Partition algorithm (union-find / connected components)

Build an undirected graph: nodes = tickets, edge = footprint overlap. The
**connected components** are the serialized groups:

- A component of **size 1** with a known footprint → that ticket is
  **parallel-safe** (goes in the `parallel` set).
- A component of **size ≥ 2** → a **serialized group**; within the group, run in
  ascending ticket-number order (deterministic; matches the conflict-resolver's
  "lower PR number first" rule).
- A singleton with an **unknown** footprint → its own group with a `warning`
  (surfaced, not auto-parallelized).

Union-find is O(n²) edge checks for n tickets, which is fine — batches are
single-digit. Determinism: tickets sorted by number before processing; component
representatives chosen as the min ticket number.

### Output

`--json` (default for the tick path):

```json
{
  "generated_at": "2026-06-07T...Z",
  "batch_size": 3,
  "parallel": [301],
  "serialize_groups": [
    { "group": [302, 303], "shared": ["scripts/autopickup-tick.sh"], "order": [302, 303] }
  ],
  "unknown": [],
  "footprints": {
    "301": { "paths": ["scripts/status.sh"], "source": "explicit-path" },
    "302": { "paths": ["scripts/autopickup-tick.sh"], "source": "explicit-path" },
    "303": { "paths": ["scripts/autopickup-tick.sh","CLAUDE.md"], "source": "explicit-path+keyword" }
  },
  "recommendation": "spawn 301 in parallel; serialize [302 -> 303] (share scripts/autopickup-tick.sh)"
}
```

Human report (default without `--json`): a grouped, readable version of the same —
"Parallel-safe:", "Serialize (one-at-a-time):", "Unknown (write a coordinate-with
hint by hand):", and a one-line recommendation. Mirrors the tick's report style.

### How it composes with `worker-conflict-resolver`

| | `plan-parallel-batch.sh` (this ticket) | `worker-conflict-resolver` (existing) |
|---|---|---|
| **When** | BEFORE spawn (pre-flight gate) | AFTER ≥2 PRs already conflict |
| **Acts on** | candidate ticket batch | open PR branches |
| **Effect** | prevents the collision (serialize overlaps) | merges the collision (additive resolution) |
| **Mutates?** | no — report-only recommendation | yes — produces a superseding merge branch + PR |
| **Determinism** | fully deterministic heuristic | deterministic for additive, escalates semantic |

They are two halves of one anti-drift strategy: **prevent** what you can predict
cheaply (footprint overlap from ticket text), **cure** what slips through (real
diff conflict on the branch). The helper's docstring + the spec table above + a
note in `worker-conflict-resolver.md` make the relationship explicit so a future
worker doesn't think one obsoletes the other.

### Wiring into the spawn/tick path (recommendation only)

- **CLAUDE.md**: one pointer line under "Operating loop" step 5 (Spawn): *"Before
  a multi-ticket spawn, run `scripts/plan-parallel-batch.sh` to partition the
  batch into parallel-safe vs serialize groups (report-only; you actuate)."*
  Offset the addition by trimming an over-long line elsewhere so the size guard
  stays green (CLAUDE.md is near its band).
- The helper is consumable by the autopickup tick later (it emits stable JSON),
  but this ticket does **not** modify `autopickup-tick.sh` — that's a
  safety-rail file and a separate wiring ticket. v1 is the helper + its
  recommendation pointer.

## Test plan

TDD. A standalone test driver `scripts/test-plan-parallel-batch.sh` (bash,
colored pass/fail counter, mirrors `scripts/test-validate-contract.sh`) plus a
fixture under `self-test/fixtures/anti-drift-parallelism/`.

**Headline acceptance fixture (from the ticket):** 3 tickets, 2 sharing a file →
helper recommends `parallel{disjoint}` + `serialize{the 2 overlapping}`:

1. **3-ticket / 2-overlap fixture** (the acceptance criterion). Input: ticket A
   (touches `scripts/status.sh`), B + C (both touch
   `scripts/autopickup-tick.sh`). Assert JSON: `parallel == [A]`,
   `serialize_groups[0].group == [B, C]`, `shared` contains the tick script.
2. **All-disjoint** → all in `parallel`, no serialize groups.
3. **All-overlap** (3 tickets, same file) → one serialize group of 3, empty
   `parallel`.
4. **Explicit `footprint` override** beats the heuristic.
5. **Directory-bucket overlap** — a "self-test" keyword ticket overlaps a
   `self-test/fixtures/x.json` explicit-path ticket (prefix match).
6. **Unknown footprint** (title/body with no path/keyword) → `unknown` list +
   warning, NOT silently parallelized.
7. **Determinism** — same input twice → byte-identical JSON (modulo
   `generated_at`, which the test strips).
8. **Usage errors** — malformed JSON → exit 2; empty batch → exit 2; `--help` →
   exit 0.
9. **Single ticket** → trivially parallel (one-element `parallel`, no groups).

Plus the standard gates the ticket requires (all RUN, real output):

- `bash scripts/test-plan-parallel-batch.sh` → exit 0.
- `bash -n scripts/plan-parallel-batch.sh` (and `scripts/preflight-syntax.sh`).
- `self-test/fixtures/anti-drift-parallelism/run.sh` → exit 0 (runs standalone,
  and is also exercised by the appended `anti-drift-parallelism-partition`
  `script`-kind golden case in `self-test/golden-cases.example.json`).
- `self-test/run.sh --kind script` → no NEW failures (state-schemas/ajv is the
  known pre-existing case).
- `scripts/validate-state-all.sh` → exit 0.
- `scripts/validate-contract.sh --file validation-contract.md` → exit 0 (this
  ticket's own filled contract).

## Risks / rollback

1. **Heuristic over-serializes** (false overlap) → some lost parallelism, never a
   conflict. Acceptable by design (we bias to the cheaper error). Mitigation: the
   `footprint` override + the per-ticket `source` field make it auditable; if a
   bucket is too coarse, narrow it in the one keyword table.
2. **Heuristic under-serializes** (missed overlap) → a real conflict slips
   through, caught by `worker-conflict-resolver` exactly as today. No regression
   vs the status quo (manual coordinate-with also misses things).
3. **Rollback.** Pure addition — a new script + fixture + one CLAUDE.md pointer.
   `git revert` the pointer commit and Commander falls back to manual
   coordinate-with. The script is inert unless explicitly invoked.
4. **Determinism drift.** Locked by test 7 (byte-identical output) so a future
   edit that introduces nondeterminism (e.g. unsorted iteration) fails CI.
5. **No safety-rail file touched.** The helper is read-only and does not modify
   `autopickup-tick.sh`, `merge-policy-lookup.sh`, `policy.md`, workflows, or any
   state file — it only reads its input batch and prints.
