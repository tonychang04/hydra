# Validation contract — #306

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | Detector runs clean on empty active.json: 0 stalls, exit 0 | `echo '{"workers":[]}' > $T/active.json; bash scripts/detect-worker-stalls.sh --json --no-log --state-dir $T` | exit 0; `.stall_count == 0` | PASS | `exit=0 stall_count=0` |
| 2 | Detector flags a stale running worker: 1 stall, verdict stalled | `bash scripts/detect-worker-stalls.sh --json --no-log --state-dir <fixture> --now 2026-06-18T12:00:00Z` (worker started 11:30Z → idle 30m > 12m) | exit 0; `.stall_count == 1`, `.stalls[0].verdict == "stalled"` | PASS | `exit=0 stall_count=1 verdict=stalled` |
| 3 | A paused-on-question worker older than threshold is NOT flagged | `bash scripts/test-detect-worker-stalls.sh` (Test 4) | test PASS | PASS | `Test 4 ... PASS paused workers (both spellings) not flagged` |
| 4 | `--trends` emits a top-N failure-mode list | `bash scripts/detect-worker-stalls.sh --trends --json --logs-dir <fixture-logs>` (2 failed logs) | exit 0; `.trends` non-empty `{mode,count}` array | PASS | `exit=0 trends=[{"mode":"failed","count":2}]` |
| 5 | autopickup-tick.sh --json output contains a `stalls` key | `bash scripts/autopickup-tick.sh --json --no-rescue --no-merge-surface --state-dir <fixture> 2>/dev/null \| jq -e 'has("stalls")'` | exit 0; prints `true` | PASS | `exit=0 has_stalls=true` |
| 6 | Detector self-test suite passes | `NO_COLOR=1 bash scripts/test-detect-worker-stalls.sh` | exit 0; all PASS, 0 FAIL | PASS | `24 passed, 0 failed` |
| 7 | State validation still clean | `bash scripts/validate-state-all.sh` | exit 0 | PASS | `validate-state-all: OK (2 passed, 17 skipped); exit=0` |
| 8 | Existing tick smoke fixtures still pass (no regression) | `for f in self-test/fixtures/autopickup-tick-*/run-smoke.sh; do bash "$f"; done` | each prints `SMOKE_OK` | PASS | `audit/digest/scheduled → SMOKE_OK` |
