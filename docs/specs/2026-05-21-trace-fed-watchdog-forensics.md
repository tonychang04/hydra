---
status: draft
date: 2026-05-21
author: hydra worker (ticket #206)
---

# Trace-fed watchdog forensics: rescue-worker --probe reads the last trace span

## Problem

The worker timeout watchdog (`scripts/rescue-worker.sh`, ticket #45) decides
rescue-vs-relay from two surfaces: worktree git state (`--probe`, ticket #45) and
a worker-authored flaky-tool marker (`--probe`'s `flaky-tool-retry` verdict,
ticket #190). Neither tells the watchdog **what the worker was actually doing
when it went silent**.

That gap drives the watchdog's worst failure mode: a worker that is **alive but
slow** — sitting inside one long-running tool call (a big `npm test`, a `docker
compose up`, a slow `gh` round-trip) — looks identical, from git state alone, to
an **idle ghost**. Both have a clean (or stale-dirty) worktree and no new
commits. The watchdog returns `nothing-to-rescue`, commander labels the ticket
`commander-stuck`, and a live, recoverable worker is killed mid-tool-call. The
symmetric error also exists: a worker stuck in a **retry loop** — calling the
same tool over and over, or hitting the same error repeatedly — is genuinely
unrecoverable and *should* be restarted, but git state can't distinguish it from
a worker making slow forward progress.

#197 landed the substrate that closes this gap: a per-worker append-only trace at
`logs/traces/<ticket>.jsonl` (one JSON span event per line, OTel GenAI
vocabulary). The trace records exactly what git state cannot — the live timeline
of tool calls, with `phase:start`/`phase:end` pairing per `span_id` and
`error.type` on failed spans. The #197 spec explicitly fences this consumer as
out of scope for #197 and names #206 as the watchdog reader:
"`rescue-worker.sh` will read the last few trace events to decide rescue vs.
relay, instead of only inspecting git state."

This ticket builds that reader: `--probe` reads the **tail** of the worker's
trace and emits a sharper verdict distinguishing three states the watchdog
currently conflates.

## Goals

1. Add two new `--probe` verdicts derived from the trace tail:
   - `worker-mid-tool-call` — the most recent `execute_tool` span is **open**
     (a `phase:start` with no matching `phase:end` in the tail). The worker is
     ALIVE inside a long-running tool. Do **not** rescue/restart; the tool is
     just slow. Exit code **6**.
   - `worker-looping` — the trace tail shows a **repeated identical span pattern
     or recursive failures** (the last K `execute_tool` starts are the same tool
     across distinct spans, or ≥K spans in the tail carry the same `error.type`).
     The worker is stuck in a loop and is unrecoverable in place — rescue and
     restart. Exit code **7**.
2. When the trace shows neither (the last span is a clean `end`, the trace is
   empty, missing, or inconclusive), fall through to the **existing** git-state
   verdicts (`rescue-uncommitted` / `rescue-commits` / `push-only` /
   `nothing-to-rescue`) **byte-for-byte unchanged**. No trace ⇒ identical
   behavior to today. This is the key safety property, mirroring #190's gating.
3. Carry forensic context in the new verdict JSON so commander can act and an
   operator can debug: the open tool's name (mid-tool-call), the looping tool
   name and/or repeated `error.type` and the repeat count (looping), plus the
   worktree git-state (`commits_ahead`, `dirty`) for observability.
4. Keep the existing flaky-tool-retry verdict (#190, exit 5) and its precedence
   intact: a live worker that left a flaky-tool marker is still
   `flaky-tool-retry` (most-specific, carries an actionable fallback). Trace
   analysis runs **after** the flaky-tool check, **before** git-state verdicts.
5. Document commander's response to each new verdict and extend the offline
   self-test fixture (`self-test/fixtures/rescue-worker/run.sh`) with a trace
   case for each state plus regression that no-trace behavior is unchanged.

## Non-goals

- **Modifying `scripts/trace-analyze.sh` or `scripts/trace-append.sh`.** #195 may
  extend `trace-analyze.sh`; this ticket only *reads* the trace format. The
  tail-read is a small self-contained jq program inside `rescue-worker.sh`, not a
  call out to `trace-analyze.sh` (which slurps the *whole* file and has no
  tail/open-span/loop semantics). Reusing it would mean either changing it
  (forbidden here) or reading the entire trace (wasteful, and the watchdog only
  needs the tail).
- **Auto-wiring workers to emit traces.** #197 shipped one vertical-slice emit
  path and fenced broad rollout as a follow-up. This ticket consumes whatever
  trace exists; an empty/absent trace falls through safely.
- **A retry/escalation state machine.** As with #190, this PR gives commander the
  signal; the documented procedure handles repeats (a second `worker-looping`, or
  a `worker-mid-tool-call` that never resolves, falls through to the normal
  rescue/stuck path). No new state file.
- **Changing `--rescue`, `--probe-review`, or the 12-min watchdog threshold.**
  Untouched.
- **Mutating the worktree from `--probe`.** Probe stays read-only. Commander's
  response to mid-tool-call is "wait one more tick" (a no-op rescue); to
  worker-looping is `--rescue` then respawn.

## Survey (current state, cited)

- **Probe modes & verdicts** — `scripts/rescue-worker.sh:11-28` documents the
  four git-state verdicts; `:281-347` (`flaky_tool_verdict`) is the model for a
  fully-defensive, gated, JSON-emitting probe helper that returns 0 only when its
  signal is valid and recent, else prints nothing and returns 1 so probe falls
  through. The flaky check is invoked first inside `--probe` at `:368-376`.
- **Exit codes** — `scripts/rescue-worker.sh:55-65`: 0 success, 1 I/O, 2 usage,
  3 rescue-conflict, 4 review-rescue, 5 flaky-tool-retry. New codes 6 and 7 are
  the next free integers and are orthogonal.
- **Trace format** — `docs/specs/2026-05-21-worker-session-trace.md:97-138`: five
  stable top-level keys (`ts`, `span_id`, `parent_span_id`, `kind`, `attrs`);
  duration spans emit `attrs.phase:"start"` then `attrs.phase:"end"` sharing one
  `span_id`; `attrs."gen_ai.tool.name"` names the tool; `attrs."error.type"` is
  set on failed spans. The spec names #206 as "the tail-reader" (`:81`, `:138`).
- **Sample trace** — `self-test/fixtures/worker-session-trace/sample-trace.jsonl`
  shows the exact shape, including a half-open final tool span (line 9: a `Bash`
  start with no end) — i.e. a real "mid-tool-call" tail.
- **Fixture conventions** — `self-test/fixtures/rescue-worker/run.sh`: a
  throwaway git repo via `mktemp`, `--base refs/heads/main` (no remote needed),
  per-case numbered steps with explicit exit-code + stdout asserts, a final
  `--help` contract check, `echo "PASS: ..."` at the end. The #190 block
  (`:264-419`) is the model for adding a new gated-signal feature to this fixture.
- **gitignore** — `.gitignore:30-31` gitignores `logs/*` (keeping only
  `.gitkeep`), so real traces never commit. The fixture writes its trace into the
  `mktemp` worktree (under a `--trace-dir`-style path the probe is told to read),
  never under `logs/`.

## Trace format read by the probe

The probe reads the **tail** of `logs/traces/<ticket>.jsonl` (default last 20
lines — enough to see the last several spans, cheap to read). The trace file
location resolves as:

1. `--trace-file <path>` if passed (used by the fixture to point at a `mktemp`
   trace; also lets an operator probe an arbitrary trace).
2. else `$HYDRA_TRACE_DIR/<ticket>.jsonl` if `HYDRA_TRACE_DIR` is set.
3. else `<worktree>/logs/traces/<ticket>.jsonl` (the conventional location
   relative to the repo the worker runs in).

If no trace file is found at the resolved path, the trace branch is skipped
entirely and `--probe` behaves exactly as today.

### State detection (over the tail, defensive jq)

Let `T` = the parsed array of valid JSON objects from the tail (malformed lines
are dropped, never fatal). Tuning knobs (env vars, documented in `--help`):

- `HYDRA_TRACE_TAIL_LINES` — how many trailing lines to read (default 20).
- `HYDRA_TRACE_LOOP_MIN` — K, the minimum repeat count for the looping verdict
  (default 3).

**mid-tool-call** (exit 6): take the `execute_tool` events in `T`. Group by
`span_id`. The *most recent* `execute_tool` span (latest `start` ts) has a
`phase:"start"` event but **no** `phase:"end"` event ⇒ that tool call is still
open ⇒ worker is alive mid-tool-call. The verdict carries that span's
`gen_ai.tool.name` (the tool the worker is blocked inside).

**worker-looping** (exit 7): two independent loop signals, either fires:
- *Tool-repeat:* among the last K `execute_tool` `phase:"start"` events (ordered
  by ts), all share the same `gen_ai.tool.name` across **≥2 distinct span_ids**
  (genuinely repeated calls, not one long-open span — the latter is
  mid-tool-call, not looping).
- *Recursive-failure:* ≥K events in `T` carry the same `attrs."error.type"`
  value (the worker keeps hitting the same error).
The verdict carries the looping `tool` (if tool-repeat) and/or `error_type` (if
recursive-failure) and the observed `repeat` count.

**Precedence between the two trace verdicts:** worker-looping is checked
**before** mid-tool-call. Rationale: a loop of repeated tool calls will often
*end* with one more open call (the in-flight retry). If we checked mid-tool-call
first we'd report "alive, just slow" for a worker that is actually thrashing.
Looping is the more actionable (and more dangerous) signal, so it wins. A single
open tool call with no repeats is mid-tool-call.

**idle / inconclusive:** neither signal fires (e.g. the tail's last span is a
clean `end`, or there are no tool spans) ⇒ print nothing, return 1, fall through
to the git-state verdicts unchanged.

### Verdict JSON shapes

```json
{"verdict":"worker-looping","tool":"Bash","error_type":null,"repeat":3,"commits_ahead":N,"dirty":true|false}
{"verdict":"worker-mid-tool-call","tool":"Bash","commits_ahead":N,"dirty":true|false}
```

(`tool` or `error_type` may be `null` when only the other loop signal fired.)

## Proposed approach

Add one helper, `trace_forensic_verdict`, to `rescue-worker.sh`, modeled exactly
on the existing `flaky_tool_verdict`:

- Fully defensive: missing file, no jq, all-malformed tail, no tool spans ⇒
  print nothing, return 1 (fall through). A garbled trace must never break the
  watchdog (same hard requirement #190 placed on the flaky marker).
- Read the tail with `tail -n "$tail_lines"`, slurp valid objects with
  `jq -R 'fromjson? // empty' | jq -s '.'` (the `fromjson?` form drops malformed
  lines without aborting).
- Run two small jq programs over the slurped array (loop check, then open-span
  check) and emit the verdict JSON via `jq -nc` (safe escaping), reporting
  worktree git-state alongside for observability.
- Return 0 (caller exits 7) for looping, 0 (caller exits 6) for mid-tool-call,
  1 otherwise. Because two different exit codes are needed, the helper prints the
  verdict and echoes a sentinel exit-code on a side channel; simplest: the helper
  prints the verdict JSON to stdout and the desired exit code (6 or 7) as its
  return-value-by-stdout is avoided — instead the helper writes the verdict to a
  variable and the `--probe` block decides the exit code from the verdict string
  (`worker-looping` → 7, `worker-mid-tool-call` → 6). This keeps the helper a
  pure "print verdict or nothing" function like `flaky_tool_verdict`.

Wire into `--probe` between the flaky-tool check and the git-state verdicts:

```
--probe:
  flaky_tool_verdict        && exit 5      # #190 (alive, fallback) — most specific
  v=$(trace_forensic_verdict)              # #206 (this ticket)
    if v == worker-looping     → print v; exit 7
    if v == worker-mid-tool-call → print v; exit 6
  ...existing dirty/commits/pushed verdicts unchanged...
```

### Commander's response (documented procedure)

- **exit 6 `worker-mid-tool-call`:** the worker is alive inside a slow tool. Do
  NOT rescue. Wait one more watchdog tick. If the *same* span is still open on the
  next probe (still mid-tool-call, same tool, no new commits), treat it as a hung
  tool and fall through to the normal rescue path. Label `commander-mid-tool-call`
  for observability (P1 pillar).
- **exit 7 `worker-looping`:** the worker is thrashing and won't self-recover.
  Run `--rescue` (commit + rebase + push any partial work), then respawn a fresh
  worker with a "resume from rescue — previous run looped on `<tool>`/`<error>`"
  hint so the new worker avoids the same loop. Label `commander-looping`.
- A second consecutive `worker-looping` from the same ticket, or a
  `worker-mid-tool-call` that never resolves, falls through to the existing
  rescue / `commander-stuck` path. No infinite loop; the watchdog degrades to
  current behavior.

### Alternatives considered

- **A — call `scripts/trace-analyze.sh` instead of an inline jq read.** Rejected:
  the ticket forbids modifying `trace-analyze.sh` (#195 owns it), and its
  subcommands slurp the *whole* file with no tail / open-span / loop semantics.
  The watchdog needs only the tail and needs new semantics, so an inline,
  self-contained helper (mirroring `flaky_tool_verdict`) is the right blast
  radius. The format coupling is to the *trace schema* (stable five top-level
  keys, per the #197 spec), not to that script.
- **B — a single combined "worker-alive" verdict.** Rejected: mid-tool-call and
  looping demand *opposite* commander responses (wait vs. rescue-and-restart).
  Collapsing them would re-introduce the conflation this ticket exists to remove.
- **C — separate `--probe-trace` subcommand (symmetric with `--probe-review`).**
  Rejected for the same reason #190 folded flaky-tool into `--probe`: trace
  analysis inspects the *same surface* `--probe` already does (the worker's
  worktree/run) with the *same positional args*. Commander makes one probe call
  and gets back whichever verdict applies.
- **D — derive "alive" from worktree/file mtime instead of the trace.** Rejected:
  mtime can't tell *which* tool is open or *whether* the worker is looping vs.
  progressing, and would false-fire on slow editing. The trace records exactly
  this; that's why #197 built it.

## Test plan

All assertions extend the existing offline fixture
`self-test/fixtures/rescue-worker/run.sh` (no network, no `gh`, no live daemon),
run by the `worker-timeout-watchdog-script` golden case. Each trace case writes a
small JSONL trace into a `mktemp` worktree and probes it with `--trace-file`.

**New verdicts:**

1. **mid-tool-call** — trace tail ends with an `execute_tool` `phase:start` (tool
   `Bash`) and no matching `end` ⇒ `--probe` emits
   `"verdict":"worker-mid-tool-call"`, `"tool":"Bash"`, exits **6**.
2. **looping (tool-repeat)** — trace tail has K=3 `execute_tool` starts, all tool
   `Bash`, distinct span_ids, each paired with an `end` ⇒
   `"verdict":"worker-looping"`, `"tool":"Bash"`, `"repeat":3` (or ≥3), exits
   **7**.
3. **looping (recursive-failure)** — trace tail has ≥3 spans carrying
   `error.type:"tool_error"` ⇒ `"verdict":"worker-looping"`,
   `"error_type":"tool_error"`, exits **7**.
4. **looping wins over a trailing open span** — a 3× repeat of `Bash` followed by
   one more open `Bash` start ⇒ `worker-looping` (exit 7), NOT mid-tool-call
   (proves looping precedence).

**Gating / no-false-fire (fall through to git-state verdicts):**

5. **clean completed trace** — tail ends with a clean `invoke_agent`/tool `end`,
   no open span, no repeats ⇒ falls through; on a clean branch with no other
   signal that's `nothing-to-rescue` (exit 0), NOT a trace verdict.
6. **no trace file** — `--probe` with no `--trace-file` and no trace at the
   default path ⇒ existing verdicts unchanged (regression: clean →
   `nothing-to-rescue`, dirty → `rescue-uncommitted`).
7. **malformed trace** — a trace whose tail is garbage / partial JSON ⇒ falls
   through, no crash (exit 0 on a clean branch).
8. **single non-repeated tool call (one closed span)** — one `Bash` start+end and
   nothing else ⇒ neither looping nor mid-tool-call ⇒ falls through.

**Precedence:**

9. **flaky-tool marker beats trace** — a worktree with BOTH a valid flaky-tool
   marker AND a looping trace ⇒ `flaky-tool-retry` (exit 5) still wins (the
   flaky marker is the most specific, actionable signal). Proves trace analysis
   runs *after* the flaky check.

**Contract:**

10. `scripts/rescue-worker.sh --help` documents `worker-mid-tool-call`,
    `worker-looping`, and exit codes 6 and 7.
11. `bash -n scripts/rescue-worker.sh` passes (CI `syntax` job).

Output is pasted into the PR per the operator's "test for real" standing
requirement.

## Risks / rollback

- **Risk: a malformed trace breaks `--probe` and jams the watchdog.** Mitigated by
  the fully-defensive helper: `jq -R 'fromjson? // empty'` drops bad lines;
  missing file / no jq / no tool spans all return 1 (fall through). Asserted by
  the malformed-trace fixture step.
- **Risk: a slow-but-progressing worker is mis-read as looping and killed.**
  Mitigated by requiring K (default 3) genuinely *distinct* repeated span_ids of
  the same tool, or K repeated identical `error.type`s. A worker making forward
  progress emits varied tool/span patterns. K is tunable
  (`HYDRA_TRACE_LOOP_MIN`).
- **Risk: a hung tool (mid-tool-call forever) never gets rescued.** Mitigated by
  the documented commander procedure: a still-open same span on the *next* tick
  falls through to the normal rescue path. The watchdog never relies on a single
  probe to keep waiting indefinitely.
- **Risk: exit codes 6/7 collide with a future code.** Mitigated by documenting
  the full set in the header + `--help` (0/1/2/3/4/5/6/7). Future codes pick the
  next free integer.
- **Risk: coupling to the trace schema.** Mitigated: the helper reads only the
  five stable top-level keys + the three documented `attrs` names
  (`phase`, `gen_ai.tool.name`, `error.type`) that the #197 spec marks stable for
  exactly this consumer. No coupling to `trace-analyze.sh` internals.
- **Rollback:** the change is additive — one new helper + two `--probe` branches +
  `--help`/header lines + fixture steps + this spec. Revert the single commit; with
  the helper removed, `--probe` returns to its five-verdict behavior and leftover
  trace files are simply unread.

## Implementation notes

(Filled in after the PR lands.)
