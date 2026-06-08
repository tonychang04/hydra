---
status: implemented
date: 2026-06-08
author: hydra worker (ticket #284)
---

# Retro enrichment — per-worker / per-repo contribution + trend metrics

## Problem

Hydra's weekly retro (`docs/specs/2026-04-16-retro-workflow.md`) is an **inline
Commander procedure** that synthesizes six sections (Shipped / Stuck /
Escalations / Citation leaderboard / Promotion candidates / Proposed edits) from
`logs/*.json`, `state/memory-citations.json`, and `escalation-faq.md`. Those
sections are aggregate-only: total PRs, total stuck, a global citation
leaderboard. The operator cannot see **where** the signal concentrates — which
repo stalls workers, which repo merges cleanly, whether citation counts are
moving, or which flaky tool keeps biting.

gstack's `/retro` (north star: `gstack/.factory/skills/gstack-retro/SKILL.md`)
breaks results down **per contributor**, with streaks and week-over-week trend
tracking, precisely so the human can tune who/what to lean on. Hydra's analogue
of "contributor" is the **worker run** and the **target repo**. Surfacing
per-repo merge rate, per-repo stuck rate, citation-leaderboard *deltas*, and
flaky-tool hotspots gives the operator the same dispatch-tuning signal:
"serialize repo X, it stalls" / "this learning earned new citations, promote it"
/ "the `browse` tool flaked 3 times this week."

## Goals

- A deterministic, report-only helper that computes new per-worker/per-repo
  breakdown sections from `logs/*.json` + `state/memory-citations.json` and
  prints them as Markdown ready to splice into `memory/retros/YYYY-WW.md`.
- New sections:
  1. **Per-repo contribution** — for each repo in the window: PRs opened,
     merged, stuck; merge rate; stuck rate.
  2. **Per-worker contribution** — completions per `worker_type` (or
     `worker_id` when present): shipped vs stuck, total wall-clock minutes.
  3. **Citation leaderboard deltas** — entries whose `last_cited` is inside the
     window, sorted by `count`, with promotion-ready flag.
  4. **Flaky-tool hotspots** — counts of flaky-tool retry events parsed from
     each log's `surprises` / `flaky_tool` signal, grouped by tool.
- Deterministic from on-disk state only (same inputs => byte-identical output).
- Report-only: introduces **no** new merge, spawn, or label behavior.
- `scripts/validate-state-all.sh` exits 0 (no state-schema changes).

## Non-goals

- Not rewriting the inline retro procedure into a script. The inline procedure
  stays authoritative for the existing six sections; this helper only *adds* a
  breakdown block, mirroring how `retro-file-proposed-edits.sh` is a focused
  script the inline procedure calls.
- No new state files or schema changes.
- No GitHub API calls — purely local log + citation aggregation (deterministic,
  testable offline, no network in the test path).
- Not changing dispatch behavior. Output is advisory signal for the operator.

## Proposed approach

Add `scripts/retro-metrics.sh` (+ `scripts/test-retro-metrics.sh`), matching the
house style of `retro-file-proposed-edits.sh` (bash, `set -euo pipefail`, header
comment block, `--help`, explicit flags, exit codes, EXIT-trap cleanup).

```
retro-metrics.sh [--logs-dir P] [--citations-file P] [--window-days N]
                 [--now ISO8601] [--repo R]
```

- `--window-days` defaults to 7; `--now` (default: today) anchors the window so
  tests are deterministic.
- Reads every `logs/*.json` whose `completed_at` (fallback: file mtime) is inside
  `[now - window_days, now]`.
- Log fields consumed (all optional, jq `// default`): `repo`, `tier`,
  `result` (`merged` | `pr_opened` | `stuck`), `status`, `worker_type`,
  `worker_id`, `wall_clock_minutes`, `surprises` (string/array), `flaky_tool`.
- "stuck" = `result == "stuck"` OR `status` in
  (`stuck`, `failed`, `paused-on-question`, `paused_on_question`).
- "shipped" = `result` in (`merged`, `pr_opened`).
- Citation deltas: read `state/memory-citations.json`; an entry counts toward the
  window when its `last_cited` is inside the window; surface `count` + promotion
  flag, ranked by `count` among in-window entries (see "Risks").
- Emits four `##`-level Markdown sections to stdout. Empty window => each section
  prints a single "_none in window_" line (never crashes, always deterministic).

The inline retro procedure (CLAUDE.md "Weekly retro" + the retro skill if/when
one exists — out of scope here per COORDINATE-WITH) gains one pointer line:
"After the six core sections, append `scripts/retro-metrics.sh` output." That
wiring is documented in this spec; the CLAUDE.md edit itself is explicitly **out
of scope** for this ticket (COORDINATE-WITH forbids editing CLAUDE.md), so the
helper ships standalone and the operator/Commander splices it.

### Alternatives considered

- **A: Rewrite inline retro into one big script.** Rejected — large blast
  radius, fights the established Alternative-D inline design, and the
  COORDINATE-WITH note scopes this ticket to the generator script + spec only.
- **B: Compute metrics inside `retro-file-proposed-edits.sh`.** Rejected — that
  script's job is filing issues; mixing aggregation in violates single
  responsibility.
- **C (picked): standalone `retro-metrics.sh` the inline procedure splices.**
  Mirrors the existing focused-helper pattern, independently testable, zero
  state-schema risk.

## Test plan

`scripts/test-retro-metrics.sh` (house style, self-contained, no network),
covering:

1. **Per-repo breakdown** — fixture logs across 2 repos with mixed
   merged/pr_opened/stuck => correct counts + merge/stuck rates per repo.
2. **Per-worker breakdown** — fixtures with distinct `worker_type` => correct
   shipped/stuck split + summed wall-clock.
3. **Window filtering** — a log outside `[now-7d, now]` is excluded
   (deterministic via `--now`).
4. **Citation deltas** — citations file with some `last_cited` in-window, some
   out => only in-window entries surface, promotion flag honored, sorted by count.
5. **Flaky-tool hotspots** — logs whose `surprises`/`flaky_tool` mention a tool
   => grouped counts.
6. **Empty window** — no in-window logs => each section prints "_none in window_",
   exit 0.
7. **Determinism** — same inputs run twice => byte-identical stdout.
8. `scripts/validate-state-all.sh` exits 0 (no state mutated).

## Risks / rollback

- **Risk: citation "delta" is approximate.** `memory-citations.json` stores a
  running `count` + `last_cited`, not a per-week history. True week-over-week
  delta would need snapshots. **Mitigation:** scope the section to entries
  `last_cited` *inside* the window (they were touched this week) and rank by
  `count`; label the section "active this week" rather than claiming an exact
  delta. A future ticket can add weekly citation snapshots for exact deltas.
- **Risk: small-sample noise.** Same concern as the parent retro spec.
  **Mitigation:** this helper only *reports* counts; it proposes no edits, so the
  >=5-data-point gate (owned by the inline procedure) is unaffected.
- **Rollback:** delete `scripts/retro-metrics.sh` + its test and the one pointer
  line. No state migration; nothing else depends on it.
