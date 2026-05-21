---
status: implemented
date: 2026-05-20
author: hydra worker (#176)
supersedes-non-goal-of: docs/specs/2026-04-17-claudemd-size-guard.md
---

# CLAUDE.md size guard — graduated reaction (NOTICE / WARN bands)

## Problem

`CLAUDE.md` is loaded into every Commander session's system prompt, so every
inlined procedure is a token tax paid on every spawn, forever. The original size
guard (`scripts/check-claude-md-size.sh`, spec
`docs/specs/2026-04-17-claudemd-size-guard.md`) is **binary**: silent under the
ceiling (default 18000 chars), hard-fails the spawn preflight at the first char
over.

That binary design has a sharp edge. As of 2026-05-20 `CLAUDE.md` sat at
**17540 / 18000 (97%)** — roughly one routing row from blocking *every* spawn —
and Commander said **nothing** about it. The first signal the operator (or the
supervisor agent) gets is a red preflight that blocks all work. There is no
runway: no "you're close, trim before you add the next thing."

The operator wants Commander to **react early and make the situation clear** as
`CLAUDE.md` approaches the ceiling, not slam into a wall. (Ticket #176, operator
direction 2026-05-20.)

### Reversal of a prior non-goal

The original size-guard spec listed **"a warning/dry-run mode"** as an explicit
**non-goal** ("The gate is binary — 18000 or less, or the preflight fails").
This spec **deliberately reverses that** per operator direction 2026-05-20. The
reasoning behind the original non-goal (Alternative B, "two thresholds means
arguments about which applies") is addressed here by making the bands *advisory
only* below the ceiling — NOTICE and WARN never change the exit code, so there is
no ambiguity about what blocks: only `size > max` blocks, exactly as before. The
new bands inform; they do not gate.

## Goals

- `check-claude-md-size.sh` emits one of four bands — **OK / NOTICE / WARN /
  FAIL** — based on size as a percentage of the ceiling.
- **Exit codes unchanged at the boundaries that matter:** exit 0 for OK /
  NOTICE / WARN; exit 1 only when `size > max` (FAIL). NOTICE and WARN inform but
  do **not** block preflight.
- Band cut points are tunable via `HYDRA_CLAUDEMD_NOTICE_PCT` /
  `HYDRA_CLAUDEMD_WARN_PCT` (defaults 85 / 95). `--max` (or `HYDRA_CLAUDEMD_MAX`)
  remains authoritative for the ceiling.
- `validate-state-all.sh` surfaces the NOTICE / WARN line **without failing**
  (it already calls the size script as its last preflight item).
- A `--quiet` mode prints a single session-greeting one-liner at NOTICE / WARN,
  silent at OK — mirroring `scripts/hydra-connect.sh --status --quiet`.
- `CLAUDE.md` "Session greeting" section gets a short pointer telling Commander
  to append that one-liner (mirroring the existing connector-status one-liner).
- `CLAUDE.md` itself is trimmed back into the **OK band** (target ≤ ~15300,
  ideally ~14k) by collapsing the largest inline *prose* sections into pointers
  to specs that already exist. **Zero routing information lost.**
- Regression test (`scripts/test-check-claude-md-size.sh`) extended to cover the
  NOTICE band, the WARN band, env-var overrides for each, OK-still-silent,
  FAIL-still-exit-1, and the validate-state-all integration (NOTICE / WARN ⇒
  still exit 0).

## Non-goals

- Changing what blocks preflight. Only `size > max` blocks, same as before.
  NOTICE / WARN are advisory.
- Re-litigating the ceiling value (18000) or applying the rule to
  downstream-repo `CLAUDE.md` files. Out of scope, same as the original spec.
- A separate daemon or scheduled scan. The check runs where it already runs
  (preflight + session greeting), just with more nuance in its output.

## Band definitions

Bands are computed from `pct = floor(size * 100 / max)` and the two cut points,
themselves derived from the ceiling:

```
notice_floor = floor(max * NOTICE_PCT / 100)   # default 85% → 15300 at max=18000
warn_floor   = floor(max * WARN_PCT  / 100)   # default 95% → 17100 at max=18000
```

| Band   | Condition                          | Range @ max=18000 | Exit | Output |
|--------|------------------------------------|-------------------|------|--------|
| OK     | `size < notice_floor`              | < 15300           | 0    | one-line ✓ (unchanged); `--quiet`: silent |
| NOTICE | `notice_floor ≤ size < warn_floor` | 15300–17099       | 0    | one line: `<size>/<max> (NN%), <K> to ceiling` + top 3 H2 trim candidates (each with a "spec exists?" hint) |
| WARN   | `warn_floor ≤ size ≤ max`          | 17100–18000       | 0    | prominent block: NOTICE content + explicit "trim before adding routing" call to action |
| FAIL   | `size > max`                       | > 18000           | 1    | ✗ + top 5 trim candidates (unchanged hard rail) |

**Boundary precision (load-bearing):**

- The blocking boundary stays `size > max` — strictly over. `size == max` is
  **not** a failure; it lands in WARN (advisory). This preserves the original
  contract (`size <= max` ⇒ exit 0) and keeps existing callers / fixtures green.
  The ticket table's "FAIL ≥ 100% (≥ 18000)" describes the *display* intent; the
  actual gate is unchanged so `--max` stays authoritative and back-compatible.
- Band floors use `<` on the upper edge and `≤`/`>=` on the lower edge so the
  four bands partition the line with no gaps and no overlap:
  OK `[0, notice_floor)`, NOTICE `[notice_floor, warn_floor)`,
  WARN `[warn_floor, max]`, FAIL `(max, ∞)`.

### Env-var precedence

- `HYDRA_CLAUDEMD_NOTICE_PCT` / `HYDRA_CLAUDEMD_WARN_PCT` override the defaults
  (85 / 95). Both must be integers in `[0, 100]`.
- Sanity: `NOTICE_PCT ≤ WARN_PCT ≤ 100`. If a user inverts them (NOTICE > WARN),
  the script errors with exit 2 rather than silently producing an empty band.
- `--max` / `HYDRA_CLAUDEMD_MAX` remain the ceiling; flag wins over env, same as
  before. There is no `--notice-pct` / `--warn-pct` flag (env-only) to keep the
  CLI surface small — the percentages are tuning knobs, not per-invocation
  arguments. (If a flag is ever wanted, it's an additive follow-up.)

## Proposed approach

### 1. Extend `scripts/check-claude-md-size.sh` in place

Do **not** rewrite. The script already prints the top-5 H2 trim candidates, uses
TTY color, and has clean exit codes (0 ok / 1 over / 2 usage). The change:

1. After computing `size`, compute `notice_floor` / `warn_floor` from the
   env-overridable percentages (validate them like `--max`).
2. Branch into four bands instead of two:
   - **OK** — keep the existing one-line ✓ on stdout, exit 0.
   - **NOTICE** — print the advisory line + **top 3** H2 sections (reuse the
     existing awk section-sizer, `head -3` instead of `head -5`) to stdout,
     exit 0.
   - **WARN** — print a prominent (bold/yellow) block: the NOTICE content plus
     an explicit "trim a section into a spec before adding the next routing row"
     call to action, to stdout, exit 0.
   - **FAIL** — keep the existing ✗ block + top-5 candidates on stderr, exit 1.
3. Add `--quiet`: at OK, print nothing; at NOTICE / WARN, print exactly one
   session-greeting line (`CLAUDE.md: <size>/<max> (NN%) — <band msg>`) to
   stdout; at FAIL, print the one-liner too (so the greeting still surfaces a
   blocked state) and exit 1. Mirrors `hydra-connect.sh --status --quiet`.
4. NOTICE / WARN go to **stdout** (they're informational, exit 0). FAIL stays on
   **stderr** (it's an error, exit 1). This keeps the "errors on stderr" contract
   and lets `validate-state-all.sh` show the advisory line in normal output.

### 2. Surface in `validate-state-all.sh`

The bulk runner already calls `check-claude-md-size.sh --path <CLAUDE.md>` as its
last item and maps exit 0 → passed, 1 → failed, 2+ → abort. With the new bands:

- OK / NOTICE / WARN all return exit 0 → all counted as **passed**, preflight
  stays green. The NOTICE / WARN advisory text the script prints to stdout flows
  straight through (the bulk runner does not capture/suppress sub-check stdout),
  so the operator sees it inline. **No code change strictly required** for the
  pass path — but we add a one-line comment documenting that NOTICE / WARN are
  intentionally non-failing, so a future editor doesn't "fix" it into a gate.
- FAIL (exit 1) still counts as a failure, unchanged.

### 3. CLAUDE.md "Session greeting" pointer

Append one short line to the existing "Session greeting" section, right after the
connector-status one-liner, mirroring its shape:

> **CLAUDE.md size one-liner.** If `scripts/check-claude-md-size.sh --quiet`
> exits with output, append it verbatim (e.g. `CLAUDE.md: 17540/18000 (97%) —
> WARN: trim a section to a spec before adding routing`). Silent when OK.

A few lines max — respecting the size rule this ticket enforces.

### 4. Trim CLAUDE.md back into the OK band

Collapse the largest inline *prose* sections into 2–4 line pointers to specs that
**already exist** (every destination verified present before pointering). Lose
zero routing info. Sections kept inline **in full** (hard rails / routing
surface): identity, worker-types table, operating loop, commands table, safety
rules, label gotcha, state-files list, session-greeting rule.

Sections collapsed to pointers (specs already exist):

- Escalate to supervisor agent → `2026-04-16-mcp-agent-interface.md`,
  `2026-04-17-supervisor-escalate-client.md`, `docs/mcp-tool-contract.md`,
  `2026-04-17-main-agent-filing.md`
- Auto-dispatch test-discovery → `2026-04-17-auto-dispatch-test-discovery.md`
- Worker timeout watchdog → `2026-04-16-worker-timeout-watchdog.md`,
  `2026-04-17-review-worker-rescue.md`, `2026-04-17-rescue-worker-index-lock.md`
- Scheduled autopickup → `2026-04-16-scheduled-autopickup.md`,
  `2026-04-16-autopickup-default-on.md`, `2026-04-17-scheduled-retro.md`,
  `2026-04-17-daily-digest.md`
- Memory hygiene → `memory/memory-lifecycle.md`,
  `2026-04-16-external-memory-split.md`, `2026-04-17-memory-preloading.md`,
  `2026-04-17-skill-seed-list.md`, `2026-04-17-skill-promotion-automation.md`
- Weekly retro → `2026-04-16-retro-workflow.md`, `2026-04-17-scheduled-retro.md`,
  `2026-04-17-retro-auto-file.md`

### Alternatives considered

- **A — keep binary, just trim.** Rejected: the operator explicitly asked for a
  graduated reaction; trimming alone buys runway once but doesn't change the
  cliff-edge behavior next time.
- **B — three exit codes (0 OK, 3 NOTICE, 4 WARN, 1 FAIL).** Rejected: callers
  (`validate-state-all.sh`, CI, pre-commit hooks) treat any non-zero as failure.
  Advisory bands must stay exit 0 or they'd block preflight — defeating the
  point. Band identity is communicated via stdout text, not exit code.
- **C — add `--notice-pct` / `--warn-pct` flags.** Deferred (YAGNI): env vars
  cover the tuning need; flags are an additive follow-up if ever wanted.

## Test plan

Extend `scripts/test-check-claude-md-size.sh` (same structure: bash, colored
output, pass/fail counter, `mktemp` fixtures). Add cases sized to a small
`--max` so the percentages are easy to hit:

- **OK band** — fixture at ~50% of `--max` → exit 0, ✓ line present, no "NOTICE"
  / "WARN" keyword. (existing Test 1 covers the spirit; assert no band keyword.)
- **NOTICE band** — fixture at ~88% of `--max` → exit 0, output contains
  `NOTICE` + the `to ceiling` phrase + at least one trim candidate.
- **WARN band** — fixture at ~97% of `--max` → exit 0, output contains `WARN` +
  the call-to-action substring.
- **FAIL band** — fixture at ~110% of `--max` → exit 1, ✗ banner on stderr
  (existing Test 2 covers this; keep it).
- **Env overrides** — set `HYDRA_CLAUDEMD_NOTICE_PCT` / `HYDRA_CLAUDEMD_WARN_PCT`
  so a mid-size fixture lands in a *different* band than the defaults would put
  it; assert the band moves. Also assert inverted percentages (NOTICE > WARN)
  exit 2.
- **--quiet** — OK fixture → no stdout; NOTICE / WARN fixture → exactly one line
  starting `CLAUDE.md:`.
- **validate-state-all integration** — with the real repo's CLAUDE.md in NOTICE
  or WARN, `validate-state-all.sh` still exits 0 and prints the advisory line;
  with a tiny `HYDRA_CLAUDEMD_MAX` (FAIL) it still exits 1. (existing Test 7
  covers the FAIL path; add a NOTICE/WARN-stays-green assertion.)

Run after the trim: `scripts/check-claude-md-size.sh` reports the **OK** band,
and `bash scripts/validate-state-all.sh` exits 0.

## Risks / rollback

- **Risk: NOTICE / WARN noise on every preflight.** Mitigation: after the trim,
  CLAUDE.md is in the OK band → silent. The advisory only fires once the file
  re-approaches the ceiling, which is exactly when the operator wants the signal.
- **Risk: a future editor "fixes" NOTICE / WARN into a hard fail.** Mitigation:
  the inline comment in `validate-state-all.sh` and this spec both state the
  advisory-only invariant explicitly.
- **Risk: percentage math off-by-one at band edges.** Mitigation: integer floor
  math with the partition rules above; regression tests pin each band's edge.
- **Risk: trim loses behavior only documented in CLAUDE.md.** Mitigation: every
  collapsed section names a spec that already exists (verified before pointering);
  routing-surface sections kept inline in full.

**Rollback:** revert the PR. Script, surfacing wire-in, session-greeting pointer,
and the trim are one PR; reverting restores the prior binary guard and the
pre-trim CLAUDE.md with no other side effects. Commander's *blocking* behavior is
identical either way (only `size > max` ever blocked).
