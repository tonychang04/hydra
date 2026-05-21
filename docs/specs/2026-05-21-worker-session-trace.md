---
status: draft
date: 2026-05-21
author: hydra worker (ticket #197)
---

# Full-session worker trace (replayable run record)

## Problem

Today the only durable record a worker leaves is `logs/<ticket>.json` — an
**outcome-level** summary written once, at the end, per
`.claude/agents/worker-implementation.md:66` ("Append to
`$COMMANDER_ROOT/logs/<num>.json`: ticket, PR URL, tier, files changed, tests
run + results, wall-clock minutes, any surprises"). It says *what happened* but
not *how the worker got there*.

When the watchdog rescues a stalled worker (`scripts/rescue-worker.sh`, ticket
#45) or a worker hits `commander-stuck`, the operator has almost nothing to
debug from: there is no causal chain of tool calls, no record of which test ran
and failed, no timeline of where the worker spent its budget. The
agent-observability consensus (cited in the ticket) is that **failures live in
multi-step causal chains, so full-session trace capture is required** to debug
them after the fact.

Traces are also a feeder for two other P1/P3 features that are explicitly **out
of scope here** but motivate the format:

- **Cost attribution** (#195) — needs per-span `gen_ai.usage.*_tokens`.
- **Watchdog enrichment** (#206) — `rescue-worker.sh` will read the last few
  trace events to decide rescue vs. relay, instead of only inspecting git
  state.

This ticket builds the **substrate** (format + one working capture path + an
analysis helper + a fixture + a test). It does **not** build the consumers.

## Goals

1. A per-worker, append-only trace at `logs/traces/<ticket>.jsonl` — one JSON
   object per line, one line per event ("span event").
2. A standards-aligned vocabulary: OpenTelemetry **GenAI semantic-convention**
   attribute names (`gen_ai.operation.name`, `gen_ai.usage.input_tokens`,
   `gen_ai.tool.name`, `error.type`, …) so the format is recognizable and the
   future consumers (#195/#206) and any external OTel tooling can read it.
3. A span hierarchy: a root `invoke_agent` span per worker run, with child
   `execute_tool` / `chat` spans, linked by `span_id` / `parent_span_id`.
4. A lightweight append mechanism that fits Hydra: bash + jq, **no daemon, no
   Docker, no collector backend**.
5. A jq-based analysis helper in `scripts/` (span durations, error filter,
   tool-call sequence).
6. Content safety: metadata + tool/test events captured by default;
   prompt/completion **content** capture gated behind an explicit opt-in flag
   (OTel marks message content sensitive; Hydra's secrets hard-rail forbids
   leaking prompts/keys into committed-or-shared artifacts by default).

## Non-goals

- Building the cost-attribution consumer (#195) or the watchdog trace-reader
  (#206). We only define the format they will consume and ship one example.
- Auto-wiring every worker subagent to emit traces. We ship the helper + the
  format + ONE documented emit path (the implementation worker's tool/test
  events) as a vertical slice. Broad rollout across all six worker types is a
  follow-up.
- A trace viewer / UI / replay tool. jq queries are the v1 read path.
- Shipping a real OTel SDK or OTLP exporter. We borrow OTel's *attribute
  vocabulary*, not its transport.
- Sampling, rotation, retention policy. Traces are gitignored runtime under
  `logs/` and share that directory's lifecycle.

## Survey (current state, cited)

- **Outcome log** is written by the worker per `.claude/agents/worker-implementation.md:66`.
  It is JSON (one object), keyed by ticket number, under `logs/<num>.json`.
- **`logs/` is already gitignored runtime**: `.gitignore` has `logs/*` with a
  single `!logs/.gitkeep` exception. So `logs/traces/` is gitignored
  automatically — no `.gitignore` change is needed, and traces never get
  committed. The committed test fixture therefore lives under
  `self-test/fixtures/`, not `logs/`.
- **Watchdog consumer** is `scripts/rescue-worker.sh` (539 lines). Its `--probe`
  mode (`scripts/rescue-worker.sh:11`) returns JSON verdicts from git state
  today; #206 will let it also read the tail of `logs/traces/<ticket>.jsonl`.
- **Script conventions** (followed here): `scripts/parse-citations.sh` is the
  model jq-based, stdin-or-file, `set -euo pipefail`, `--help`/usage,
  documented-exit-codes shape. `scripts/state-put.sh` is the model for an
  atomic-append helper.
- **Test conventions**: `scripts/test-promote-citations.sh` is the model —
  plain bash, `say/ok/bad` helpers, pass/fail counter, `mktemp` fixtures, no
  external harness. CI runs `bash -n` on every `scripts/*.sh`
  (`.github/workflows/scripts/syntax-check.sh`) and frontmatter-checks every
  `docs/specs/*.md` (status + date required).
- **Self-test wiring**: `self-test/run.sh` runs `kind:"script"` cases from
  `golden-cases.json` (gitignored; only `golden-cases.example.json` is
  committed). A fixture driver like `self-test/fixtures/rescue-worker/run.sh`
  is the pattern for a committed, offline, self-contained check.

## Trace format

`logs/traces/<ticket>.jsonl` — newline-delimited JSON. One object per line =
one event. The minimum required fields:

```json
{
  "ts": "2026-05-21T18:30:00.123Z",
  "span_id": "01J...",
  "parent_span_id": "01H...",
  "kind": "execute_tool",
  "attrs": { "gen_ai.tool.name": "Bash", "...": "..." }
}
```

Field contract:

| field            | required | meaning |
|------------------|----------|---------|
| `ts`             | yes      | ISO-8601 UTC, millisecond precision. Event time. |
| `span_id`        | yes      | Opaque unique id for this span. |
| `parent_span_id` | no       | Parent span's id; absent/null on the root span. |
| `kind`           | yes      | `invoke_agent` (root) \| `execute_tool` \| `chat`. |
| `attrs`          | yes      | Object of OTel GenAI attribute name → value. |

`kind` mirrors OTel GenAI `gen_ai.operation.name`, and the helper always copies
it into `attrs["gen_ai.operation.name"]` too, so OTel-aware readers and Hydra's
own jq queries both work.

### Span lifecycle: one event or two?

A span that has a duration (a tool call, the whole agent run) emits **two**
events sharing one `span_id`: a `*.start` and a `*.end`. The analysis helper
pairs them by `span_id` to compute duration. Instantaneous events (e.g. a
single `chat` turn we only log once) may emit a single event. This keeps the
file append-only (we never rewrite a line to add an end time) and lets a crashed
worker leave a half-open span that the analyzer reports as `incomplete` rather
than silently dropping.

We record start/end via a `phase` attribute in `attrs`
(`attrs.phase = "start" | "end"`), not a new top-level field, so the five
top-level keys above stay stable for #206's tail-reader.

### Attribute vocabulary (OTel GenAI)

Default-captured (always safe — metadata only):

- `gen_ai.operation.name` — `invoke_agent` / `execute_tool` / `chat`.
- `gen_ai.tool.name` — for `execute_tool`, the tool (e.g. `Bash`, `Edit`).
- `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` — when known.
- `error.type` — set on a span that ended in error (e.g. `test_failed`,
  `tool_error`); absent on success.
- `hydra.ticket`, `hydra.worker_type` — Hydra-namespaced run context.
- `hydra.tool.exit_code`, `hydra.test.name`, `hydra.test.result` — Hydra
  extensions for the tool/test events that are this slice's emit path.

Opt-in only (sensitive, behind `--with-content` / `HYDRA_TRACE_CONTENT=1`):

- `gen_ai.prompt`, `gen_ai.completion` — raw prompt / completion text. OTel
  flags message content as sensitive; Hydra's secrets hard-rail means we never
  write these unless the operator explicitly opts in for a debug session.

## Proposed approach

### Capture mechanism — the key design call

**Decision: an active emit helper, `scripts/trace-append.sh`. NOT post-hoc
extraction.**

Two options were considered:

1. **Post-hoc extraction** from the worker's transcript/log after the run.
   *Rejected.* Hydra workers do not persist a machine-readable transcript inside
   the worktree that Commander can re-parse — the "transcript" is the live Claude
   Agent SDK stream, not a file artifact. There is nothing on disk to extract
   from after the fact, so this option cannot be built without first inventing a
   transcript-dump mechanism (a much bigger change). It would also lose true
   span timing (you'd be guessing start/end from text ordering) and could only
   ever reconstruct what the model happened to narrate.

2. **Active append helper** (chosen). The worker calls
   `scripts/trace-append.sh` at known points (tool start/end, test run) to
   append one event line. This is the lightest mechanism that actually fits
   Hydra: pure bash + jq, no daemon, no backend, mirrors the existing
   `state-put.sh` / `parse-citations.sh` shape. It records real timing because
   the worker calls it exactly when an event happens. It degrades safely — if a
   worker never calls it, you get an empty/short trace, never a crash. And it's
   the only option that needs no new transcript infrastructure.

The append is atomic: the helper builds the line with jq (guaranteeing valid
JSON), then `>>`-appends a single line. JSONL append is naturally safe for the
single-writer-per-file case (one worker owns one ticket's trace file). The
helper auto-creates `logs/traces/` on first call.

### Components / file structure

- **Create `scripts/trace-append.sh`** — append one event to
  `logs/traces/<ticket>.jsonl`.
  - Flags: `--ticket <n>` (required), `--kind <invoke_agent|execute_tool|chat>`
    (required), `--span-id <id>` (default: generated), `--parent-span-id <id>`,
    `--phase <start|end>` (default: emit a single event with no phase),
    `--attr k=v` (repeatable), `--with-content` (allow `gen_ai.prompt`/
    `gen_ai.completion` attrs; otherwise they are dropped with a warning),
    `--trace-dir <path>` (default `$HYDRA_TRACE_DIR` → `./logs/traces`).
  - Generates `ts` as ISO-8601 UTC ms, generates a `span_id` if absent, copies
    `kind`→`attrs["gen_ai.operation.name"]`, builds the object with jq, appends
    one line. Prints the `span_id` on stdout (so a caller can capture it to pass
    as `--parent-span-id` / to pair start/end).
  - Exit codes: `0` ok; `2` usage error.

- **Create `scripts/trace-analyze.sh`** — jq-based read/analysis over a
  `<ticket>.jsonl`.
  - Subcommands: `durations` (pair start/end by span_id → ms; mark
    `incomplete` for unpaired starts), `errors` (lines whose
    `attrs."error.type"` is set), `tools` (ordered `gen_ai.tool.name`
    sequence), `summary` (counts: spans, tools, errors, total wall span).
  - Input: a file arg or stdin. Output: human-readable lines by default,
    `--json` for machine output. `set -euo pipefail`, `--help`, exit `0`/`2`.

- **Create `self-test/fixtures/worker-session-trace/`**:
  - `sample-trace.jsonl` — a committed, realistic fixture: an `invoke_agent`
    root, two `execute_tool` spans (one Bash that succeeds, one that fails with
    `error.type=tool_error`), and a `chat` span with token usage.
  - `run.sh` — offline driver: runs `trace-append.sh` into a tmp dir and
    asserts the line is valid JSON with the required keys; runs each
    `trace-analyze.sh` subcommand against `sample-trace.jsonl` and asserts the
    expected durations / error count / tool sequence; asserts `--with-content`
    gating drops `gen_ai.prompt` by default and keeps it when opted in.

- **Create `scripts/test-trace.sh`** — the standalone bash test (matches
  `scripts/test-promote-citations.sh` style) that the fixture `run.sh` can call
  / that a developer runs directly. (We provide both: a `scripts/test-*.sh` for
  local dev parity with sibling scripts, and the `self-test/fixtures/.../run.sh`
  for golden-case wiring. The fixture `run.sh` delegates to the test script to
  stay DRY.)

- **Modify `scripts/README.md`** — one row each for `trace-append.sh` and
  `trace-analyze.sh` under the existing script table.

- **Documented emit path (the vertical slice)**: the spec documents where the
  implementation worker *would* call `trace-append.sh` (tool start/end + test
  run). We do **not** edit `.claude/agents/worker-implementation.md` in this
  ticket beyond what's needed; CLAUDE.md is explicitly not edited (a pointer to
  this spec is noted in the PR for a later wiring ticket). The "working example"
  required by the ticket is the fixture + the test that exercises the real
  scripts end to end.

### Data flow

```
worker  --(trace-append.sh --kind execute_tool --phase start ...)-->  logs/traces/<t>.jsonl
worker  --(... --phase end --attr error.type=tool_error ...)------->  logs/traces/<t>.jsonl
operator/#206  --(trace-analyze.sh durations|errors|tools <t>.jsonl)--> human/JSON report
```

### Error handling

- `trace-append.sh` with a missing required flag → exit 2, usage to stderr,
  nothing written.
- Sensitive attr (`gen_ai.prompt`/`gen_ai.completion`) supplied without
  `--with-content` → the attr is dropped, a one-line warning goes to stderr, the
  event is still written (we never fail a worker's run because it tried to log a
  prompt). With `--with-content` the attr is kept verbatim.
- `trace-analyze.sh` on a missing file → exit 2 with a clear message.
- `trace-analyze.sh` on a half-open span (start with no matching end) →
  reported as `incomplete`, never a crash.
- jq absent → both scripts fail fast with a clear "jq required" message
  (consistent with sibling scripts).

## Test plan

All offline, bash + jq, no network/docker (CI-safe):

1. **append: valid line** — `trace-append.sh --ticket 197 --kind execute_tool
   --attr gen_ai.tool.name=Bash` writes exactly one line; `jq empty` parses it;
   the five required keys are present; `attrs."gen_ai.operation.name" ==
   "execute_tool"`.
2. **append: span_id echoed + reused** — stdout span_id can be fed back as
   `--parent-span-id`; a start+end pair shares one `span_id`.
3. **append: content gating** — `--attr gen_ai.prompt=secret` WITHOUT
   `--with-content` ⇒ no `gen_ai.prompt` in output + stderr warning; WITH
   `--with-content` ⇒ `gen_ai.prompt` present.
4. **append: usage error** — missing `--kind` ⇒ exit 2, no file written.
5. **analyze durations** — against `sample-trace.jsonl`, the succeeding Bash
   span reports its ms duration; the half-open span (if any) reports
   `incomplete`.
6. **analyze errors** — exactly the one span with `error.type=tool_error` is
   listed.
7. **analyze tools** — tool sequence equals the fixture's tool order.
8. **analyze summary --json** — counts match (spans/tools/errors).
9. **analyze: missing file** — exit 2.
10. **`bash -n`** on both new scripts passes (also enforced by CI syntax-check).

The fixture `run.sh` runs checks 1–9; check 10 is CI. Output is pasted into the
PR per the operator's "test for real" standing requirement.

## Risks / rollback

- **Risk: traces grow unbounded.** Mitigated by living under `logs/` (already
  gitignored runtime, never committed; shares whatever cleanup `logs/` gets).
  Rotation/retention is a deliberate non-goal for v1.
- **Risk: a worker writes a secret into a trace.** Mitigated by default-off
  content capture + the drop-and-warn gate. The hard-rail (never write `.env*`/
  secrets) still applies; this just adds belt-and-suspenders for prompt text.
- **Risk: concurrent writers corrupt a file.** Not applicable in v1 — one worker
  owns one ticket's trace file (single writer). If shared-file writing is ever
  needed, switch to the `state-put.sh` lock pattern.
- **Risk: scope creep into the consumers.** Explicitly fenced: #195 and #206
  consume this format and are separate tickets. If wiring the emit path into the
  live worker turns out to be more than a vertical slice, STOP after the spec +
  substrate + fixture and report (per the ticket's escape hatch).
- **Rollback:** the feature is purely additive — two new scripts, a fixture, a
  test, a README row, and this spec. Nothing existing changes behavior. Delete
  the files to roll back; no migration, no state change.

## Out of scope (tracked elsewhere)

- Cost attribution consumer — #195.
- Watchdog trace-reader (`rescue-worker.sh` reads trace tail) — #206.
- Wiring every worker subagent (all six types) to emit — follow-up.
- A trace viewer / replay UI — future.
- CLAUDE.md pointer to wire the emit path into worker agents — noted in the PR
  for a later ticket (this ticket does not edit CLAUDE.md).
