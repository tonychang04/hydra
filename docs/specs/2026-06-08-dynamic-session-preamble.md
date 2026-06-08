---
status: draft
date: 2026-06-08
author: hydra worker (ticket #274)
---

# Dynamic learnings-search + recent-failure-pattern session preamble

**Ticket:** [#274](https://github.com/tonychang04/hydra/issues/274) — P3/auto-learn, Tier 1.
**Status:** implemented.

## Problem

gstack injects two dynamic signals into its session preamble: a `learnings-search`
over the project's accumulated learnings, and a recent-event timeline that the agent
uses to adapt (e.g. "the last three runs all failed at signing → check the keychain
first"). Hydra's memory-preload is **static**: the Memory Brief (`docs/specs/2026-04-17-memory-preloading.md`)
is a curated excerpt prepended to *worker* prompts, but Commander's own session
greeting (`CLAUDE.md` § "Session greeting") surfaces only counts — N tickets ready,
K workers active — with no view into *what recently went wrong* or *which learnings
are most relevant right now*. Commander therefore re-learns the same lessons and
cannot say "the last 3 workers on `mcp-sentinel` hit flaky-tool-retry → prefer codex".

This is the weakest of the three north-star pillars (auto-learn, P3) per the
2026-06-07 self-improvement push: the data to adapt already exists in
`memory/learnings-*.md` and `logs/*.json`, but nothing reads it dynamically at
session start.

## Goals

1. `scripts/hydra-memory-search.sh <query> [--limit N]` — a read-only keyword search
   over `memory/learnings-*.md`, ranked by match count, emitting compact text (and
   `--json`). `HYDRA_EXTERNAL_MEMORY_DIR`-aware, matching the house convention in
   `scripts/parse-citations.sh`.
2. `scripts/hydra-recent-failures.sh [--json]` — scans the last K `logs/*.json`
   for repeated stuck / flaky / rescue patterns, grouped by `repo` + failure-type,
   emitting a compact "watch-out" block (text or JSON).
3. A spec (this file) plus a note in the PR body naming exactly where Commander's
   session greeting should call these — **without editing `CLAUDE.md`** (PR #291 owns
   that file).

## Non-goals

- **No `CLAUDE.md` edits.** The wiring point is documented in the PR body only.
- **No writes to `memory/` or `logs/`.** Both scripts are strictly read-only.
- No changes to `worker-*.md`, `README.md`, or the Memory Brief itself.
- No new state file or schema (so `validate-state-all.sh` is unaffected).
- No network, no LLM call — pure shell + `jq`, like the existing memory scripts.

## Context: learnings + logs are gitignored runtime data

`memory/learnings-*.md` and `logs/*` are **gitignored** (`.gitignore` lines 2 and 32;
only `*.example.md` and `logs/.gitkeep` are tracked). They are local runtime data
that accumulate in an operator's working tree, not committed fixtures. Two
consequences:

- The scripts read these paths at **runtime** against whatever the operator's tree
  holds; they must degrade gracefully when the dir is empty (a fresh checkout has
  zero learnings / zero logs — that is the *normal* first-run state, not an error).
- The self-test cannot rely on committed fixtures; it builds **synthetic tmp dirs**
  and points the scripts at them via `--memory-dir` / `--logs-dir`.

## Proposed approach

### `hydra-memory-search.sh`

Mirror `scripts/parse-citations.sh`'s CLI conventions: `set -euo pipefail`, a
`usage()` heredoc, `--memory-dir` override defaulting to
`${HYDRA_EXTERNAL_MEMORY_DIR:-./memory}`, `-h/--help`, exit 2 on usage error.

- Positional `<query>` is required (space-joined if multiple words).
- For each `learnings-*.md` under the resolved memory dir, count case-insensitive
  matches of the query across the file, and collect up to a few matching line
  snippets per file.
- Rank files by match count desc, cap at `--limit` (default 5). Files with zero
  matches are excluded.
- Default output: compact text — `<repo>  (N matches)` headers + indented snippets.
  `--json`: a `{query, limit, memory_dir, results:[{file, repo, matches, snippets}]}`
  object so Commander (or a future tick) can consume it programmatically.
- Empty memory dir or zero matches → exit 0 with an empty result set (a
  no-learnings session is normal, not an error — same lenience as `parse-citations`).

Repo name is derived from the filename: `learnings-<repo>.md` → `<repo>`.

### `hydra-recent-failures.sh`

The `logs/*.json` schema is **heterogeneous** (the key inventory spans 100+ distinct
keys across the log corpus; `.result` is null in the majority of files). So failure
detection must be signal-tolerant rather than assume one field:

A log is counted as a failure observation if ANY of these hold:
- `.result` matches `stuck|flaky|rescue|fail|stop|timeout|error` (case-insensitive),
- a `.rescued`, `.rescue_commit`, `.resumed_from_rescue`, or `.rescue_resumed_from`
  key is present / truthy,
- `.bug_class` / `.is_bug` is truthy,
- the rendered JSON text contains the tokens `commander-stuck`, `flaky-tool-retry`,
  `rescue-worker`, or `commander-rescued` (covers surprises/status free-text).

The derived **failure-type** is the first signal that matched, normalized to one of
`stuck | flaky | rescue | bug | other`. Group by `(repo, failure-type)`; a group with
`count >= threshold` (default 2, `--min`) is "repeated" and surfaced.

- `--last K` (default 20) — only consider the K most recently modified log files.
- `--logs-dir <path>` override (default `./logs`), for testability and external dirs.
- `--json` — `{scanned, window, threshold, patterns:[{repo, failure_type, count,
  tickets:[...]}]}`. Default text: one "WATCH" line per repeated pattern.
- No logs / no failures → exit 0, empty patterns (clean is normal).

`repo` falls back to `"unknown"` when the log omits it.

### Wiring point (documented, not implemented here)

Commander's session greeting in `CLAUDE.md` § "Session greeting" already appends
three health one-liners. The intended call site is a fourth optional block there:
after the connector/size/promotion one-liners, run
`scripts/hydra-recent-failures.sh --json` and, if `patterns` is non-empty, render a
"Recent failure patterns" line; `hydra-memory-search.sh` is invoked on demand when
Commander is about to spawn on a repo (feeding the Memory Brief). The actual edit is
deferred to the owner of `CLAUDE.md` (#291).

## Test plan

A standalone self-test, `self-test/test-session-preamble.sh`, that:

1. Runs both scripts with `--help` (exit 0, prints usage).
2. Builds a tmp memory dir with synthetic `learnings-foo.md` / `learnings-bar.md`
   and asserts `hydra-memory-search.sh "<term>" --memory-dir <tmp> --json` ranks the
   file with more matches first and that `--json` is valid JSON.
3. Asserts a non-matching query yields an empty result set + exit 0.
4. Builds a tmp logs dir with synthetic failing + clean logs and asserts
   `hydra-recent-failures.sh --logs-dir <tmp> --json` finds the repeated
   `(repo, failure-type)` group above threshold and excludes the clean repo.
5. Asserts an empty logs dir yields empty patterns + exit 0.
6. `bash -n` on both scripts.

Plus: `bash -n` on each script, and `scripts/validate-state-all.sh` exits 0
(no state touched).

## Risks / rollback

- **Low risk.** Two new additive read-only scripts + one spec + one self-test. No
  existing file is modified, no state/schema changes, no `CLAUDE.md` edit.
- **Schema drift in logs** is the main fragility — mitigated by the multi-signal
  detector above (never assumes a single field) and the `"unknown"` repo fallback.
- **Rollback:** delete the two scripts + the self-test + this spec. Nothing else
  depends on them until the `CLAUDE.md` wiring lands separately.
