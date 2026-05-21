---
status: draft
date: 2026-05-21
author: hydra worker (ticket #205)
---

# Production-trace → self-test golden-case auto-promotion

## Problem

Hydra's self-test suite (`self-test/run.sh` + `self-test/golden-cases.json`) is
**hand-curated**: an operator writes each golden case by hand. It does not learn
from real production failures. When a worker hits `commander-stuck`, fails review,
or gets rescued by the watchdog, the run leaves a session trace
(`logs/traces/<ticket>.jsonl`, ticket #197) and — if it reached review — an
evidence-table verdict (ticket #196). Today that signal evaporates: the failure
is debugged once and never converted into a regression that guards against the
same failure mode recurring.

The 2026 agent-eval consensus is a **production-to-test loop**: a run that fails
should become a new golden case automatically, so the regression suite grows from
real failures. This is the same flywheel as the memory-citation loop
(`MEMORY_CITED:` → `state/memory-citations.json` → 3+ cites promote to a skill),
applied to self-test. This ticket builds the **promotion step** that converts one
failed/stuck/rescued ticket's trace + outcome into one new `kind:"script"` golden
case.

Depends on (both merged on `main`):
- **#197** — the trace substrate (`scripts/trace-append.sh`,
  `scripts/trace-analyze.sh`, format `logs/traces/<ticket>.jsonl`).
- **#196** — the evidence-based review gate
  (`.claude/skills/classify-pr-for-review/`, `scripts/validate-evidence-table.sh`,
  evidence-table verdict format).

## Goals

1. A script, `scripts/promote-trace-to-golden.sh`, that takes ONE ticket's trace
   (+ its rescue verdict / review outcome) and produces ONE `kind:"script"`
   golden case that `self-test/run.sh` can consume as-is.
2. **Grow the regression suite from real failures**: the produced case is a
   *regression-replay* — it pins (a) the failure trace still parses with the
   trace tooling, and (b) the recorded failure signature (the `error.type` /
   `hydra.test.name` that the run hit) is still detectable. A future change to
   the trace tooling that stops detecting that failure mode trips the case.
3. **Idempotent**: re-running for the same ticket updates the existing case in
   place (keyed by a deterministic case id), never appends a duplicate.
4. **Small + fast**: each promoted case is a `script` case running offline
   `trace-analyze.sh` invocations over a committed fixture — sub-second, CI-safe,
   keeps the suite under the ~30-case / <5-min budget.
5. **Content-safe**: the trace is sanitized before it is copied into a committed
   fixture — any `gen_ai.prompt` / `gen_ai.completion` content attr is dropped
   (secrets hard-rail; same default-off content rule as `trace-append.sh`).
6. A committed fixture + a regression test that proves a real failed-run trace
   produces a valid golden case `run.sh` can execute (per the operator's
   "test for real" standing requirement).

## Non-goals

- **Auto-wiring promotion into Commander's watchdog / autopickup tick.** This
  ticket ships the *script* + format + a test. Where Commander calls it (e.g.
  after `rescue-worker.sh` returns `nothing-to-rescue` → `commander-stuck`) is a
  CLAUDE.md/spec wiring follow-up; **CLAUDE.md is not edited here** (the spawn
  prompt forbids it, and the size guard discourages it).
- **Modifying the trace substrate** (`trace-append.sh` / `trace-analyze.sh`) or
  the watchdog (`rescue-worker.sh`). Those are owned by other in-flight workers
  (#185/#203 hazard). We only READ their formats. We append a case to
  `golden-cases.example.json` (the only shared file we touch, append-only).
- **Replaying the whole failed run** (spawning a worker to re-do the ticket).
  The trace is not enough to deterministically re-run a Claude session, and the
  `worker-implementation`-kind executor is still a SKIP (`self-test/run.sh:535`).
  The promoted case is a `script`-kind *trace-replay*, not a session-replay.
- **Promotion thresholds** (e.g. "only promote after N occurrences"). v1 promotes
  one trace → one case on demand; the dedup/threshold policy is a follow-up that
  the Commander wiring ticket can layer on (mirrors how `promote-citations.sh`
  added the 3×3 gate on top of a simpler scan).
- A trace viewer / case-management UI.

## Survey (current state, cited)

- **Golden case format** — `self-test/run.sh` infers `kind` from an explicit
  `.kind` field, else `.worker_type`, else "script if `.steps` is a non-empty
  array" (`self-test/run.sh:184-194`). A `script` case has `id`, optional
  `kind:"script"`, optional `requires:[]`, and `steps:[{name, cmd, expected_exit,
  expected_stdout_jq?, expected_stderr_contains?}]` (`run.sh:307-386`). Each
  `cmd` runs from worktree root; `expected_stdout_jq` is piped through `jq -e`
  (`run.sh:362-371`). Comment rows start their `id` with `_` and are skipped
  (`run.sh:182`). The model executable cases are `memory-validators` and
  `runner-meta` in `golden-cases.example.json`.
- **Trace format** — `logs/traces/<ticket>.jsonl`, one event per line, five
  stable top-level keys `ts / span_id / parent_span_id / kind / attrs`
  (`docs/specs/2026-05-21-worker-session-trace.md`). Failures carry
  `attrs."error.type"` (e.g. `test_failed`, `tool_error`) and tool/test events
  carry `attrs."hydra.test.name"` / `attrs."hydra.test.result"`
  (`scripts/trace-append.sh:14-26`, `self-test/fixtures/worker-session-trace/sample-trace.jsonl`).
- **Trace read tooling** — `scripts/trace-analyze.sh <subcommand> [--json]
  [file]`: `summary` (counts + wall-clock, exit 0 on a valid file), `errors`
  (spans with `error.type` set), `tools`, `durations`. Missing file → exit 2
  (`scripts/trace-analyze.sh:45-48`). This is what the promoted case calls.
- **Rescue verdicts** — `scripts/rescue-worker.sh --probe` emits a JSON
  `{"verdict": ...}`: `rescue-commits`, `rescue-uncommitted`, `push-only`,
  `nothing-to-rescue` (→ `commander-stuck`), `flaky-tool-retry`
  (`rescue-worker.sh:14-18`). The promotion script records the verdict as case
  provenance (a `_provenance` field) but does not act on it beyond labeling.
- **Review outcome** — the evidence-table verdict format (`PASS` / `FAIL` /
  `UNVERIFIED`) from `.claude/skills/classify-pr-for-review/SKILL.md` and
  `scripts/validate-evidence-table.sh`. When a trace came from a PR that failed
  review, the operator can pass `--outcome review-fail` for provenance.
- **Conventions to follow** — script shape: `scripts/promote-citations.sh`
  (idempotent, `--dry-run`, `--help`, exit 0/2, jq-built JSON). Test shape:
  `scripts/test-promote-citations.sh` (bash, `say/ok/bad`, pass/fail counter,
  `mktemp` fixtures, no external harness). Both are CI-checked by
  `.github/workflows/scripts/syntax-check.sh` (bash -n, jq empty, spec
  frontmatter). CI runs `./self-test/run.sh --kind=script` on every PR.

## Trace → golden case mapping

Given a trace `logs/traces/<ticket>.jsonl` for ticket `N`, the promotion derives:

- **Sanitized fixture**: `self-test/fixtures/trace-golden/<N>.jsonl` — the trace
  with content attrs (`gen_ai.prompt`, `gen_ai.completion`) stripped from every
  event's `attrs`. (Default traces never carry these; stripping is
  belt-and-suspenders so a `--with-content` debug trace can't leak into a
  committed fixture.)
- **Failure signature**: the set of distinct `attrs."error.type"` values present
  in the trace (via `trace-analyze.sh errors --json`). If the trace has at least
  one error, the case asserts that signature is still detected. (A
  `nothing-to-rescue` idle-ghost trace may have zero `error.type` events; that
  case asserts only "trace parses + has the expected span/event counts", which is
  still a useful regression — it pins that an idle-ghost trace is well-formed and
  analyzable.)

The produced **`kind:"script"` golden case**:

```json
{
  "id": "trace-golden-<N>",
  "kind": "script",
  "_description": "Auto-promoted from ticket #<N>'s failed/stuck/rescued run trace ...",
  "_provenance": { "ticket": "<N>", "verdict": "<rescue-verdict|outcome>", "promoted_at": "<ISO-8601>" },
  "tier": "T1",
  "steps": [
    {
      "name": "trace-<N> parses (summary exits 0)",
      "cmd": "scripts/trace-analyze.sh summary --json self-test/fixtures/trace-golden/<N>.jsonl",
      "expected_exit": 0,
      "expected_stdout_jq": ".events >= 1 and .spans >= 1"
    },
    {
      "name": "trace-<N> still detects failure signature: <error.type>",
      "cmd": "scripts/trace-analyze.sh errors --json self-test/fixtures/trace-golden/<N>.jsonl",
      "expected_exit": 0,
      "expected_stdout_jq": "map(.error_type) | index(\"<error.type>\") != null"
    }
  ]
}
```

For a trace with no `error.type` (idle ghost / `nothing-to-rescue`), the second
step is replaced by a summary-count assertion (`.errors == 0 and .events == <n>`)
so the case is never empty and still guards the trace shape.

## Proposed approach

### Output mode — the key design call

**Decision: the script emits the case JSON to stdout (and writes the fixture);
it does NOT edit `golden-cases.example.json` itself by default.**

Two options were considered:

1. **Script mutates `golden-cases.example.json` in place** (jq read-modify-write,
   append/replace the `trace-golden-<N>` case). *Rejected as the default.* The
   committed cases file is a shared artifact other workers also append to; an
   in-place mutate from a script invoked mid-flight is exactly the kind of
   parallel-write contention the #185/#203 hazard warns about, and it makes the
   script's side effects harder to review. It also couples "generate a case" to
   "decide where it lands", which the Commander wiring ticket should own.

2. **Script emits the case to stdout; caller appends** (chosen). The script is a
   pure generator: it writes the sanitized fixture and prints one valid case
   object. Commander (or the operator) appends it to the cases file with a
   one-line jq merge. This mirrors `promote-citations.sh --dry-run` (prints the
   plan, no git side effects) and `parse-citations.sh` (emits a JSON delta the
   caller merges). It keeps the script idempotent and testable without git, and
   leaves the "land it" decision to the wiring layer. An optional
   `--into <cases-file>` flag does the idempotent merge for callers that want it
   (used by the test against a `mktemp` copy, never against the committed file by
   default).

### Idempotency

The case id is deterministic: `trace-golden-<N>`. When `--into <file>` is given,
the merge is a jq `(.cases | map(select(.id != $id))) + [$newcase]` — drop any
existing case with that id, then append the fresh one. Re-running for the same
ticket replaces, never duplicates. The fixture file is overwritten in place
(same path `<N>.jsonl`). Without `--into`, idempotency is trivially the caller's
jq merge using the same key.

### Components / file structure

- **Create `scripts/promote-trace-to-golden.sh`** — the generator.
  - Flags: `--ticket <N>` (required), `--trace <file>` (default
    `logs/traces/<N>.jsonl`), `--verdict <v>` (rescue verdict, default
    `unknown`), `--outcome <o>` (review outcome, optional, e.g. `review-fail`),
    `--fixture-dir <dir>` (default `self-test/fixtures/trace-golden`),
    `--into <cases-file>` (idempotent-merge into this file instead of stdout),
    `--dry-run` (print the plan + the case to stdout, write NOTHING — no fixture,
    no merge), `--help`.
  - Steps: validate args; require `jq` + `trace-analyze.sh`; read the trace;
    fail (exit 2) on a missing/empty/malformed trace; sanitize → write fixture
    (unless `--dry-run`); compute failure signature via `trace-analyze.sh
    errors --json`; build the case object with jq; either print it (default /
    `--dry-run`) or idempotently merge into `--into`.
  - Exit codes: `0` ok; `2` usage / missing trace / malformed input.
- **Create `self-test/fixtures/trace-golden/sample-failed-trace.jsonl`** — a
  committed, realistic fixture of a FAILED run trace: an `invoke_agent` root, a
  Bash tool span, a failing test span with `error.type=test_failed` +
  `hydra.test.name=npm test`, and (to prove sanitization) ONE event carrying a
  `gen_ai.prompt` content attr that MUST be stripped from the promoted fixture.
- **Create `scripts/test-promote-trace-to-golden.sh`** — the regression test
  (matches `test-promote-citations.sh` style). Asserts the full flywheel: a
  failed-run trace → a valid golden case → `run.sh` executes it green.
- **Append ONE golden case to `self-test/golden-cases.example.json`** —
  `trace-to-golden-meta` (`kind:"script"`): self-tests the promotion script the
  same way `runner-meta` self-tests the runner. It runs
  `promote-trace-to-golden.sh --dry-run` against the committed sample fixture
  and asserts the emitted case is valid + carries the failure signature; then
  (the flywheel proof) merges into a `mktemp` cases file and runs `run.sh
  --cases-file <tmp>` to prove the produced case actually executes green. This
  is the case that grows the suite-from-failures *and* is itself the meta-guard
  for the promotion machinery.
- **Modify `scripts/README.md`** — one row each for
  `promote-trace-to-golden.sh` and `test-promote-trace-to-golden.sh`.

### Data flow

```
failed run        --> logs/traces/<N>.jsonl  (trace-append.sh, #197)
rescue/review     --> verdict / outcome      (rescue-worker.sh / evidence table)
promote-trace-to-golden.sh --ticket N --trace ... --verdict ...
   |-- sanitize (drop content attrs) --> self-test/fixtures/trace-golden/<N>.jsonl
   |-- analyze errors                 --> failure signature
   `-- emit case JSON  (stdout, or --into merges idempotently)
self-test/run.sh --cases-file ...  --> runs the trace-replay case  (CI on every PR)
```

### Error handling

- Missing `--ticket` → exit 2, usage to stderr.
- Trace file not found / empty / not valid JSONL → exit 2 with a clear message
  (we never emit a case for a trace we couldn't read).
- A trace with zero events → exit 2 ("trace has no events; nothing to promote").
- `--into` target missing or not valid JSON → exit 2.
- `trace-analyze.sh` absent → exit 2 ("trace-analyze.sh required").
- jq absent → exit 2 ("jq required").
- `--dry-run` writes nothing, even the fixture (pure preview).

## Test plan

All offline, bash + jq, no network/docker (CI-safe). `test-promote-trace-to-golden.sh`:

1. **emit: valid case** — `--dry-run` against `sample-failed-trace.jsonl` emits a
   single JSON object with `id == "trace-golden-<N>"`, `kind == "script"`, and a
   non-empty `steps` array. `jq empty` parses it.
2. **emit: failure signature captured** — the emitted case has a step whose
   `expected_stdout_jq` references the trace's `error.type` (`test_failed`).
3. **sanitize: content stripped** — a non-dry-run write produces
   `<fixture-dir>/<N>.jsonl` with NO `gen_ai.prompt` attr anywhere (the sample's
   content event is sanitized out), while preserving the `error.type` event.
4. **idempotent merge** — `--into <tmp-cases>` twice yields exactly ONE
   `trace-golden-<N>` case (no duplicate); the second run replaces the first.
5. **flywheel proof (the headline test)** — promote the sample trace into a
   `mktemp` cases file, then run `./self-test/run.sh --cases-file <tmp>
   --case trace-golden-<N>` and assert exit 0 (the produced case executes green
   against the real `trace-analyze.sh`).
6. **idle-ghost trace** — a trace with zero `error.type` events promotes to a
   case whose second step is a `.errors == 0` summary assertion (not an empty
   case), and that case also runs green via `run.sh`.
7. **usage / missing-trace errors** — missing `--ticket` → exit 2; missing trace
   file → exit 2; empty trace → exit 2.
8. **dry-run writes nothing** — `--dry-run` does not create the fixture file.
9. **`bash -n`** on the new script passes (also enforced by CI syntax-check).

The committed golden case `trace-to-golden-meta` covers checks 1, 2, and 5 in CI
(`./self-test/run.sh --kind=script`). The standalone test covers all of 1–9.
Output is pasted into the PR per the "test for real" requirement.

## Risks / rollback

- **Risk: the suite grows unbounded** as failures accumulate. Mitigated by: each
  case is sub-second; the Commander wiring ticket owns the dedup/threshold/cap
  policy (non-goal here). v1 ships one meta-case + the generator; the suite does
  not auto-grow until wired.
- **Risk: a promoted fixture leaks a prompt/secret.** Mitigated by the
  sanitization step (drop `gen_ai.prompt`/`gen_ai.completion` from every event)
  + the existing default-off content rule in `trace-append.sh`. Test #3 asserts
  the strip happens. The committed sample deliberately includes a content attr
  to prove it is removed.
- **Risk: parallel-write contention on `golden-cases.example.json`.** Mitigated
  by NOT mutating it from the script by default (stdout output mode); the one
  case we add is an append in this PR, reviewed like any diff.
- **Risk: scope creep into the watchdog/Commander wiring.** Explicitly fenced —
  CLAUDE.md is not edited; the wiring is a follow-up. If wiring turns out to be
  needed for the test to pass, STOP and report (it is not — the test drives the
  script directly).
- **Rollback:** purely additive — one new script, one new test, one fixture, one
  appended golden case, two README rows, this spec. Delete to roll back; no
  migration, no state change, no behavior change to existing scripts.

## Out of scope (tracked elsewhere)

- Wiring promotion into Commander's watchdog / autopickup tick (CLAUDE.md
  pointer) — follow-up.
- Dedup / occurrence-threshold / suite-size-cap policy — follow-up (mirrors the
  3×3 gate `promote-citations.sh` layered on later).
- Promoting from the live evidence table (parsing a posted review comment into
  criteria-level golden assertions) — the verdict is recorded as provenance now;
  criterion-level promotion is a richer follow-up.
- A session-replay executor (re-running the failed worker) — blocked on the
  `worker-implementation`-kind executor, still a SKIP.
