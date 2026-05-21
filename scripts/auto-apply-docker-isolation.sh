#!/usr/bin/env bash
#
# auto-apply-docker-isolation.sh — scaffold a worker-scoped
# docker-compose.override.yml at spawn time so parallel Hydra workers don't
# collide on host ports.
#
# Context: .claude/agents/worker-implementation.md ("Docker isolation for
# parallel workers") and docs/specs/2026-04-16-worker-port-isolation.md
# describe two layers a worker must apply before `docker compose up`:
#   Layer 1 — namespace the Compose project (COMPOSE_PROJECT_NAME)
#   Layer 2 — remap each published host port into the worker's slot range,
#             written to a docker-compose.override.yml with `ports: !override`.
# Both were *delegated to the worker*; if a worker forgets Layer 2, two
# parallel `docker compose up` runs collide on e.g. 5432:5432 and the second
# dies with "bind: address already in use". This helper applies both layers
# automatically so isolation happens whether or not the worker thinks about it.
# Spec: docs/specs/2026-05-21-auto-apply-docker-isolation.md (ticket #178).
#
# It does NOT run `docker compose up`/`down` — bring-up, teardown, and the
# `down -v` trap stay the worker's job (unchanged). It only writes the override
# file and emits the env exports a caller should source:
#
#   eval "$(scripts/auto-apply-docker-isolation.sh --worktree "$WT" \
#             --repo-path "$REPO" --worker-slot "$SLOT")"
#
# Behavior:
#   - No docker-compose.yml in --repo-path        → no-op, exit 0.
#   - No worker slot (flag unset + HYDRA_WORKER_SLOT unset) → no-op, exit 0.
#   - Allocation fails for a service              → warn + continue (graceful).
#   - Zero ports allocated (none published / all failed) → no file, exit 0.
#   - Idempotent: the override is fully regenerated each run (never appended).
#
# stdout: ONLY `export …` lines (eval-safe). All human-readable logging is on
#         stderr.
#
# Exit codes:
#   0  success, or any graceful-fallback path (no compose / no slot / partial
#      or total allocation failure). The whole point is to never abort a spawn.
#   2  usage error (bad flags).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: auto-apply-docker-isolation.sh [options]

Scaffolds a worker-scoped docker-compose.override.yml (namespaced Compose
project + slot-remapped host ports) in the worktree root. No-op when there is
no compose file or no worker slot. Never aborts on allocation failure.

Options:
  --worktree <path>      Worktree root; the override is written here.
                         Default: current directory.
  --repo-path <path>     Directory containing docker-compose.yml.
                         Default: the worktree.
  --worker-slot <N>      Worker slot (non-negative int). Default: $HYDRA_WORKER_SLOT.
  --worker-id <id>       Worker id for the Compose project name.
                         Default: $HYDRA_WORKER_ID, else "worker-$$".
  --compose-file <name>  Compose filename to read. Default: docker-compose.yml.
  --allocator <path>     Port allocator script.
                         Default: sibling scripts/alloc-worker-port.sh.
  --base-port <N>        Slot-0 base port (forwarded to the allocator). Default 40000.
  --ports-per-slot <N>   Slot width (forwarded to the allocator). Default 100.
  --quiet                Suppress the informational "skipping" messages.
  -h, --help             Show this help.

Exit codes:
  0  success or graceful fallback (no compose / no slot / alloc failure)
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# Defaults + arg parsing.
# ---------------------------------------------------------------------------
worktree="$PWD"
repo_path=""
worker_slot="${HYDRA_WORKER_SLOT:-}"
worker_id="${HYDRA_WORKER_ID:-worker-$$}"
compose_file="docker-compose.yml"
allocator="$SCRIPT_DIR/alloc-worker-port.sh"
base_port=40000
ports_per_slot=100
quiet=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)       [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --worktree needs a value" >&2; exit 2; }; worktree="$2"; shift 2 ;;
    --repo-path)      [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --repo-path needs a value" >&2; exit 2; }; repo_path="$2"; shift 2 ;;
    --worker-slot)    [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --worker-slot needs a value" >&2; exit 2; }; worker_slot="$2"; shift 2 ;;
    --worker-id)      [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --worker-id needs a value" >&2; exit 2; }; worker_id="$2"; shift 2 ;;
    --compose-file)   [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --compose-file needs a value" >&2; exit 2; }; compose_file="$2"; shift 2 ;;
    --allocator)      [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --allocator needs a value" >&2; exit 2; }; allocator="$2"; shift 2 ;;
    --base-port)      [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --base-port needs a value" >&2; exit 2; }; base_port="$2"; shift 2 ;;
    --ports-per-slot) [[ $# -ge 2 ]] || { echo "auto-apply-docker-isolation: --ports-per-slot needs a value" >&2; exit 2; }; ports_per_slot="$2"; shift 2 ;;
    --quiet)          quiet=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "auto-apply-docker-isolation: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# repo_path defaults to the worktree if not given.
[[ -n "$repo_path" ]] || repo_path="$worktree"

# Informational logging — stderr, gated by --quiet.
info() { [[ "$quiet" -eq 1 ]] || printf 'auto-apply-docker-isolation: %s\n' "$*" >&2; }
# Warnings always print (they signal a degraded but non-fatal outcome).
warn() { printf 'auto-apply-docker-isolation: WARN: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# No-op gate 1: no compose file → nothing to isolate.
# ---------------------------------------------------------------------------
compose_path="$repo_path/$compose_file"
if [[ ! -f "$compose_path" ]]; then
  info "no $compose_file in $repo_path — skipping docker isolation"
  exit 0
fi

# ---------------------------------------------------------------------------
# No-op gate 2: no worker slot → run outside Commander's parallel spawn path,
# so there is no parallelism to protect.
# ---------------------------------------------------------------------------
if [[ -z "$worker_slot" ]]; then
  info "no worker slot (set --worker-slot or HYDRA_WORKER_SLOT) — skipping docker isolation"
  exit 0
fi
if ! [[ "$worker_slot" =~ ^[0-9]+$ ]]; then
  echo "auto-apply-docker-isolation: --worker-slot must be a non-negative integer (got: $worker_slot)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Layer 1 — Compose project name. Sanitize: lowercase, keep only [a-z0-9_-],
# everything else → '-'. (Compose rejects uppercase / exotic chars.)
# ---------------------------------------------------------------------------
sanitized_id="$(printf '%s' "$worker_id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-_' '-')"
project_name="hydra-${sanitized_id}"

# ---------------------------------------------------------------------------
# Enumerate published ports from the compose file.
#
# No yq on the host, so we line-scan. We support the documented short forms:
#   - "5432:5432"
#   - 5432:5432
#   - "${PG_PORT:-5432}:5432"
#   - "127.0.0.1:5432:5432"   (host-ip:host-port:container-port)
# We deliberately do NOT try to handle the long-form dict mapping
#   - target: 5432
#     published: 5432
# — if a service's ports: block contains those keys, we warn and skip that
# service (graceful fallback) rather than emit a wrong override.
#
# We track the current service name (the key directly under `services:`) and,
# while inside a `ports:` list, each list entry.
# ---------------------------------------------------------------------------

# Parallel arrays of allocated results.
svc_names=()      # service name per allocated port
remap_lines=()    # "<allocated>:<container>" per allocated port
hydra_exports=()  # "HYDRA_<SVC>_PORT=<allocated>" per allocated port

current_service=""
in_services=0
in_ports=0
ports_indent=-1
saw_longform=0
longform_services=""

# Compute leading-space count of a line.
indent_of() {
  local line="$1" expanded
  expanded="${line%%[![:space:]]*}"
  printf '%s' "${#expanded}"
}

# Uppercase + sanitize a service name for an env var (HYDRA_<SVC>_PORT).
env_name_for() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_'
}

allocate_for() {
  # $1 service, $2 host-port-token, $3 container-port
  local service="$1" host_tok="$2" container="$3"
  # Extract a numeric desired host port from the token if possible.
  # Tokens may be "5432", "${PG_PORT:-5432}", etc. Pull the trailing digits.
  local host_num
  host_num="$(printf '%s' "$host_tok" | grep -oE '[0-9]+' | tail -1 || true)"
  [[ -n "$host_num" ]] || host_num="$container"
  local desired=$(( base_port + worker_slot * ports_per_slot + host_num % ports_per_slot ))
  local allocated rc
  set +e
  allocated="$("$allocator" --worker-slot "$worker_slot" --service "$service" \
    --desired-port "$desired" --base-port "$base_port" --ports-per-slot "$ports_per_slot" 2>/dev/null)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 || -z "$allocated" ]]; then
    warn "could not allocate a host port for service '$service' (container $container) — leaving it unmapped"
    return 0
  fi
  svc_names+=("$service")
  remap_lines+=("${allocated}:${container}")
  hydra_exports+=("HYDRA_$(env_name_for "$service")_PORT=${allocated}")
}

# Parse a single ports list entry, dispatch to allocate_for.
parse_ports_entry() {
  # $1 = the content after the leading "- " of a list item.
  local entry="$1"
  # Strip surrounding quotes and trailing comments/whitespace.
  entry="${entry%%#*}"
  entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  entry="${entry%\"}"; entry="${entry#\"}"
  entry="${entry%\'}"; entry="${entry#\'}"
  [[ -n "$entry" ]] || return 0

  # Count colons OUTSIDE of ${...} so we don't miscount "${PG:-5432}:5432".
  local stripped_braces
  stripped_braces="$(printf '%s' "$entry" | sed -E 's/\$\{[^}]*\}/X/g')"
  local colons="${stripped_braces//[^:]/}"
  local ncolon=${#colons}

  case "$ncolon" in
    0)
      # Single value, e.g. "5432" — container-only, host port auto-assigned by
      # Docker → no fixed host binding to collide → nothing to remap.
      return 0
      ;;
    1)
      # host:container
      local host="${entry%%:*}" container="${entry##*:}"
      allocate_for "$current_service" "$host" "$container"
      ;;
    2)
      # host-ip:host:container — drop the ip, keep host:container.
      local rest="${entry#*:}"           # host:container
      local host="${rest%%:*}" container="${rest##*:}"
      allocate_for "$current_service" "$host" "$container"
      ;;
    *)
      warn "unrecognized ports entry '$entry' in service '$current_service' — skipping"
      ;;
  esac
}

while IFS='' read -r raw || [[ -n "$raw" ]]; do
  # Skip blank / comment-only lines for structural parsing but they don't break
  # state (a blank line inside ports: doesn't end the block in our scan; the
  # next non-blank line's indent decides).
  line="${raw%$'\r'}"   # strip CR if present
  # Trimmed content (no leading space) for keyword matching.
  trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')"
  [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

  ind="$(indent_of "$line")"

  # Top-level `services:` key.
  if [[ "$ind" -eq 0 && "$trimmed" == services:* ]]; then
    in_services=1
    current_service=""
    in_ports=0
    continue
  fi
  # Any other top-level key ends the services section.
  if [[ "$ind" -eq 0 ]]; then
    in_services=0
    current_service=""
    in_ports=0
    continue
  fi

  [[ "$in_services" -eq 1 ]] || continue

  # A service name: a key (ends with ':') indented under services:, and NOT a
  # known service-property key, and not currently a deeper-indented line.
  # Services are the keys at the shallowest indent under `services:`. We detect
  # one as: indent <= 2-ish AND looks like "name:" with nothing after. To stay
  # robust to 2- or 4-space styles, treat any "<word>:" line whose indent is
  # less than the current ports_indent (or when not in ports) and that is not a
  # property keyword as a service header.
  if [[ "$in_ports" -eq 1 ]]; then
    # Inside a ports: block. List entries are deeper than ports_indent and
    # start with '-'. Anything at <= ports_indent ends the block.
    if [[ "$ind" -gt "$ports_indent" ]]; then
      if [[ "$trimmed" == -* ]]; then
        item="${trimmed#-}"
        item="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//')"
        # Long-form dict entry? (starts a mapping: target:/published:/protocol:)
        if [[ "$item" == target:* || "$item" == published:* || "$item" == protocol:* || "$item" == mode:* || "$item" == host_ip:* ]]; then
          saw_longform=1
          case "$longform_services" in
            *" $current_service "*) : ;;
            *) longform_services="$longform_services $current_service " ;;
          esac
        else
          parse_ports_entry "$item"
        fi
      else
        # A continuation line of a long-form dict entry (e.g. "published: 5432"
        # on its own, indented under the "- target:" item).
        if [[ "$trimmed" == published:* || "$trimmed" == target:* || "$trimmed" == protocol:* || "$trimmed" == mode:* || "$trimmed" == host_ip:* ]]; then
          saw_longform=1
          case "$longform_services" in
            *" $current_service "*) : ;;
            *) longform_services="$longform_services $current_service " ;;
          esac
        fi
      fi
      continue
    else
      in_ports=0
      # fall through to re-evaluate this line as a possible service/property.
    fi
  fi

  # `ports:` property of the current service.
  if [[ "$trimmed" == ports: || "$trimmed" == "ports:"* ]]; then
    in_ports=1
    ports_indent="$ind"
    continue
  fi

  # Otherwise: if this is a "name:" key and it's a service header (it lives
  # directly under services:, i.e. the shallowest property indent), record it.
  # Heuristic: a line of the form "<key>:" (optionally "<key>: value") whose
  # indent is small. We treat the FIRST indented key after `services:` as the
  # service indent and any key at that indent as a service.
  if [[ "$trimmed" == *:* ]]; then
    key="${trimmed%%:*}"
    # service-property keys we know are NOT services
    case "$key" in
      image|build|ports|environment|env_file|volumes|depends_on|networks|command|entrypoint|restart|healthcheck|container_name|expose|labels|deploy|profiles|working_dir|user|ulimits|cap_add|cap_drop|tmpfs|extra_hosts|dns|logging|stop_grace_period|stop_signal|sysctls|shm_size|platform|hostname|domainname|mem_limit|cpus|secrets|configs)
        : # property; ignore
        ;;
      *)
        # Determine the service indent the first time we see a key under services.
        if [[ -z "${service_indent:-}" ]]; then
          service_indent="$ind"
        fi
        if [[ "$ind" -eq "$service_indent" ]]; then
          current_service="$key"
          in_ports=0
        fi
        ;;
    esac
  fi
done < "$compose_path"

# ---------------------------------------------------------------------------
# Decide what to write.
# ---------------------------------------------------------------------------
n_alloc=${#remap_lines[@]}

if [[ "$n_alloc" -eq 0 ]]; then
  if [[ "$saw_longform" -eq 1 ]]; then
    warn "compose uses only long-form (target:/published:) ports for service(s):${longform_services:- } — unsupported by this scaffolder; not writing an override (worker should apply Layer 2 manually if needed)"
  else
    info "no remappable published host ports found in $compose_file — skipping override (Layer 1 project name still emitted)"
  fi
  # Still emit Layer 1 so a caller gets the namespaced project even with no
  # remappable ports. No override file is written.
  printf 'export COMPOSE_PROJECT_NAME=%s\n' "$project_name"
  exit 0
fi

if [[ "$saw_longform" -eq 1 ]]; then
  warn "compose has long-form (target:/published:) ports for service(s):${longform_services:- } — those services were NOT remapped (unsupported); short-form services were remapped"
fi

# ---------------------------------------------------------------------------
# Write the override. Group remap lines by service so each service has exactly
# one `ports: !override` block (idempotent, no duplication).
# Output ordering is deterministic: services in first-seen order.
# ---------------------------------------------------------------------------
override_path="$worktree/docker-compose.override.yml"
tmp_override="$(mktemp)"

{
  echo "# Generated by scripts/auto-apply-docker-isolation.sh (Hydra ticket #178)."
  echo "# Worker-scoped docker isolation: namespaced Compose project + remapped"
  echo "# host ports so parallel workers don't collide. DO NOT COMMIT this file"
  echo "# into the target repo. Regenerated on every run (idempotent)."
  echo "# COMPOSE_PROJECT_NAME=$project_name"
  echo "services:"
} > "$tmp_override"

# Emit per service, preserving first-seen order, one ports block each.
emitted_services=""
for i in "${!svc_names[@]}"; do
  svc="${svc_names[$i]}"
  case "$emitted_services" in
    *" $svc "*) continue ;;  # already emitted this service's block
  esac
  emitted_services="$emitted_services $svc "
  {
    echo "  $svc:"
    echo "    ports: !override"
    for j in "${!svc_names[@]}"; do
      if [[ "${svc_names[$j]}" == "$svc" ]]; then
        echo "      - \"${remap_lines[$j]}\""
      fi
    done
  } >> "$tmp_override"
done

mv "$tmp_override" "$override_path"
info "wrote $override_path (project=$project_name, $n_alloc port(s) remapped)"

# ---------------------------------------------------------------------------
# Emit eval-safe env exports on stdout.
# ---------------------------------------------------------------------------
printf 'export COMPOSE_PROJECT_NAME=%s\n' "$project_name"
for e in "${hydra_exports[@]}"; do
  printf 'export %s\n' "$e"
done

exit 0
