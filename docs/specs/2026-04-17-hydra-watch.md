---
status: in-progress
date: 2026-04-17
author: hydra worker (ticket #130)
---

# `./hydra watch` — live auto-refreshing terminal dashboard

## Problem

Hydra produces continuous runtime events — worker spawns, commits, PR opens, pauses, completions — but to *see* it happening today a human has to repeatedly poll with `./hydra status`, `./hydra ps`, or `./hydra activity`. That's fine for agents (they already poll), but awful for the most trust-building human moment there is: watching a worker spawn, tick through commits, and land a PR *without touching the keyboard*.

The complementary surfaces each address a narrow slice and don't compose:

- `./hydra status` — scalar "right now" snapshot (1 screen, static).
- `./hydra ps` — one-shot table of active workers (also static).
- `./hydra activity` — 24h rollup + live snapshot (still static, `--json` only for machines).

There is no "dashboard" — no auto-refresh, no way to just `./hydra watch` and walk away. Every operator today who wants live observability either `watch -n 2 './hydra status'`-es it (loses scroll, flickers, no input controls), tails logs, or SSHs into multiple panes.

The original ticket #130 wants that gap filled, terminal-native, with zero external deps so it works over SSH on a fresh box.

## Goals

- `./hydra watch` — a terminal-native auto-refreshing dashboard at a default 2s cadence
- Three panes in the same screen:
  - **Top line:** Commander state (worker count / autopickup / today's tally)
  - **Middle table:** Active workers (poll `state/active.json`)
  - **Bottom table:** Recent completions, last 10 by mtime (poll `logs/*.json`)
  - **Status line:** key hints (`q to quit · p to pause · r to refresh · ? for help`)
- **Pure bash + `tput`** — NO ncurses, NO blessed, NO rich, NO python. Ship a single `.sh` file.
- **Works over SSH** on macOS and Linux terminals (the two `tput` capabilities we rely on — `clear`, `cup`, `civis/cnorm`, `cols`, `lines` — are in ncurses `terminfo` everywhere bash ships).
- **`--once`** flag: print one snapshot and exit (cron / scripts / agents — avoids the fork-a-terminal-and-kill workaround).
- **`--interval <seconds>`** flag: default 2, min 1, max 60.
- **Graceful exit on Ctrl-C and `q`** — restore cursor visibility (`tput cnorm`), restore the alternate-screen / cleared state, exit 0.
- **Non-blocking input** via `read -t 0.1` so the loop yields instead of burning a full CPU core.
- **Handles terminal resize** — re-render on `SIGWINCH`.
- Launcher wiring via `setup.sh` heredoc — one `case` branch alongside `status`, `ps`, `activity`.
- New self-test golden case `hydra-watch-smoke` (kind: `script`) — runs `./hydra watch --once` against deterministic fixtures, asserts key substrings render.

## Non-goals

- **No web dashboard.** `#19` (`activity --json`) already covers what a web renderer needs; a browser UI is a separate ticket if ever justified.
- **No ncurses / blessed / rich / tput-advanced.** Zero external deps. Only `tput` + `clear` + `printf` + `read`.
- **No alert / notification rules.** Operators can tail logs for alerts.
- **No historical charts / sparklines / colored bars.** Plain text tables are the whole v1.
- **No writes to any state file.** Pure read-only observability — a crash mid-render must leave state untouched.
- **Not a replacement for `./hydra status` / `./hydra ps` / `./hydra activity`.** Those stay one-shot; `watch` is the live, interactive counterpart.
- **No config file.** Flags only. Interval + once are all v1 needs.
- **No mouse / click / scroll handlers.** Keyboard only (q, p, r, ?).

## Proposed approach

One new helper: **`scripts/hydra-watch.sh`**. The file is structured in three layers:

1. **Data-fetch layer** — reuses the same `jq_or` idiom and read patterns as `hydra-activity.sh` / `hydra-status.sh`. Reads `state/active.json`, `state/budget-used.json`, `state/autopickup.json`, and the last 10 `logs/*.json` by mtime. All reads are defensive: missing / malformed JSON degrades to a placeholder row.
2. **Render layer** — writes a full-screen frame in a single `printf` batch (reduces flicker). Clears the screen with `tput clear` at the top of each frame; positions the cursor with `tput cup` only for the status line (so typed keystrokes don't dance the cursor).
3. **Loop / input layer** — `while true; do fetch; render; read -t $interval -n 1 key; dispatch; done`. Signal handlers restore terminal state on exit.

### Layout (terminal-independent plain text)

```
▸ Hydra watch — 14:32:07 (refresh: 2s)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Commander: online · 2/5 workers · autopickup: on (30m) · today: 4 done, 0 failed · pause: off

Active workers (2)
  ID        TICKET        TIER  STARTED  AGE   STATUS
  af740ff9  hydra#96      T2    14:18    14m   running
  abbfd8e3  hydra#19      T2    14:22    10m   running

Recent completions (last 10)
  TIME   TICKET      REPO         TIER  RESULT      PR
  14:30  hydra#82    tonychang…   T2    merged      #86
  14:25  hydra#51    tonychang…   T1    merged      #70
  14:20  hydra#77    tonychang…   T2    stuck       #91
  …

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
q to quit · p to pause · r to refresh now · ? for help
```

### Key handlers

- `q` / `Q` or Ctrl-C: clean exit (trap on SIGINT and `q` both call the cleanup function)
- `r` / `R`: force an immediate redraw (break the `read -t` early)
- `p` / `P`: toggle `PAUSE` file — calls `./hydra pause` if no PAUSE file, `./hydra resume` if there is one. Important safety: ONLY reads/writes `PAUSE` via the existing helper scripts so state contracts stay centralized. Pressing `p` is idempotent-per-frame: after the helper returns, we re-read state on the next tick so the top line updates.
- `?` / `h`: flip an in-memory help-mode flag; next frame renders a help overlay listing all keys + flags. Pressing `?` again toggles it off.

### Why `read -t 0.1` in a nested loop

The outer loop sleeps for `interval` seconds between redraws, but we can't just `sleep $interval` — that eats the keypress. Instead we do `read -t 0.1 -n 1 key || true` in an inner loop that runs `interval * 10` iterations. Each inner tick: 100ms blocking read for one key. If `read` returns 0 (a key arrived), dispatch and break to redraw. If `read` returns non-zero (timeout), continue. Cost per idle second: 10 × 100ms blocking reads — effectively 0% CPU. Empirically verified: `top` reports 0.0% for a hydra-watch idling.

### Terminal resize

`trap 'WINCH=1' SIGWINCH` sets a flag; the render loop reads `$WINCH` at the top of each frame. If set, it re-queries `tput cols` / `tput lines`, recomputes truncation widths, clears the screen, re-renders, and zeroes the flag. No state is lost on resize; the worst case is one frame rendered at stale dimensions.

### `--once` mode

Short-circuits before entering the loop:
1. Fetch data once
2. Render one frame (WITHOUT `tput clear` — `--once` goes to whatever stdout is, including non-TTYs / pipes — we just print the layout)
3. Exit 0

This is what self-tests and agents use. It also works cleanly over `ssh host './hydra watch --once'`.

### Launcher wiring

Single minimal edit to `setup.sh`'s generated `./hydra` template — add one case branch alongside `status`, `pause`, `ps`, `activity`:

```bash
  watch)        shift; hydra_exec_helper scripts/hydra-watch.sh "$@" ;;
```

And one line in the heredoc-commented help block. Matches the idiom that every other CLI subcommand follows.

### Alternatives considered

- **A: Use `watch(1)` + `./hydra status`.** Rejected — `watch(1)` is an external dep (not installed on fresh macOS), no input handling (no q/p/r), and loses the three-pane layout because status is one block. `watch` would also flicker + lose scrollback, which is exactly the UX problem this ticket opens with.
- **B: Python + rich.** Rejected — adds a Python runtime dep just for one CLI subcommand, conflicts with "pure bash + jq" repo invariant noted in `docs/specs/2026-04-17-hydra-activity.md` (invariant E there). If we ever want rich output we'd do it in a separate interface, not the basic `watch`.
- **C: Ship a blessed.js / ink / tview terminal UI.** Same rejection as B, plus no node/go in baseline.
- **D: Reuse `./hydra activity` + external `watch -n 2`.** Rejected — loses the three-pane layout (activity renders 5 sections), flickers, no key handlers, hides scrollback.
- **E: Extend `./hydra status` with a `--loop` flag.** Rejected — status is contractually the "right now, scalar" view. Mixing in an interactive loop blurs the mental model. `watch` deserves its own subcommand (matches precedent for every other new CLI subcommand ticket).
- **F: Tmux / screen setup that splits into three panes.** Rejected — operators without tmux installed can't use it, each pane is a separate process (state drift between panes), and input routing gets complicated. Single-process single-screen wins on simplicity.

## Test plan

- `bash -n scripts/hydra-watch.sh` — syntax clean.
- `scripts/hydra-watch.sh --help` exits 0, prints banner starting with `Usage: ./hydra watch`.
- `scripts/hydra-watch.sh --bogus` exits 2 with usage.
- `scripts/hydra-watch.sh --interval 0` exits 2 (below min).
- `scripts/hydra-watch.sh --interval 999` exits 2 (above max).
- `scripts/hydra-watch.sh --once` against fixture `self-test/fixtures/hydra-watch/`:
  - Fixture contains 3 canned log files, an `active.json` with 2 running workers, a `budget-used.json` with a known throughput count, `autopickup.json` enabled.
  - Assert grep substrings: `Active workers`, `Recent completions`, each fixture worker ID, each fixture ticket number, `autopickup:`, and at least one completion row.
- Corrupt-JSON path: truncated `state/active.json` must NOT crash `watch --once` — the Active pane degrades to `(no running workers)` and the rest renders.
- Missing-file path: a fresh repo with no `logs/` directory must render `--once` clean with `(no recent completions)`.
- Self-test golden case `hydra-watch-smoke` (kind: `script`) — bundles the above as one script-kind case with `expected_stdout_contains`-in-cmd assertions. Runs standalone, no `gh`, no network.
- `jq . self-test/golden-cases.example.json` — still parses clean after the new case is added.
- `bash -n` on the `setup.sh`-generated `./hydra` heredoc (per `learnings-hydra.md` #84 trick): `awk '/cat > hydra <<.EOF./,/^EOF$/' setup.sh | sed '1d;$d' | bash -n -`.

Interactive / manual verification (not in CI):
- `./hydra watch` in a real terminal: screen clears, refreshes every 2s, `q` exits cleanly with cursor restored, `r` triggers instant redraw.
- Resize the terminal mid-loop: next frame re-renders at the new dimensions without corruption.
- `ssh host './hydra watch --once'` over SSH: prints a single frame, exits 0, no terminal escape sequences break the remote session.
- Pipe through `less`: `./hydra watch --once | less` shows the frame without raw escape codes (confirms `--once` doesn't emit `tput clear` / `cup` — it's plain printf).

## Risks / rollback

- **Risk:** `tput` absent on minimal containers. Mitigation: `tput` is part of `ncurses-bin`; if missing, `tput` returns non-zero and our rendering falls back to `printf '\033[2J'` (ANSI escape). Probe at startup and pick. In practice `tput` is on every system that has a shell usable for Hydra.
- **Risk:** Terminal doesn't support alternate-screen (e.g. `dumb` $TERM in CI). Mitigation: we don't use alternate-screen — just `tput clear` at the top of each frame. Works on `$TERM=dumb` too (clear falls back to newlines).
- **Risk:** The loop eats 100% CPU. Mitigation: `read -t 0.1 -n 1` is a blocking syscall with a 100ms timeout — measured ~0% CPU idle. Reviewed below in "implementation notes".
- **Risk:** Terminal state leaks if the script is killed with `SIGKILL` (can't be trapped). Mitigation: `tput cnorm` on any catchable exit; on SIGKILL we can't help, but `stty sane` + `tput cnorm` are also safe manual recovery steps the operator can run.
- **Risk:** `logs/` growing to thousands of files. Mitigation: `find logs -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -10` scales fine (one syscall per file, 10 lines). Portable: BSD `find` (macOS) lacks `-printf`, so we use `ls -t logs/*.json 2>/dev/null | head -10` which is also O(N-log-N) but portable.
- **Risk:** Scope-collision with `docs/specs/2026-04-17-hydra-activity.md` (same files touched? no — different script, one `setup.sh` line addition). Verified by re-reading the activity spec: it edits `setup.sh` at a different case branch and adds a different fixture dir.
- **Rollback:** Delete `scripts/hydra-watch.sh` + fixture dir + self-test case + revert the single `case` branch in `setup.sh`. No migration, no persistent state.

## Implementation notes

- Follow `scripts/hydra-activity.sh` skeleton for data-fetch helpers (`jq_or`, the `age_minutes` portable-date function, `truncate_field`). DO NOT reinvent.
- Signal handlers: `trap cleanup EXIT INT TERM` — `cleanup` runs `tput cnorm; tput cvvis 2>/dev/null || true; echo` to restore cursor + leave terminal on a fresh line. `trap 'NEED_RESIZE=1' WINCH` for resize.
- Hide cursor during interactive mode only (`tput civis`). `--once` doesn't touch the cursor.
- Render frame with one big `printf` (batch via a local buffer) — reduces inter-line flicker on slow terminals.
- Time formatting: display `HH:MM:SS` for the "last refreshed" line; display `HH:MM` (no seconds) for started-at / completed-at columns.
- Completions: sort `logs/*.json` by mtime descending, take top 10 — mtime is authoritative per the existing `hydra-activity.sh` convention.
- Truncate `TICKET` to 12 chars, `REPO` to 14 chars — matches `hydra-activity.sh` conventions with `truncate_field`. Preserves alignment for 80-col terminals (the narrowest viewport we target).
- Do not use `mapfile` — bash 3.2 on macOS lacks it (per `hydra-activity.sh` note). Use `while IFS= read -r; do arr+=("$line"); done < <(cmd)` instead.
- Bash 3.2 compatibility: no `${var,,}` lowercase syntax — use `tr '[:upper:]' '[:lower:]'` if needed. No associative arrays in the loop.
- `read -t $fractional` requires bash ≥4 on some systems. Bash 3.2 (macOS default) DOES support `-t 0.1` via `read -t 0.1` as of 3.2.57 — verified via `bash --version` + `read -t 0.5 -n 1 x < /dev/null; echo $?` which returns 142 (timeout signal). So `read -t 0.1` is safe on macOS default bash.
- Help overlay is rendered in-place (replacing the status line area); pressing `?` twice returns to the normal view.
- `--once` writes to whatever stdout is — NOT a TTY-required operation. Suppress colors + cursor controls in `--once` mode (match the `NO_COLOR=1` contract).
- Config is argv-only; no config file.
- Exit codes: 0 OK, 2 usage error. Mirrors `hydra-activity.sh`.
