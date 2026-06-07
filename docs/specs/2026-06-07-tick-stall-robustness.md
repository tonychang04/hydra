---
status: accepted
date: 2026-06-07
---

# Tick stall robustness — gc-stale-worktrees + interval guard + flaky-tool exit-5 routing

**Ticket:** #242 ([P1/harness] Stall robustness: flaky-tool exit-5 routing +
autopickup interval guard + gc-stale-worktrees)

**Depends on:** #239 / #244 (autopickup-tick orchestrator — provides the numbered
step-function structure + the report-only `*_due`/marker contract this rides next
to) and #240 / #252 (daily self-audit, section 4d — the most recent step to mirror).

## Problem

Stalls are the #1 worker killer and the harness has documented-but-unrouted or
entirely-missing recovery plumbing (2026-06-06 survey):

1. **Zombie worktrees accrue.** Worktree cleanup is implicit. A crashed/killed
   worker can leave its `.claude/worktrees/agent-*` directory behind with no
   garbage collector. Over a long-running Commander these accumulate (the live
   tree already holds dozens), wasting disk and obscuring which worktrees are
   actually live. Nothing in the tick reports or reclaims them.

2. **No interval-vs-timeout guard.** `state/autopickup.json:interval_min` is
   clamped to `[5, 120]`, but nothing warns when it is set at or above the
   ~18-minute stream-idle ceiling. If `interval_min >= 18`, a worker can hit the
   stream-idle timeout *before any tick runs to rescue it* — the rescue probe
   never gets a chance, so the autonomy guarantee silently degrades. The
   watchdog's whole premise is that a tick fires while the worker is still
   recoverable; an interval at/above the ceiling defeats it.

3. **Flaky-tool exit-5 is unrouted in CLAUDE.md.** `scripts/rescue-worker.sh`
   `--probe` emits a `flaky-tool-retry` verdict and exits **5** when the worker
   left a recent `.hydra/flaky-tool.json` marker
   (`docs/specs/2026-05-21-flaky-tool-probe-verdict.md`). The correct response is
   NOT to rescue — the worker is ALIVE — but to read the marker's `fallback` hint
   and relay it to the live worker via `SendMessage`, then let it continue. That
   response IS documented in the flaky-tool spec, but **CLAUDE.md's watchdog
   routing line lists only exit 3 (rebase-conflict) and exit 4 (review-rescue)**
   — there is no exit-5 entry. With no routing pointer, Commander treats exit 5
   as generic and mis-parks the ticket `commander-stuck`, killing a recoverable
   live worker (the exact failure the flaky-tool verdict was built to prevent).

## Goals

1. **`scripts/gc-stale-worktrees.sh`** — a standalone, report-or-actuate helper
   that lists (`--dry-run`, default) or removes (`--apply`) `.claude/worktrees/
   agent-*` directories that are BOTH (a) not referenced by any worker in
   `state/active.json` AND (b) older than 24h (mtime). Dry-run is the default and
   is purely read-only.

2. **Wire gc into the tick as a report-only step (section 4e).** The tick
   enumerates stale-worktree *candidates* and reports them under an additive
   `gc` JSON key + an `actions.gc_stale_worktrees` roll-up count. The tick NEVER
   deletes — actuation is `gc-stale-worktrees.sh --apply`, invoked by Commander
   (or directly by the operator). This matches the report/actuate split every
   other tick step uses (retro_due → Commander writes; audit_due → Commander
   spawns; gc candidates → Commander/operator runs `--apply`).

3. **Interval guard (section, folded into preflight reporting).** When
   `state/autopickup.json:interval_min >= 18`, the tick emits a WARN in the
   report: `interval will miss the ~18min stream-idle ceiling; set <15`. Surfaced
   as `preflight.interval_warn` (boolean) + `preflight.interval_warn_text` and a
   human-report line. Report-only; the tick does not rewrite the interval.

4. **Flaky-tool exit-5 routing documented + one-line CLAUDE.md pointer.**
   Consolidate the exit-5 → SendMessage(fallback) routing (read
   `.hydra/flaky-tool.json`, relay `fallback`, label `commander-flaky-tool-retry`,
   do NOT rescue) into this spec's "Routing" section, and add a single exit-5
   clause to the CLAUDE.md watchdog routing line. CLAUDE.md is at NOTICE (89%),
   so the one-line addition is OFFSET by trimming a verbose, already-spec-pointed
   section so net size does not grow.

5. `scripts/validate-state-all.sh` and `scripts/preflight-syntax.sh` stay green.
   No new state field (interval_min already exists; gc reads active.json only).

## Non-goals

- **No new state field / schema change.** The interval guard reads the existing
  `interval_min`; gc reads `state/active.json` (existing). The only doc touch is
  a one-line CLAUDE.md routing clause.
- **No deletion from the tick.** The tick reports gc candidates; it never removes
  directories. Removal is the explicit `gc-stale-worktrees.sh --apply` actuation.
- **No change to `rescue-worker.sh`'s exit-5 detection.** The verdict and exit
  code already exist (#190). This ticket routes Commander's *response* to them;
  it does not touch the probe.
- **No re-implementation of chained scripts.** gc is a new standalone helper; the
  tick shells out to it (same orchestrate-don't-duplicate rule as #239/#240).
- **No change to the worktree creation path.** The harness creates
  `.claude/worktrees/agent-*`; gc only reclaims orphans. gc never touches a dir
  that is in `active.json` or younger than 24h.

## Proposed approach

### `scripts/gc-stale-worktrees.sh`

Mirrors the style of `pr-shepherd.sh` / `rescue-worker.sh` (set -euo pipefail,
`--help`, offline-testable seams, JSON + human modes).

**Identify candidates.** Enumerate immediate subdirectories of the worktrees root
(`<root>/.claude/worktrees/agent-*`). For each, a dir is a **stale candidate**
when BOTH hold:

- **not active:** its absolute path is not the `.worktree` of any worker in
  `state/active.json`. Matching is by resolved absolute path; a worker whose
  entry has no `worktree` field cannot pin a dir (pre-migration entries are rare
  and the 24h gate still protects fresh dirs).
- **older than 24h:** the dir's mtime is more than `MAX_AGE_S` (default 86400)
  seconds in the past. `--max-age-s <n>` overrides for tests.

**Fail-closed on missing active.json.** If `state/active.json` is absent or
unreadable, the script REFUSES to delete anything (prints a clear message, exits
1 in `--apply` mode; in `--dry-run` it reports zero candidates with a note). This
prevents a "delete everything because we couldn't read the active set" footgun —
the active set is load-bearing for the not-active half of the predicate. (Note:
`state/active.json` is gitignored runtime state, so it is legitimately absent in
a fresh checkout — failing closed is the safe default there too.)

**Modes.**

- `--dry-run` (DEFAULT): list candidates (human) or emit
  `{"root":...,"candidates":[{path,age_s,reason}],"removed":[]}` (`--json`).
  Read-only — no filesystem mutation.
- `--apply`: remove each candidate via `git worktree remove --force` when the dir
  is a registered git worktree, falling back to `rm -rf <dir>` ONLY for a dir
  under the worktrees root that git does not know about (a truly orphaned dir).
  The `rm -rf` target is constrained to `<root>/.claude/worktrees/agent-*` and
  validated to be non-empty + a real directory before removal — never a path the
  user supplied, never outside the worktrees root. Reports `removed:[...]`.

**Flags / seams:**

- `--root <path>` — repo root (default: script's `../..`). Lets the smoke test
  point at a fixture tree.
- `--state-dir <path>` — override `state/` (default `<root>/state`); the smoke
  test points it at a fixture `active.json`.
- `--max-age-s <n>` — staleness threshold in seconds (default 86400 = 24h).
- `--worktrees-dir <path>` — override the worktrees root for tests (default
  `<root>/.claude/worktrees`).
- `--json` / `--dry-run` / `--apply` / `-h|--help`.

**Exit codes:** `0` ran (candidates/removals reported) · `1` I/O error
(missing active.json in `--apply`, jq missing) · `2` usage error.

### Tick section 4e — gc reporting (report-only)

A new self-contained block after section 4d (audit), before the actions roll-up,
mirroring 4b/4c/4d:

- shells out to `gc-stale-worktrees.sh --dry-run --json --state-dir <STATE_DIR>
  --worktrees-dir <...>` (best-effort; a gc failure is reported, never fatal —
  same `set +e` discipline as the rescue probe),
- produces one compact `gc_json` object `{candidates_count, candidates:[...]}`,
- emits an additive `gc` top-level key + an `actions.gc_stale_worktrees` count +
  a human-report stanza + a footnote when count > 0:
  `↳ Stale worktrees: run scripts/gc-stale-worktrees.sh --apply to reclaim.`

The tick passes a `--worktrees-dir` so the offline smoke harness can point gc at
a fixture worktrees tree without touching the live one.

### Interval guard (preflight)

Read `interval_min` from `state/autopickup.json` (default/absent → no warn).
`interval_warn = (interval_min >= 18)`. Surface in `preflight_json` as
`interval_min`, `interval_warn`, `interval_warn_text`. Human report appends a
WARN line under Preflight when set. This is additive to the existing
`preflight` object (stability contract preserved). The guard does NOT block spawn
(an at-ceiling interval is a misconfiguration to flag, not a hard stop); it warns
loudly so Commander/operator lowers it to `<15`.

### Routing: flaky-tool exit-5 (Commander's response)

This is the canonical routing entry the ticket asks for (CLAUDE.md gets the
one-line pointer; the detail lives here):

> **`rescue-worker.sh --probe` exit 5 = `flaky-tool-retry`** — the worker is
> ALIVE but blocked on a repeatedly-failing external tool (it left a recent
> `<worktree>/.hydra/flaky-tool.json` marker). Commander's response is NOT a
> rescue. Read `tool` + `fallback` from the verdict JSON (or the marker), then
> `SendMessage` the live worker: *"External tool `<tool>` is flaky and timing
> out. Stop retrying it; fall back to `<fallback>` and continue."* Label the
> ticket `commander-flaky-tool-retry` (P1 observability). Do NOT run `--rescue`
> and do NOT label `commander-stuck`. If the SAME worker probes `flaky-tool-retry`
> a second time (the fallback also failed) or then goes genuinely silent, fall
> through to the normal rescue / `commander-stuck` path — no infinite retry.

CLAUDE.md's watchdog routing line gains one clause:
`flaky-tool-retry (exit 5) → SendMessage the live worker the marker's fallback;
do NOT rescue`. Offset by trimming the verbose "Session greeting" health-oneliner
prose (already fully covered by its own specs) so net CLAUDE.md size does not grow.

## Test plan

New offline fixture `self-test/fixtures/gc-stale-worktrees/` + a `run-smoke.sh`
driven fully offline (no network, no gh, no live worktrees beyond the fixture
tree it builds in a tempdir):

1. **gc dry-run lists a stale non-active dir** — seed a fixture worktrees tree
   with `agent-STALE` (mtime set 25h old, not in active.json) and `agent-FRESH`
   (just-created) and `agent-ACTIVE` (old but referenced by the fixture
   active.json). `gc-stale-worktrees.sh --dry-run --json` ⇒ `candidates`
   contains `agent-STALE` only; `removed` is empty; the dir still exists on disk.
2. **gc real run removes only the stale non-active dir** — `--apply` ⇒
   `removed` contains `agent-STALE`; `agent-STALE` is gone; `agent-FRESH` and
   `agent-ACTIVE` remain.
3. **Fail-closed on missing active.json** — point `--state-dir` at a dir with no
   `active.json`; `--apply` exits 1 and removes nothing; `--dry-run` reports zero
   candidates with the fail-closed note.
4. **Interval-guard WARN fires for interval_min=30** — run the tick with a
   fixture `autopickup.json` whose `interval_min` is 30 ⇒ `--json`
   `.preflight.interval_warn == true` and `.preflight.interval_warn_text`
   mentions `18` / `<15`; a fixture with `interval_min: 10` ⇒
   `interval_warn == false`.
5. **Tick gc section reports candidates** — run the tick with `--worktrees-dir`
   pointed at the fixture tree from (1) ⇒ `.gc.candidates_count >= 1` and
   `.actions.gc_stale_worktrees >= 1`; human mode renders the "Stale worktrees"
   stanza.

The existing `autopickup-tick/`, `autopickup-tick-scheduled/`, and
`autopickup-tick-audit/` smoke harnesses continue to pass unchanged (additions
are additive JSON keys + new flags with safe defaults). Two golden `script`
steps are appended to the `autopickup-tick-script` case (existing steps
unreordered): the gc smoke and the interval-guard smoke.

Run: `bash self-test/fixtures/gc-stale-worktrees/run-smoke.sh`;
`bash self-test/fixtures/autopickup-tick/run-smoke.sh`;
`bash self-test/fixtures/autopickup-tick-scheduled/run-smoke.sh`;
`bash self-test/fixtures/autopickup-tick-audit/run-smoke.sh`;
`bash scripts/validate-state-all.sh`; `bash scripts/preflight-syntax.sh`;
`bash self-test/run.sh --kind script`.

## Addendum — fail-closed on CORRUPT active.json (#254 review)

**Problem found in review (data-loss blocker).** The original fail-closed gate
keyed only on `[[ -f && -r ]]` — present + readable. A crash mid-rewrite of
`state/active.json` leaves it present + readable but **truncated/unparseable**.
The in-loop `jq … 2>/dev/null` swallowed the parse error, so the active set came
back EMPTY with `fail_closed=false`. Every `agent-*` dir >24h then became a
deletion candidate — **including live worker worktrees** whose entries lived in
the now-corrupt file. Confirmed: with a corrupt active.json, the pre-fix script
listed a live worktree as a candidate and `--apply` deleted it (`exit 0`).

**Fix.** Validate the parse BEFORE building the active set: the gate is now
`[[ -f && -r ]] && jq empty "$ACTIVE_FILE"`. A corrupt file fails the `jq empty`
check and falls into the same `fail_closed=true` branch as missing/unreadable —
the script removes NOTHING (`--apply` exits 1; `--dry-run` reports zero
candidates with the fail-closed note). The existing missing/unreadable gate is
unchanged; this only adds the corrupt case.

**Concern #2 — surface a failed gc safety scan in the tick.** Section 4e
previously left `gc_json` at a default `candidates_count:0` whenever the gc scan
could not produce parseable JSON, so a broken scan rendered as `(none)` —
indistinguishable from "clean". The tick now carries `scan_ok` (true only when
the gc script ran AND returned parseable JSON) plus `scan_skipped_reason`. Human
output prints `(gc scan-skipped — safety scan could not run: <reason>…)` when
`scan_ok=false` and `(gc fail-closed — …missing/unreadable/corrupt…)` when the
scan ran but fail-closed — never `(none)` for either. A test-only `--gc-script`
seam lets the smoke harness point the scan at a non-existent binary to assert
`scan_ok=false`.

**New test cases (RED→GREEN).** Added to
`self-test/fixtures/gc-stale-worktrees/run-smoke.sh`:
6. corrupt active.json ⇒ `fail_closed=true`, zero candidates, `--apply` exits 1,
   the stale dir a valid file would have protected is NOT deleted.
7. tick on corrupt active.json ⇒ `.gc.fail_closed==true`, `.gc.scan_ok==true`,
   human output surfaces fail-closed (not `(none)`); 7b: `--gc-script` pointed at
   a missing binary ⇒ `.gc.scan_ok==false`.

## Risks / rollback

- **Risk: gc deletes a live worktree.** → Mitigated by the AND predicate (must be
  BOTH not-active AND >24h), fail-closed on missing active.json, the dry-run
  default, the `git worktree remove --force` path (git refuses a dir with
  uncommitted changes unless forced — and the >24h + not-active gate already
  excludes anything in flight), and the constrained `rm -rf` target
  (`<root>/.claude/worktrees/agent-*` only, validated). The tick never deletes at
  all.
- **Risk: the tick accidentally mutates state.** → Mitigated by report-don't-
  mutate: section 4e only shells `gc --dry-run` (read-only) and the interval
  guard only reads `interval_min`. Same discipline as 4b/4c/4d.
- **Risk: a 24h-old but still-needed worktree is reclaimed.** → A worker live for
  >24h is itself an anomaly the watchdog would have rescued long before; and the
  not-active gate protects any dir still tracked in active.json regardless of age.
- **Rollback:** additive (new standalone script, new tick section 4e + interval
  guard fields, new fixture, two appended golden steps, one CLAUDE.md routing
  clause offset by a trim). Reverting the commit restores #240 behavior with no
  migration.
