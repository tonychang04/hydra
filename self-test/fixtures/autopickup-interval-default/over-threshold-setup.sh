#!/usr/bin/env bash
# Fixture for test-autopickup-interval-default.sh (#316): a setup.sh stub whose
# inline autopickup.json seed uses an over-threshold interval_min (30), so the
# drift guard's setup.sh-seed check must red against it. NOT a real installer.
case "$f" in
  */autopickup.json)       echo '{"enabled": false, "interval_min": 30, "auto_enable_on_session_start": true, "last_run": null, "last_picked_count": 0, "consecutive_rate_limit_hits": 0}' > "$f" ;;
esac
