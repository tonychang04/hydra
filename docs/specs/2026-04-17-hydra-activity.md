---
status: in-progress
date: 2026-04-17
author: hydra worker (ticket #19)
---

# `./hydra activity` — text-based observability layer

## Problem

Hydra produces lots of runtime events — worker spawns, completions, stuck/escalated cases, retro writes, memory citations — but the only way to see any of it today is to hand-grep `logs/*.json`, eyeball `state/active.json`, and mentally aggregate. Basic operator questions have no fast answer:

- What has Hydra been doing in the last 24 hours?
- Which workers are active or stuck right now?
- Are memory entries actually earning their keep?
- How many retros have been written, when was the last one?

`./hydra status` (ticket #25) covers the *right now* snapshot — active count, budget counters, pause / autopickup state. It is deliberately a point-in-time scalar summary and does not surface any historical context. `retro` (ticket #1) covers the weekly *summary* view. There is no middle layer: "what's been happening over roughly the last day, at a glance."

Ticket #19 as originally filed sketches a broader "dashboard" with HTML output, quota burndown, etc. This spec narrows that to a text-only "activity" layer — no web UI, no metrics DB, no pretty charts, no real-time streaming. Those can be follow-ups once the text version is in daily use.

## Goals

- `./hydra activity` — terminal-friendly summary of the last 24 hours of Hydra activity plus a live snapshot of active / stuck workers and citation/retro counts
- Data sources (read-only, zero writes): `logs/*.json`, `state/active.json`, `state/memory-citations.json`, `state/autopickup.json`, optionally `memory/retros/*.md`
- `--json` output mode for downstream agent parsing (Commander, slack-bot, cron dashboards)
- Terminal table layout (plain ASCII, `column -t`-style or hand-aligned) that stays readable when the operator pipes through `less` or pastes into Slack
- Standalone helper script under `scripts/hydra-activity.sh`, following the exact pattern of `scripts/hydra-status.sh` (leaf `.sh` + `jq`, sources `.hydra.env` if present, `--help` banner, `NO_COLOR=1` honored)
- Launcher wiring via the `./hydra` subcommand dispatcher in `setup.sh` (one-line case-branch edit, matches `status` / `pause` / etc.)
- New self-test golden case `activity-command-smoke` (kind: `script`) — runs the script against deterministic fixtures, diffs on a few stable substrings, never hits the network
- README gets a new H2 "What Hydra is doing" pointing at the command

## Non-goals

- **No web server, HTML, or browser output.** The original ticket floated an `--html` mode; deliberately excluded. HTML is a separate ticket if ever justified.
- **No metrics database**, Prometheus scrape endpoint, or Grafana integration.
- **No real-time streaming** (no `watch`, no long-poll, no SSE). One-shot render, operator re-runs for a fresh view.
- **No charts, sparklines, or graphics** of any kind. Plain-text tables only.
- **No writes to any state file.** Pure read-only observability — a crash mid-render must leave state untouched.
- **Not a replacement for `retro`.** Retro is the weekly synthesis + writes `memory/retros/YYYY-WW.md`; activity is the 24-hour snapshot and never touches memory.
- **Not a replacement for `./hydra status`.** Status is the scalar "right now" (counts + pause + autopickup); activity is the historical + aggregated view.
- **Not an alerting tool.** If the operator wants paging, that's Slack-bot / supervisor-escalate territory.
- Does NOT touch `setup.sh`'s env-loading or `.hydra.env` (scope fence — worker #102 is editing those).
- Does NOT touch any memory-hygiene script or the MCP entrypoint (scope fence — worker #103).

## Proposed approach

One new helper: **`scripts/hydra-activity.sh`**, modeled directly on `scripts/hydra-status.sh` (same `jq_or` defensive-read helper, same color handling, same `--help` + exit-code conventions). All reads are defensive — a missing or malformed file degrades gracefully to a placeholder row, never crashes.

### Sections the render produces (human mode, default)

```
▸ Hydra activity — last 24h
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Completed (last 24h): N
  #TICKET            REPO                TIER  RESULT     PR    MIN
  ...

Active right now: K
  ID                 TICKET              TIER  STATUS     AGE
  ...

Stuck (status = paused-on-question or failed): M
  #TICKET            REPO                REASON (truncated)
  ...

Memory citations: top 5 of last 7d
  COUNT  ENTRY
  ...

Retros on disk: R (latest: memory/retros/YYYY-WW.md)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### `--json` mode

Emits a single JSON object with keys `{generated_at, window_hours, completed, active, stuck, citations_top, retros}`. Values are arrays of the same row objects used in the text render, minus the ANSI colors. No stdout decoration. Consumers: Commander for auto-surfacing, slack-bot for scheduled posts, possible future dashboards.

### Reads, precisely

- `logs/*.json` — one entry per completed ticket. Window = now − 24h, computed against `completed_at` (falling back to file mtime when `completed_at` is absent; older log files from before the timestamp field was standardized). The shape of each log is flexible per CLAUDE.md — `ticket`, `repo`, `tier`, `result`, `pr_url`, `wall_clock_minutes`, `completed_at` are the fields we display; everything else is ignored. Missing fields → render `—`.
- `state/active.json` — `workers[]`. Filter by `status` for the Active-right-now and Stuck buckets. Age computed from `started_at` in minutes.
- `state/memory-citations.json` — `citations{}`. Top 5 by `count`, sorted desc. Filter by `last_cited >= today - 7 days`.
- `memory/retros/*.md` — just the count + latest filename by natural sort. We don't parse retro contents.
- `state/autopickup.json` — reserved for a future "autopickup last tick" row; not displayed in v1 to keep the output compact. We already read it for `./hydra status`.

### Launcher wiring

Single minimal edit to `setup.sh`'s generated `./hydra` template — add one case branch alongside `status`, `pause`, etc.:

```bash
  activity)     shift; hydra_exec_helper scripts/hydra-activity.sh "$@" ;;
```

And a one-line usage entry in the heredoc-commented help block. This is a 2-line change; it does not overlap with env-file work that worker #102 is doing.

### Alternatives considered

- **A: Inline as a Commander chat command (same shape as `status` / `retro`).** Rejected — chat commands require spawning a Claude session. The whole point of the CLI surface (per `docs/specs/2026-04-16-hydra-cli.md`) is muscle-memory shell ops. Activity is routine observability; cron / slack / SSH all want it too.
- **B: Extend `./hydra status` with a `--history` flag.** Rejected — `status` is "right now, at a glance" (one-screen scalar). Mixing a 24-hour log view in blurs the contract. Separate subcommand, separate mental model.
- **C: New Python tool.** Rejected — repo invariant is bash + jq on the installable surface.
- **D: Ship the HTML output mentioned in the original ticket alongside the text version.** Rejected for now — the ticket's narrowed scope excludes it, and an HTML renderer is a separate meaningful chunk of work (template, asset embedding, browser-open convenience). Ticket follow-up if operators ask for it.
- **E: Write everything as a Python one-liner invoked via bash.** Rejected — matches the doctor / status / list-repos / issue pattern poorly and adds a maintenance axis.

## Test plan

- `bash -n scripts/hydra-activity.sh` — syntax clean.
- `scripts/hydra-activity.sh --help` exits 0, prints banner starting with `Usage: ./hydra activity`.
- Run script against fixture `self-test/fixtures/hydra-activity/`:
  - Fixture contains 3 canned log files (2 merged, 1 stuck), a fixture `active.json` with 1 running + 1 paused-on-question worker, a fixture `memory-citations.json` with 3 entries of varying counts.
  - Human mode: grep output for `Completed (last 24h): 3`, `Active right now: 1`, `Stuck`, and the fixture's highest-count memory key.
  - `--json` mode: `jq -e '.completed | length == 3'`, `jq -e '.active | length == 1'`, `jq -e '.stuck | length >= 1'`, `jq -e '.citations_top | length >= 1'`.
- Corrupt-JSON path: feed a deliberately broken fixture `state/active.json` (`{"workers": [` truncated) and verify the script does not crash (exit 0, shows `—` or `0` in the Active section, continues with the other sections).
- Self-test golden case `activity-command-smoke`: bundles the above as `script` kind. Runs standalone, no `gh`, no network.
- `jq . self-test/golden-cases.example.json` — still parses clean after new case added.

## Risks / rollback

- **Risk:** Log file shape evolves (new worker types add fields). Mitigation: `jq_or` defensive reads; only display a whitelisted field set; everything else ignored. A missing/renamed field shows `—`, never errors.
- **Risk:** Operator runs `./hydra activity` on a cold repo with zero logs + empty state files. Mitigation: all sections report `0` or `(none)` and exit 0. First-run UX must be clean.
- **Risk:** Large `logs/` directory (hundreds of files) makes the render slow. Mitigation: target is <2s even with ~500 log files; the render is a single `jq`-per-file pass, bounded by the 24-hour window filter. If this ever bites, switch to a `find -newermt` prefilter — noted in implementation comments.
- **Risk:** Color output clutters piped/Slack use. Mitigation: honor `NO_COLOR=1` (matches `hydra-status.sh`) and auto-disable colors when stdout is not a TTY.
- **Risk:** Scope-collision with ongoing edits to `setup.sh` (worker #102) and memory scripts / entrypoint (worker #103). Mitigation: the launcher edit is a single case-branch line; no memory-script changes here; no entrypoint.sh changes. Review will flag if merge conflicts.
- **Rollback:** Delete `scripts/hydra-activity.sh` + fixture dir + self-test case + README H2 + revert the single case-branch line in `setup.sh`. No migration, no persistent state touched.

## Implementation notes

- Follow the `scripts/hydra-status.sh` skeleton verbatim (color handling, `jq_or`, `--help` + exit-code conventions, root resolution via `SCRIPT_DIR/..`).
- Window-filter logs with `find "$logs_dir" -name '*.json' -type f -newermt "24 hours ago"` first, then `jq` each. This avoids `jq`-ing every historical log when the op is only showing the last day.
- Computed `age_min` in the Active section uses `started_at`; if absent, show `—` rather than inventing a value.
- `--json` output is `jq -n --arg ...`-built, never a `printf`-as-JSON. One malformed string must not corrupt the envelope.
- Deliberate Phase-1 caveat: activity does NOT count `gh` PR merge status (would require N network calls). Relies on `log.result` and `log.pr_url` verbatim. `retro` can follow up if needed.
