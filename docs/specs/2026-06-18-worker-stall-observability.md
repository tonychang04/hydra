---
status: implemented
date: 2026-06-18
author: hydra worker (ticket #306)
---

# Worker-stall detector + failure-trend metrics — forward-facing observability

## Problem

Observability (P1, Hydra's weakest pillar) is **pull-only and backward-looking**:
operators run `./hydra status` or read `logs/*.json` *after the fact*. There is
no forward signal when a worker is silently stuck. The survey found stalls /
worktree-state confusion is the #1 recurring manual-intervention pattern —
`memory/learnings-hydra.md` cites #177/#185/#203/#262/#267/#285 (16+ occurrences)
— and `memory/worker-failures.md` is still an empty stub ("populated over time"),
so no failure-trend data accumulates anywhere a human can scan it.

The existing safety net (`scripts/rescue-worker.sh` + the autopickup tick's
completion-rescue scan) *acts* on individual stalls, but it does not **surface**
the standing signal: "how many workers are stuck right now?" and "which failure
modes keep recurring?". `scripts/retro-metrics.sh` (#284) computes *weekly,
retrospective, per-worker* trend metrics for the retro doc — a different cadence
and audience. Nothing produces a cheap, **per-tick, forward-facing** stall count
+ failure-mode top-N that the existing tick orchestrator can fold into its report.

## Goals

- A read-only, **report-only** detector (`scripts/detect-worker-stalls.sh`) that,
  for each RUNNING worker in `state/active.json`, computes idle time (now −
  `started_at`, mirroring `scripts/audit-detect.sh`) and flags any worker idle
  beyond a configurable threshold (default 12 min) that is not paused on a
  QUESTION. Emits `--json`.
- A durable, append-only event log: one JSON object per detection to
  `logs/stalls-YYYY-MM.jsonl` (`ts, worker_id, ticket, repo, idle_min, verdict`),
  so stall history accumulates for later trend reads.
- A `--trends` mode that counts failure-mode frequencies from recent `logs/*.json`
  (`result`/`surprises`/`flaky_tool` signals) **plus** the stall jsonl, and emits
  a top-N list, so recurring modes ("test runner timeout ×5") become visible.
- Wire a `stalls` key into `scripts/autopickup-tick.sh --json`, sourced from the
  detector, so the existing tick orchestrator surfaces it without itself acting.
- `scripts/validate-state-all.sh` exits 0 (no new validated state file — the
  jsonl is an append-only *log*, not state).

## Non-goals

- **No actuation.** The detector never kills, rescues, labels, spawns, or mutates
  `state/`. It REPORTS; Commander acts (via `rescue-worker.sh`, which already owns
  rescue/kill logic). Same verdict→nothing-to-act contract as the autopickup tick.
- Not a replacement for `rescue-worker.sh --probe`. That probe inspects a single
  worktree's git state to decide rescuability; this detector reads `active.json`
  in aggregate to surface idle/failure *trends*. Complementary, not overlapping.
- Not a replacement for `retro-metrics.sh` (#284). That is weekly, retrospective,
  spliced into the retro markdown. This is per-tick, forward-facing, machine-read
  by the tick. Different cadence + audience.
- No GitHub API calls — purely local `active.json` + `logs/*.json` aggregation
  (deterministic, offline-testable).
- No new `state/schemas/*` entry — the jsonl is a log, not validated state.

## Proposed approach

Add `scripts/detect-worker-stalls.sh`, copying the structure / flag-parsing /
exit-code conventions of `scripts/autopickup-tick.sh` and the portable
`now_epoch`/`iso_to_epoch` epoch helpers + the `started_at`-based age computation
of `scripts/audit-detect.sh` (do not reinvent either).

### Detector — default (stall-scan) mode

For each worker in `state/active.json` with `status == "running"`:
1. Compute `idle_min = (now − started_at) / 60` via the portable helpers.
   `started_at` is the only available activity signal — `active.json` carries no
   `last_active` field — exactly the basis `audit-detect.sh` uses.
2. A worker with `status` in `{paused_on_question, paused-on-question}` is NOT a
   stall (it is intentionally waiting on an operator answer — "no recent
   QUESTION" excludes the paused case).
3. Flag the worker `stalled` iff `idle_min >= threshold` (default 12, via
   `--threshold-min`). Verdict is `stalled` (flagged) or `ok` (under threshold).
4. Append one event line per **flagged** worker to `logs/stalls-YYYY-MM.jsonl`
   (suppressible with `--no-log` for tests): `{ts, worker_id, ticket, repo,
   idle_min, verdict}`.

`--json` output:
```json
{
  "generated_at": "<ISO8601Z>",
  "threshold_min": 12,
  "active_workers": <int>,
  "stalls": [ {"worker_id","ticket","repo","idle_min","status","verdict":"stalled"} ],
  "stall_count": <int>,
  "log_file": "logs/stalls-YYYY-MM.jsonl"
}
```

### Detector — `--trends` mode

Counts failure-mode frequencies, cheaply, from two sources within a window
(`--since-days`, default 30):
- recent `logs/*.json` — group by a normalized failure signal derived from
  `result` (e.g. `failed`, `stuck`) and any `surprises`/`flaky_tool` string;
- the `logs/stalls-*.jsonl` events — each `stalled` verdict is a `worker-stall`
  failure mode.

Emits a top-N (`--top`, default 5) `{mode, count}` list as JSON (`--json`) or a
human table. No state writes.

### Tick wiring

`scripts/autopickup-tick.sh` gains a section (mirroring 4b–4f) that shells out to
`detect-worker-stalls.sh --json --no-log` (the tick must not double-write the
event log; the detector's own scheduled run owns logging) against the tick's
`--state-dir`, captures `stalls_json`, adds a top-level `stalls` key to the
`--json` object, a `stalls` count into the actions roll-up, and a human-report
block. A test seam `--stalls-cmd <cmd>` lets the smoke test stub the detector.
Default behavior with no flag is byte-compatible except for the additive key.

## Test plan

- `scripts/test-detect-worker-stalls.sh` (self-contained, offline; matches
  `scripts/test-retro-metrics.sh` style):
  - empty `active.json` (no `workers`) → `stall_count == 0`, exit 0.
  - fixture with one RUNNING worker whose `started_at` is older than threshold
    (via `--now` override) → 1 stall flagged, verdict `stalled`, exit 0.
  - a worker under threshold → not flagged.
  - a `paused-on-question` worker older than threshold → NOT flagged.
  - `--trends` over fixture logs → expected top-N modes present.
  - `--no-log` suppresses jsonl writes; default writes one line per stall.
- Tick: `scripts/autopickup-tick.sh --json ...` output contains a `stalls` key
  (verified via the existing tick smoke test path + a direct `jq -e .stalls`).
- `scripts/validate-state-all.sh` exits 0 (no schema change).

## Risks / rollback

- **Risk:** `started_at`-only idle is a coarse proxy — a long-but-healthy worker
  reads as "idle". Mitigation: the detector REPORTS; Commander cross-checks with
  `rescue-worker.sh --probe` (which reads real git/trace state) before acting. The
  threshold is configurable and defaults conservatively (12 min < the ~18-min
  stream-idle ceiling) so a real stall is caught while still rescuable.
- **Risk:** jsonl growth. Mitigation: monthly file rotation (`stalls-YYYY-MM.jsonl`)
  and one line per *flagged* stall only.
- **Rollback:** the detector is a new standalone script; the tick change is a
  single additive key. Reverting the tick edit + deleting the script removes the
  feature with no state migration.

## Follow-up note (deferred — owned by #305's worker)

A one-line greeting/routing pointer for the stall detector belongs in CLAUDE.md
(e.g. under "Operating procedures"). A concurrent worker owns CLAUDE.md for #305,
so this spec defers that edit; it should be added as a follow-up once #305 lands.
