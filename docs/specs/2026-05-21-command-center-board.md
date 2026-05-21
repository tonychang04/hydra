---
status: draft
date: 2026-05-21
author: hydra worker (ticket #193)
---

# Live Command Center board (`scripts/build-board.sh`)

Ticket: [#193](https://github.com/tonychang04/hydra/issues/193) — `[P1/observability]`
Tier: T2 · Area: observability / Commander loop · Size: S–M

## Problem

Hydra runs while the operator sleeps. When they wake up they need a single
glanceable view of the fleet — who's running, who's stuck on a question, who got
rescued, what shipped, what failed — without replaying a chat log or running
`status` and reading prose.

Today the data already exists (`state/active.json` for in-flight workers,
`logs/<ticket>.json` for completed work) but it is only ever *summarized on
demand* in prose by Commander (the `status` command) or compressed into the
one-paragraph daily digest (`scripts/build-daily-digest.sh`). Neither gives the
Kanban-style "who is stuck vs awaiting review" board that the most-praised fleet
UXs (Devin / Windsurf 2.0 "Agent Command Center") lead with.

This directly attacks Hydra's weakest pillar: **observability (P1)**.

## Goals

- A standalone, read-only renderer `scripts/build-board.sh` that:
  - reads `state/active.json` + `logs/<ticket>.json` (both optional),
  - groups **every worker by lifecycle state** into five sections:
    Running / Paused-on-question / Rescued / Complete / Failed,
  - renders one row per worker with: ticket (as a GitHub link), age (computed
    from `started_at`), tier, `subagent_type`, and the last log line from
    `logs/<ticket>.json` if present,
  - writes Markdown to `state/board.md` (a gitignored runtime artifact) **and**
    prints the same Markdown to stdout,
  - handles an empty / missing `workers` array gracefully (still emits a valid,
    "no active workers" board),
  - mirrors the bash/jq style + conventions of `scripts/build-daily-digest.sh`.
- A regression test `scripts/test-build-board.sh` (mirroring
  `scripts/test-promote-citations.sh`) using `mktemp` fixtures.
- This spec documenting the board + its fields.

## Non-goals

- **Reconstructing terminal work from `logs/` alone.** The board groups workers
  that are *currently present in `state/active.json`*. The `active.json` status
  enum includes `complete`, `failed`, and `rescued`, so terminal entries do show
  up in those sections for as long as Commander leaves them in `active.json`.
  Once Commander prunes a finished worker out of `active.json`, it drops off the
  board. Surfacing a "recently shipped" section by scanning `logs/<N>.json` for
  workers no longer in `active.json` is a reasonable follow-up (it would make the
  board a fuller wake-up view) but is **out of scope** here — it changes the
  data model from "in-flight fleet snapshot" to "fleet + recent history" and
  needs its own retention/windowing decision. Tracked as a follow-up in the PR.
- No live/streaming TUI, no auto-refresh loop, no colors-in-file. Plain Markdown
  only. (A watcher can re-run the script; `/loop` already exists for that.)
- No edits to `CLAUDE.md` — PR #182 is unmerged and edits the commands table.
  A `status --board` / commands-table pointer is **noted in the PR body** for
  Commander to wire up after #182 merges; all behavior lives in the script.
- No new state file or schema. `state/board.md` is a derived artifact, not state.
- No GitHub API calls. The board renders purely from local state + logs (works
  offline, instant, no rate-limit exposure).

## Data model

### Inputs

`state/active.json` (schema: `state/schemas/active.schema.json`). Each worker:
`{id, ticket, repo, tier, started_at, subagent_type, status}` required;
`{worktree, branch}` optional. `status` enum:
`running | paused_on_question | paused-on-question | complete | failed | rescued`
(both the underscored and hyphenated "paused" forms are accepted per
`docs/specs/2026-04-17-active-schema-drift.md`).

`logs/<ticket>.json` (one file per ticket, JSON object). Observed fields:
`{ticket, repo, tier, result, pr_url, wall_clock_minutes, subagent_type}`.
The log filename key is the **ticket number** — i.e. for ticket
`tonychang04/hydra#193` the log is `logs/193.json`. Logs are optional; a row
without a log simply omits the last-log-line cell.

### State → board section mapping

| `active.json` status                          | Board section       |
|-----------------------------------------------|---------------------|
| `running`                                     | Running             |
| `paused_on_question` / `paused-on-question`   | Paused-on-question  |
| `rescued`                                     | Rescued             |
| `complete`                                    | Complete            |
| `failed`                                      | Failed              |

Any unrecognized status falls into an **Other** section so nothing is silently
dropped (forward-compat if the schema adds a state before the board learns it).

### Row fields

| Column     | Source                                                              |
|------------|--------------------------------------------------------------------|
| Ticket     | `worker.ticket`, rendered as a GitHub link when it parses as `owner/repo#N`; otherwise shown verbatim (e.g. `LIN-123`). |
| Age        | now − `worker.started_at`, humanized (`5m`, `1h30m`, `1d3h`). `?` if `started_at` is missing/unparseable. ISO-8601 timezone offsets (`+05:30` / `-07:00`) are honored: the offset is applied arithmetically so the epoch is correct on both GNU and BSD `date`. |
| Tier       | `worker.tier` (`T1`/`T2`/`T3`).                                     |
| Type       | `worker.subagent_type`.                                             |
| Last log   | One-line summary derived from `logs/<N>.json`: `result` + a short PR ref (`#502`) + wall-clock if present. Empty cell when no log exists. |

The "last log line" is a **derived one-liner**, not a raw tail: Hydra logs are
structured JSON objects (not append-only text streams), so the most useful
single line is `<result> (<pr-ref>, <N>m)` — e.g. `merged (#502, 23m)`. This is
the analog of "the last thing this worker did".

### Ticket → GitHub link resolution

`worker.ticket` shaped `owner/repo#N` → `[owner/repo#N](https://github.com/owner/repo/issues/N)`.
A bare `hydra#77` (no owner) or a Linear id `LIN-123` is shown verbatim (no link)
because the owner can't be inferred safely. This mirrors the digest's
best-effort ref handling and keeps the renderer offline.

### Log lookup key

For a worker ticket `owner/repo#N` (or `repo#N`), the log file is `logs/N.json`.
The renderer extracts the trailing `#N` and looks up `<logs-dir>/N.json`. If the
ticket has no `#N` suffix, no log lookup is attempted.

## Output format

```markdown
# Hydra Command Center

_Generated 2026-05-21T18:30:00Z · 4 workers_

## Running (2)
| Ticket | Age | Tier | Type | Last log |
|---|---|---|---|---|
| [tonychang04/hydra#96](https://github.com/tonychang04/hydra/issues/96) | 12m | T2 | worker-implementation |  |
| ...

## Paused-on-question (1)
| Ticket | Age | Tier | Type | Last log |
|---|---|---|---|---|
| ...

## Rescued (0)
_none_

## Complete (1)
...

## Failed (0)
_none_
```

Empty case (no workers):

```markdown
# Hydra Command Center

_Generated <ts> · 0 workers_

_No active workers._
```

Sections with zero workers render their header followed by `_none_` so the board
shape is stable run-to-run (operator's eye learns the layout). The empty-fleet
case collapses to a single `_No active workers._` line.

## CLI

```
scripts/build-board.sh [options]
  --state-dir <path>   Override state/ dir (default $ROOT/state)
  --logs-dir <path>    Override logs/ dir (default $ROOT/logs)
  --out <path>         Override output file (default <state-dir>/board.md)
  --now <iso8601>      Override "now" for deterministic age in tests.
  --no-write           Print to stdout only; do not write the file.
  -h, --help
Exit codes: 0 success · 2 usage error
```

The `--now` and `--state-dir`/`--logs-dir`/`--out` overrides exist so the test
can run hermetically against `mktemp` fixtures with deterministic ages, exactly
like `build-daily-digest.sh` and `promote-citations.sh` accept dir overrides.

## Test plan

`scripts/test-build-board.sh` (mirrors `scripts/test-promote-citations.sh`:
bash, colored pass/fail counter, `mktemp -d` fixture, no external harness):

1. **Grouping** — fixture `active.json` with one worker in each of the five
   states + matching `logs/*.json` for a couple of them. Assert each section
   header shows the right count and the right ticket lands in the right section.
2. **Last-log rendering** — a worker whose `logs/N.json` has
   `result=merged, pr_url=.../pull/502, wall_clock_minutes=23` renders
   `merged (#502, 23m)` in its row.
3. **GitHub link** — `owner/repo#N` ticket becomes a Markdown link to
   `/issues/N`; a bare `hydra#77` and a `LIN-123` stay verbatim (no link).
4. **Age** — with `--now` fixed, a worker started 90 min earlier shows `1h30m`.
5. **Empty workers array** — emits `_No active workers._`, exit 0.
6. **Missing active.json** — treated as empty fleet, exit 0.
7. **File write** — `state/board.md` (or `--out`) is created and its contents
   equal stdout.
8. **`--no-write`** — nothing written, stdout still produced.
9. **Unknown status** — a worker with `status=foobar` lands in an **Other**
   section (nothing dropped).
10. **Usage error** — unknown flag → exit 2.
11. **Missing `started_at`** — the row still renders Tier/Type in their proper
    cells with Age `?` (a US field separator keeps empty fields positional;
    a TAB separator would collapse and shift columns).
12. **Timezone offset** — `started_at` with a `-07:00` offset resolves to the
    correct UTC instant (age math is offset-aware).
13. **Present-but-unparseable `active.json`** — emits a visible board notice
    plus a stderr warning, and does NOT masquerade as a healthy empty fleet.
14. **Value-taking flag with no value** — `--state-dir` / `--logs-dir` /
    `--out` / `--now` with no following value → exit 2 (documented usage error).

Run: `scripts/test-build-board.sh` — 40 assertions, expect all green, exit 0.

## Risks / rollback

- **Risk:** log-key assumption (`logs/N.json` keyed by ticket number) is wrong
  for some future ticket-id shape (e.g. Linear). *Mitigation:* lookup is
  best-effort — a missing/zero match just yields an empty last-log cell; the row
  still renders. No crash.
- **Risk:** `state/board.md` accidentally committed. *Mitigation:* added to
  `.gitignore` alongside the other `state/*` runtime artifacts; the test never
  writes into the repo tree (uses `mktemp`).
- **Risk:** a broken/locked `active.json` reads as "no workers" and the operator
  trusts a board that's actually blind. *Mitigation:* a present-but-unparseable
  file is distinguished from an absent one — the board shows an explicit
  unreadable-state notice and a stderr warning instead of `_No active workers._`.
- **Rollback:** delete `scripts/build-board.sh`, `scripts/test-build-board.sh`,
  this spec, and the `.gitignore` line. Nothing else depends on the board; it is
  purely additive and read-only.
