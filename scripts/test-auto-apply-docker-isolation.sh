#!/usr/bin/env bash
#
# test-auto-apply-docker-isolation.sh — regression test for
# scripts/auto-apply-docker-isolation.sh.
#
# Exercises the acceptance criteria from docs/specs/2026-05-21-auto-apply-docker-isolation.md:
#   1. compose present            → docker-compose.override.yml written
#                                   (ports: !override, remapped host ports,
#                                    no original host binding for remapped svc),
#                                   stdout carries eval-safe export lines
#   2. compose absent             → no-op (exit 0, no file, "no compose" msg)
#   3. allocation failure         → logs warning + exit 0 (no file when all fail)
#   4. no worker slot             → no-op (exit 0, no file, "no slot" msg)
#   5. idempotency                → re-run produces byte-identical override
#   6. long-form (dict) ports     → unsupported-shape warning + exit 0, no file
#
# Tests are hermetic: a stub allocator is dropped into the tmpdir so no real
# port probing happens, and no `docker compose` is ever invoked. A "failing"
# stub allocator exercises the graceful-fallback path.
#
# Style matches scripts/test-check-claude-md-size.sh (bash, colored output,
# pass/fail counter, no external harness).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/auto-apply-docker-isolation.sh"

if [[ ! -f "$HELPER" ]]; then
  echo "test-auto-apply-docker-isolation: $HELPER not found" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_BOLD=""
  C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say() { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# ---------------------------------------------------------------------------
# Stub allocators. The real allocator probes ports; for hermetic tests we want
# deterministic, fast output.
#
# "ok" stub: echoes a deterministic port derived from the --service + --desired-port
#            so the test can assert exact remapped values.
# "fail" stub: always exits 1 (exercises graceful fallback).
# ---------------------------------------------------------------------------
ok_alloc="$tmpdir/alloc-ok.sh"
cat > "$ok_alloc" <<'STUB'
#!/usr/bin/env bash
# Deterministic stub: returns (desired-port + 1) so the output differs from the
# host port the caller asked to remap, and is easy to assert on.
set -euo pipefail
desired=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desired-port) desired="$2"; shift 2 ;;
    --worker-slot|--service|--base-port|--ports-per-slot|--probe-host) shift 2 ;;
    *) shift ;;
  esac
done
echo $(( desired + 1 ))
STUB
chmod +x "$ok_alloc"

fail_alloc="$tmpdir/alloc-fail.sh"
cat > "$fail_alloc" <<'STUB'
#!/usr/bin/env bash
echo "stub-alloc: no free port (forced failure)" >&2
exit 1
STUB
chmod +x "$fail_alloc"

# "echo-desired" stub: returns the --desired-port verbatim. Used to reproduce
# the duplicate-port collision (two services asking for the SAME desired port
# would both get it back) — the caller must de-dup so the override never
# publishes the same worker port twice.
echo_alloc="$tmpdir/alloc-echo.sh"
cat > "$echo_alloc" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
desired=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desired-port) desired="$2"; shift 2 ;;
    --worker-slot|--service|--base-port|--ports-per-slot|--probe-host) shift 2 ;;
    *) shift ;;
  esac
done
echo "$desired"
STUB
chmod +x "$echo_alloc"

# Helper: create a worktree dir + a repo dir with a compose file of given content.
make_case() {
  local name="$1" compose_body="$2"
  local wt="$tmpdir/$name/wt"
  local repo="$tmpdir/$name/repo"
  mkdir -p "$wt" "$repo"
  if [[ -n "$compose_body" ]]; then
    printf '%s\n' "$compose_body" > "$repo/docker-compose.yml"
  fi
  echo "$wt|$repo"
}

# Standard two-service compose: postgres 5432, web 3000.
COMPOSE_TWO='services:
  postgres:
    image: postgres:16
    ports:
      - "5432:5432"
  web:
    image: node:20
    ports:
      - "3000:3000"'

# ---------- Test 1: compose present → override written ----------
say "Test 1: compose present (pg 5432, web 3000) → override written"
IFS='|' read -r wt repo <<< "$(make_case t1 "$COMPOSE_TWO")"
set +e
out="$(NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id Worker-AA --allocator "$ok_alloc" 2> "$tmpdir/t1.err")"
ec=$?
set -e
override="$wt/docker-compose.override.yml"
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec; stderr: $(cat "$tmpdir/t1.err")"; fi
if [[ -f "$override" ]]; then ok "override file written"; else bad "expected override at $override"; fi
if [[ -f "$override" ]] && grep -q "ports: !override" "$override"; then
  ok "override uses 'ports: !override'"
else
  bad "expected 'ports: !override' in override; got: $( [[ -f "$override" ]] && cat "$override" )"
fi
# ok stub returns desired+1. Desired for pg = 40000 + 0*100 + (5432 mod 100=32) = 40032 → 40033.
if [[ -f "$override" ]] && grep -q '"40033:5432"' "$override"; then
  ok "postgres host port remapped to 40033"
else
  bad "expected '40033:5432' remap; got: $( [[ -f "$override" ]] && cat "$override" )"
fi
# Desired for web = 40000 + 0 + (3000 mod 100=0) = 40000 → 40001.
if [[ -f "$override" ]] && grep -q '"40001:3000"' "$override"; then
  ok "web host port remapped to 40001"
else
  bad "expected '40001:3000' remap; got: $( [[ -f "$override" ]] && cat "$override" )"
fi
# The remapped service must NOT still publish the original host binding.
if [[ -f "$override" ]] && grep -q '"5432:5432"' "$override"; then
  bad "override still contains original '5432:5432' binding (collision unfixed)"
else
  ok "override does not re-publish original host binding"
fi
# stdout must carry eval-safe export lines (only 'export ...').
if grep -q '^export COMPOSE_PROJECT_NAME=' <<< "$out"; then
  ok "stdout exports COMPOSE_PROJECT_NAME"
else
  bad "expected 'export COMPOSE_PROJECT_NAME=' on stdout; got: $out"
fi
if grep -q '^export HYDRA_POSTGRES_PORT=40033' <<< "$out"; then
  ok "stdout exports HYDRA_POSTGRES_PORT=40033"
else
  bad "expected 'export HYDRA_POSTGRES_PORT=40033' on stdout; got: $out"
fi
# Project name is sanitized (lowercase).
if grep -q '^export COMPOSE_PROJECT_NAME=hydra-worker-aa$' <<< "$out"; then
  ok "COMPOSE_PROJECT_NAME sanitized to lowercase (hydra-worker-aa)"
else
  bad "expected sanitized 'hydra-worker-aa'; got: $out"
fi
# Every stdout line must be an export (eval-safe). Ignore blank lines.
nonexport="$(grep -vE '^(export .*)?$' <<< "$out" || true)"
if [[ -z "$nonexport" ]]; then
  ok "stdout is eval-safe (only export lines)"
else
  bad "stdout has non-export lines (not eval-safe): $nonexport"
fi

# ---------- Test 2: compose absent → no-op ----------
say "Test 2: compose absent → no-op (exit 0, no file)"
IFS='|' read -r wt repo <<< "$(make_case t2 "")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --allocator "$ok_alloc" > "$tmpdir/t2.out" 2> "$tmpdir/t2.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ ! -f "$wt/docker-compose.override.yml" ]]; then ok "no override written"; else bad "override should NOT exist"; fi
if grep -qi "no compose\|no docker-compose\|skipping" "$tmpdir/t2.err"; then
  ok "logs a no-compose / skipping message"
else
  bad "expected a no-compose message on stderr; got: $(cat "$tmpdir/t2.err")"
fi

# ---------- Test 3: allocation failure → logs + exit 0 ----------
say "Test 3: every allocation fails → warns + exit 0, no file"
IFS='|' read -r wt repo <<< "$(make_case t3 "$COMPOSE_TWO")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --allocator "$fail_alloc" > "$tmpdir/t3.out" 2> "$tmpdir/t3.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "exit 0 (spawn not aborted)"; else bad "expected exit 0, got $ec"; fi
if grep -qi "warn\|fail\|could not allocate\|skip" "$tmpdir/t3.err"; then
  ok "logs an allocation-failure warning"
else
  bad "expected an allocation-failure warning on stderr; got: $(cat "$tmpdir/t3.err")"
fi
if [[ ! -f "$wt/docker-compose.override.yml" ]]; then
  ok "no override written when every allocation fails"
else
  bad "override should NOT exist when all allocations fail; got: $(cat "$wt/docker-compose.override.yml")"
fi

# ---------- Test 4: no slot → no-op ----------
say "Test 4: no --worker-slot and HYDRA_WORKER_SLOT unset → no-op"
IFS='|' read -r wt repo <<< "$(make_case t4 "$COMPOSE_TWO")"
set +e
env -u HYDRA_WORKER_SLOT NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --allocator "$ok_alloc" > "$tmpdir/t4.out" 2> "$tmpdir/t4.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ ! -f "$wt/docker-compose.override.yml" ]]; then ok "no override written"; else bad "override should NOT exist without a slot"; fi
if grep -qi "no.*slot\|no worker slot\|skipping" "$tmpdir/t4.err"; then
  ok "logs a no-slot message"
else
  bad "expected a no-slot message on stderr; got: $(cat "$tmpdir/t4.err")"
fi

# ---------- Test 5: idempotency ----------
say "Test 5: re-run produces byte-identical override (no port stacking)"
IFS='|' read -r wt repo <<< "$(make_case t5 "$COMPOSE_TWO")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 1 --worker-id w5 --allocator "$ok_alloc" > /dev/null 2> "$tmpdir/t5a.err"
ec1=$?
cp "$wt/docker-compose.override.yml" "$tmpdir/t5.first" 2>/dev/null
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 1 --worker-id w5 --allocator "$ok_alloc" > /dev/null 2> "$tmpdir/t5b.err"
ec2=$?
set -e
if [[ "$ec1" -eq 0 && "$ec2" -eq 0 ]]; then ok "both runs exit 0"; else bad "expected both exit 0, got $ec1/$ec2"; fi
if [[ -f "$tmpdir/t5.first" ]] && diff -q "$tmpdir/t5.first" "$wt/docker-compose.override.yml" > /dev/null 2>&1; then
  ok "second run override is byte-identical to first"
else
  bad "override differs between runs (port stacking?):"
  diff "$tmpdir/t5.first" "$wt/docker-compose.override.yml" 2>&1 | sed 's/^/    /' || true
fi
# Sanity: the override has exactly one ports block per service (no duplicate
# service keys appended).
pg_count="$(grep -c '^  postgres:' "$wt/docker-compose.override.yml" || true)"
if [[ "$pg_count" -eq 1 ]]; then
  ok "exactly one postgres service block (no duplication)"
else
  bad "expected 1 postgres block, found $pg_count"
fi

# ---------- Test 6: long-form (dict) ports fall through ----------
say "Test 6: long-form dict ports only → unsupported-shape warning, no file"
COMPOSE_LONGFORM='services:
  db:
    image: postgres:16
    ports:
      - target: 5432
        published: 5432
        protocol: tcp'
IFS='|' read -r wt repo <<< "$(make_case t6 "$COMPOSE_LONGFORM")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --allocator "$ok_alloc" > "$tmpdir/t6.out" 2> "$tmpdir/t6.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "exit 0 (graceful)"; else bad "expected exit 0, got $ec"; fi
if grep -qi "long.form\|unsupported\|dict\|skip" "$tmpdir/t6.err"; then
  ok "warns about unsupported long-form ports"
else
  bad "expected an unsupported-shape warning; got: $(cat "$tmpdir/t6.err")"
fi
if [[ ! -f "$wt/docker-compose.override.yml" ]]; then
  ok "no (malformed) override written for long-form-only compose"
else
  bad "override should NOT exist when only long-form ports present; got: $(cat "$wt/docker-compose.override.yml")"
fi

# ---------- Test 7: duplicate-offset ports get distinct worker ports ----------
# Two services whose host ports share the same (host mod 100) offset would, with
# a naive desired-port formula, ask for the SAME desired port. With the
# echo-desired stub (returns desired verbatim), a buggy helper would emit the
# same worker port twice → docker compose up collides. The helper must de-dup.
say "Test 7: two services with same mod-100 offset → distinct worker ports"
COMPOSE_DUP='services:
  alpha:
    image: a
    ports:
      - "3000:3000"
  beta:
    image: b
    ports:
      - "8000:8000"'
IFS='|' read -r wt repo <<< "$(make_case t7 "$COMPOSE_DUP")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id dup --allocator "$echo_alloc" > "$tmpdir/t7.out" 2> "$tmpdir/t7.err"
ec=$?
set -e
override="$wt/docker-compose.override.yml"
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
# Collect the host-side worker ports from the override.
host_ports="$(grep -oE '"[0-9]+:[0-9]+"' "$override" 2>/dev/null | sed -E 's/"([0-9]+):.*/\1/' | sort)"
uniq_count="$(printf '%s\n' "$host_ports" | sort -u | grep -c . || true)"
total_count="$(printf '%s\n' "$host_ports" | grep -c . || true)"
if [[ "$total_count" -eq 2 && "$uniq_count" -eq 2 ]]; then
  ok "two distinct worker host ports allocated (no duplicate)"
else
  bad "expected 2 distinct host ports; got $total_count total / $uniq_count unique:"
  printf '%s\n' "$host_ports" | sed 's/^/    /'
fi

# ---------- Test 8: loopback host-IP prefix preserved ----------
# A base entry "127.0.0.1:5432:5432" deliberately binds loopback only. The
# remap must keep the IP so the service stays loopback-only (dropping it would
# bind on all interfaces — a security regression).
say "Test 8: host-IP short form keeps the loopback prefix in the remap"
COMPOSE_LOOPBACK='services:
  db:
    image: postgres:16
    ports:
      - "127.0.0.1:5432:5432"'
IFS='|' read -r wt repo <<< "$(make_case t8 "$COMPOSE_LOOPBACK")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id lb --allocator "$ok_alloc" > "$tmpdir/t8.out" 2> "$tmpdir/t8.err"
ec=$?
set -e
override="$wt/docker-compose.override.yml"
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
# ok stub: desired = 40000 + (5432 mod 100 = 32) = 40032 → returns 40033.
if [[ -f "$override" ]] && grep -q '"127.0.0.1:40033:5432"' "$override"; then
  ok "remap preserves loopback IP (127.0.0.1:40033:5432)"
else
  bad "expected '127.0.0.1:40033:5432'; got: $( [[ -f "$override" ]] && cat "$override" )"
fi
# Must NOT emit an all-interfaces binding (no bare "40033:5432" line).
if [[ -f "$override" ]] && grep -qE '^\s*- "40033:5432"\s*$' "$override"; then
  bad "override emitted an all-interfaces binding, dropping the loopback IP"
else
  ok "no all-interfaces binding emitted"
fi

# ---------- Test 9: skipped ports carried through the !override block ----------
# A service with BOTH a remappable short-form port AND a container-only entry
# (no host binding). The !override block replaces the whole base list, so the
# helper must carry the un-remapped entry through verbatim or it vanishes from
# the compose model.
say "Test 9: service with a remapped + a passthrough port keeps both"
COMPOSE_MIXED='services:
  app:
    image: app
    ports:
      - "8080:8080"
      - "9090"'
IFS='|' read -r wt repo <<< "$(make_case t9 "$COMPOSE_MIXED")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id mixed --allocator "$ok_alloc" > "$tmpdir/t9.out" 2> "$tmpdir/t9.err"
ec=$?
set -e
override="$wt/docker-compose.override.yml"
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
# 8080 mod 100 = 80 → desired 40080 → ok stub returns 40081.
if [[ -f "$override" ]] && grep -q '"40081:8080"' "$override"; then
  ok "short-form port remapped (40081:8080)"
else
  bad "expected '40081:8080'; got: $( [[ -f "$override" ]] && cat "$override" )"
fi
# The container-only "9090" entry must survive in the !override block.
if [[ -f "$override" ]] && grep -qE '"?9090"?' "$override"; then
  ok "passthrough container-only port (9090) carried through"
else
  bad "container-only '9090' was dropped from the !override block; got: $( [[ -f "$override" ]] && cat "$override" )"
fi

# ---------- Test 10: alloc-failed port in a multi-port service is preserved ----------
# Service with two short-form ports; allocator fails for BOTH (fail stub). With
# every port unremappable the service has nothing to !override, so no service
# block should be written for it (writing an empty/partial !override would drop
# the base ports). Net: no override file at all (single service, all failed).
say "Test 10: multi-port service, all allocations fail → no partial override"
COMPOSE_TWOPORT='services:
  multi:
    image: m
    ports:
      - "5432:5432"
      - "6379:6379"'
IFS='|' read -r wt repo <<< "$(make_case t10 "$COMPOSE_TWOPORT")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id allfail --allocator "$fail_alloc" > "$tmpdir/t10.out" 2> "$tmpdir/t10.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "exit 0 (graceful)"; else bad "expected exit 0, got $ec"; fi
if [[ ! -f "$wt/docker-compose.override.yml" ]]; then
  ok "no partial override written when all allocations fail"
else
  bad "override should NOT exist when all allocations fail; got: $(cat "$wt/docker-compose.override.yml")"
fi

# ---------- Test 11: do not clobber a pre-existing non-Hydra override ----------
# If the worktree already has a docker-compose.override.yml that Hydra did NOT
# generate (no generator marker), the helper must refuse to overwrite it.
say "Test 11: pre-existing non-Hydra override → not clobbered, warn, exit 0"
IFS='|' read -r wt repo <<< "$(make_case t11 "$COMPOSE_TWO")"
preexisting='services:
  postgres:
    environment:
      FOO: bar'
printf '%s\n' "$preexisting" > "$wt/docker-compose.override.yml"
before_hash="$(cksum "$wt/docker-compose.override.yml")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id pre --allocator "$ok_alloc" > "$tmpdir/t11.out" 2> "$tmpdir/t11.err"
ec=$?
set -e
after_hash="$(cksum "$wt/docker-compose.override.yml")"
if [[ "$ec" -eq 0 ]]; then ok "exit 0 (graceful)"; else bad "expected exit 0, got $ec"; fi
if [[ "$before_hash" == "$after_hash" ]]; then
  ok "pre-existing override left untouched"
else
  bad "pre-existing override was clobbered; now: $(cat "$wt/docker-compose.override.yml")"
fi
if grep -qi "exist\|not.*overwrit\|refus\|skip" "$tmpdir/t11.err"; then
  ok "warns about the pre-existing override"
else
  bad "expected a pre-existing-override warning; got: $(cat "$tmpdir/t11.err")"
fi

# ---------- Test 12: a Hydra-generated override IS safe to regenerate ----------
# The idempotency path must still work when the existing file is one WE wrote.
say "Test 12: pre-existing Hydra-generated override → regenerated fine"
IFS='|' read -r wt repo <<< "$(make_case t12 "$COMPOSE_TWO")"
# First run creates a genuine Hydra override.
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id regen --allocator "$ok_alloc" > /dev/null 2> "$tmpdir/t12a.err"
first="$(cat "$wt/docker-compose.override.yml")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id regen --allocator "$ok_alloc" > /dev/null 2> "$tmpdir/t12b.err"
ec=$?
set -e
second="$(cat "$wt/docker-compose.override.yml")"
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ "$first" == "$second" ]]; then
  ok "Hydra-generated override regenerated identically (not blocked as foreign)"
else
  bad "regeneration changed the override (or was blocked)"
fi

# ---------- Test 13: service mixing long-form + short-form is left intact ----------
# If a service has BOTH a long-form dict port and a remappable short-form port,
# the helper must NOT override that service (we can't safely reproduce the
# long-form entry), so neither port is remapped and no block is written for it.
say "Test 13: mixed long-form + short-form service → service skipped entirely"
COMPOSE_MIXED_LONG='services:
  gw:
    image: gw
    ports:
      - "8080:8080"
      - target: 9000
        published: 9000
        protocol: tcp'
IFS='|' read -r wt repo <<< "$(make_case t13 "$COMPOSE_MIXED_LONG")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id mixlong --allocator "$ok_alloc" > "$tmpdir/t13.out" 2> "$tmpdir/t13.err"
ec=$?
set -e
override="$wt/docker-compose.override.yml"
if [[ "$ec" -eq 0 ]]; then ok "exit 0 (graceful)"; else bad "expected exit 0, got $ec"; fi
# 'gw' is the only service and it has a long-form entry → it must be skipped, so
# no override block for it. With no other remappable service, no file is written.
if [[ ! -f "$override" ]]; then
  ok "no override written (the only service was skipped for long-form safety)"
else
  bad "override should not exist; the short-form port of a long-form service was remapped: $(cat "$override")"
fi
if grep -qi "long.form\|mixed\|unsupported\|skip" "$tmpdir/t13.err"; then
  ok "warns the service was skipped"
else
  bad "expected a skip warning; got: $(cat "$tmpdir/t13.err")"
fi

# ---------- Test 14: a clean sibling is still remapped when another is skipped ----------
# Mixed long-form service is skipped, but a separate short-form-only service is
# still remapped (the skip is per-service, not global).
say "Test 14: long-form service skipped, clean sibling still remapped"
COMPOSE_MIX_SIBLING='services:
  gw:
    image: gw
    ports:
      - "8080:8080"
      - target: 9000
        published: 9000
  db:
    image: postgres
    ports:
      - "5432:5432"'
IFS='|' read -r wt repo <<< "$(make_case t14 "$COMPOSE_MIX_SIBLING")"
set +e
NO_COLOR=1 bash "$HELPER" --worktree "$wt" --repo-path "$repo" \
  --worker-slot 0 --worker-id sibling --allocator "$ok_alloc" > "$tmpdir/t14.out" 2> "$tmpdir/t14.err"
ec=$?
set -e
override="$wt/docker-compose.override.yml"
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ -f "$override" ]] && grep -q '"40033:5432"' "$override"; then
  ok "clean sibling 'db' still remapped (40033:5432)"
else
  bad "expected db remapped to 40033:5432; got: $( [[ -f "$override" ]] && cat "$override" )"
fi
# 'gw' must NOT appear (it was skipped for long-form safety).
if [[ -f "$override" ]] && grep -qE '^\s*gw:' "$override"; then
  bad "'gw' (long-form service) should not be in the override; got: $(cat "$override")"
else
  ok "long-form service 'gw' correctly omitted from the override"
fi

# ---------- summary ----------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-auto-apply-docker-isolation: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-auto-apply-docker-isolation: FAIL${C_RESET} (%d passed, %d failed)\n" \
  "$passed" "$failed" >&2
exit 1
