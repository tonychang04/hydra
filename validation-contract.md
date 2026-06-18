# Validation contract — #306

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | Detector runs clean on empty active.json: 0 stalls, exit 0 | `tmp=$(mktemp -d); echo '{"workers":[]}' > "$tmp/active.json"; bash scripts/detect-worker-stalls.sh --json --no-log --state-dir "$tmp"; echo "exit=$?"` | exit 0; JSON `.stall_count == 0` | UNVERIFIED | |
| 2 | Detector flags a stale running worker: 1 stall flagged | `bash scripts/detect-worker-stalls.sh --json --no-log --state-dir <fixture-with-stale-running-worker> --now <fixed>` | exit 0; JSON `.stall_count == 1`, `.stalls[0].verdict == "stalled"` | UNVERIFIED | |
| 3 | A paused-on-question worker older than threshold is NOT flagged | covered by `scripts/test-detect-worker-stalls.sh` | test PASS | UNVERIFIED | |
| 4 | `--trends` emits a top-N failure-mode list | `bash scripts/detect-worker-stalls.sh --trends --json --state-dir <fixture> --logs-dir <fixture-logs>` | exit 0; JSON `.trends` is a non-empty array of `{mode,count}` | UNVERIFIED | |
| 5 | autopickup-tick.sh --json output contains a `stalls` key | `bash scripts/autopickup-tick.sh --json --no-rescue --no-merge-surface --state-dir <fixture> 2>/dev/null | jq -e 'has("stalls")'` | exit 0; prints `true` | UNVERIFIED | |
| 6 | Detector self-test suite passes | `bash scripts/test-detect-worker-stalls.sh` | exit 0; all PASS, 0 FAIL | UNVERIFIED | |
| 7 | State validation still clean | `bash scripts/validate-state-all.sh; echo "exit=$?"` | exit 0 | UNVERIFIED | |
