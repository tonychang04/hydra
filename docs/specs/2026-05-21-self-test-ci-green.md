# Make self-test CI green: fix 3 pre-existing baseline failures

**Ticket:** #201 · **Tier:** T2 · **Pillar:** P1 (observability / trust — green CI)

## Problem

The "Self-test (script-kind cases)" CI job (`./self-test/run.sh --kind=script`,
`.github/workflows/ci.yml`) has been RED on `main` since before the 2026-05-21
batch. It is a non-required check, so it never blocked merges — but a permanently
red CI lane erodes the signal that the harness exists to provide (catching when a
Commander change makes worker output worse). Three cases fail in a CI-like
environment (ubuntu, only `jq` installed → no `claude`, no `flyctl`; fake creds):

1. **`mcp-server-starts` step 8** — asserts `mcp/hydra-tools.json` "has 13 tools",
   but the manifest now has 14.
2. **`activity-command-smoke` step 4** — "top memory citation not rendered".
3. **`migrate-to-cloud-dry-run` step 5** — `--dry-run --non-interactive` passes
   locally, hard-fails in CI.

### Root causes (evidence-first)

1. **Stale golden count.** `mcp/hydra-tools.json` has 14 tools. The 14th,
   `hydra.file_ticket`, was added legitimately in PR #153 (ticket #143); it has a
   registered handler (`scripts/hydra-mcp-server.py:798`) and no duplicate. Step 9
   of the same case (`HANDLERS_COMPLETE`) already diffs contract↔server
   dynamically and passes. The hardcoded `== 13` in step 8 was simply not bumped
   when #143 landed. The count is correct at 14; the assertion is stale.

2. **Time-bomb fixture.** `scripts/hydra-activity.sh:246-258` filters citations to
   `last_cited >= (today − 7d)` — correct behavior. The smoke fixture
   `self-test/fixtures/hydra-activity/state/memory-citations.json` hardcodes
   absolute `last_cited` dates (`2026-04-14/15/16`). The case passed when authored
   (April 2026) but rots once wall-clock passes 2026-04-23; all citations now read
   as "no recent citations", so `grep "npm install strips peer markers"` fails.
   The `--json` check (`.citations_top | length >= 1`) shares the same latent
   failure. The script is correct; the fixture is the bug. The harness already
   stamps **relative** mtimes on its log fixtures (lines 44-47) for exactly this
   reason — citations were missed.

3. **Dry-run is not environment-independent.**
   `scripts/hydra-migrate-to-cloud.sh:181,196-202` hard-`fail`s preflight if
   `flyctl` / `claude` / `gh` are not *installed* — even in `--dry-run`. The
   dry-run never *invokes* these binaries (it logs "would run X"), so requiring
   them present contradicts the script's own documented intent ("no claude
   invocation"; rehearse without side effects). The flyctl-*auth* check is already
   downgraded for dry-run (line 186-193); the binary-*presence* checks were not.
   Locally all binaries exist (passes); CI has neither flyctl nor claude (fails).

## Goals

- `./self-test/run.sh --kind=script` reports **0 failed** in a CI-like environment
  (no `claude`, no `flyctl`, fake creds). Appropriate skips are fine.
- Fix root causes; do not weaken assertions to pass.
- Keep the citation-window behavior under test (don't delete the assertion).

## Non-goals

- No change to `.github/workflows/*` (out of scope / hard-railed).
- No change to the real (non-dry-run) migration path's hard requirements.
- No new self-test cases; this is a repair of three existing cases/fixtures.

## Proposed approach

1. **`mcp-server-starts` step 8** — bump the golden assertion `== 13` → `== 14`
   and the step name "has 13 tools" → "has 14 tools" in
   `self-test/golden-cases.example.json`. Evidence: 14 distinct tools, all with
   handlers. (Alternative considered: remove a tool from the manifest — rejected,
   `file_ticket` is a real, shipped, handler-backed tool.)

2. **`activity-command-smoke`** — in `self-test/fixtures/hydra-activity/run-smoke.sh`,
   rewrite the fixture's citation `last_cited` dates to recent relative dates
   (today, today−1, today−2) at run time before invoking the script — the same
   relative-time technique already used for log mtimes. Restore the fixture file
   afterward so the committed fixture stays deterministic and git stays clean.
   (Alternative: change the script to a longer/configurable window — rejected,
   that changes production behavior to paper over a fixture bug. Alternative:
   delete the citation assertion — rejected, weakens coverage.)

3. **`migrate-to-cloud-dry-run`** — make dry-run genuinely environment-independent:
   in `scripts/hydra-migrate-to-cloud.sh`, when `DRY_RUN=1`, downgrade
   missing-`flyctl` / `claude` / `gh` from `fail` to a `DRY RUN:` notice. The real
   (non-dry-run) path keeps the hard `fail`. (Alternative: gate the case with
   `requires_flyctl` + `requires_claude_cli` so it SKIPs in CI — rejected as the
   weaker fix; the stronger acceptance bar is an env-independent dry-run that
   actually exercises the dry-run code path in CI.)

## Test plan

- Reproduce all 3 failures first in a CI-like env (PATH without `claude`/`flyctl`,
  `HYDRA_CI_SKIP_DOCKER=1`, fake creds). Confirmed before any edit.
- After each fix, re-run the specific case and confirm green.
- Final: run the full `./self-test/run.sh --kind=script` in the CI-like env and
  confirm **0 failed**. Paste output in the PR.
- Regression guard for fix #2: temporarily revert the fixture-date stamping and
  confirm the case fails again (proves the assertion still tests the window),
  then restore.
- Confirm `git status` is clean (run-smoke restores its fixture; no stray edits).

## Risks / rollback

- Fix #3 touches a production script. Risk: a real migration on a box missing
  flyctl/claude would now reach further into the (still-guarded, dry-run-only)
  flow. Mitigation: the downgrade is `DRY_RUN`-scoped only; real runs are
  unchanged and still hard-fail. The "no side effects in dry-run" case (step 7,
  stubbed PATH) continues to assert no real binary is invoked.
- Fix #2 mutates then restores a committed fixture during the test. Risk: an
  interrupted run leaves the fixture dirty. Mitigation: restore via a `trap` so it
  runs even on early exit.
- Rollback: revert the PR. All changes are isolated to self-test fixtures, the
  golden-cases example, and one dry-run-scoped branch in the migrate script.

## Codex-review hardening (added during review)

Two robustness findings from `/codex review` were applied:

1. **Re-stamp only existing keys.** A bare `.citations[key].last_cited = $d`
   *creates* the key if absent; `hydra-activity.sh` renders an entry with a
   missing count as count 0, so a renamed/trimmed fixture could still satisfy the
   assertions. The jq now uses `has()` + `error()` so a missing target key fails
   the harness loudly. Verified: renaming a fixture key makes the case FAIL with
   "citation fixture key missing".

2. **Deterministic env-independence coverage.** The dry-run case never exercised
   the new missing-binary branch with *genuinely* absent binaries (step 7 uses
   stubs that `command -v` finds; the ambient-PATH step usually has the tools), so
   a regression reintroducing the hard-fail could pass on dev machines. Added a
   step that runs `--dry-run` under a restricted PATH that strips flyctl/fly/
   claude/gh and asserts exit 0 + the "not installed" notice. Verified:
   reintroducing the dry-run hard-fail makes this step FAIL.
