#!/usr/bin/env bash
#
# gc-stale-worktrees.sh — reclaim zombie worker worktrees.
#
# A crashed or killed worker can leave its `.claude/worktrees/agent-*` directory
# behind with no garbage collector. Over a long-running Commander these accrue,
# wasting disk and obscuring which worktrees are actually live. This helper lists
# (default, --dry-run) or removes (--apply) the stale ones.
#
# A worktree dir is a STALE CANDIDATE when BOTH hold:
#   (a) not active — its absolute path is not the `.worktree` of any worker in
#       state/active.json, AND
#   (b) older than 24h — its mtime is more than --max-age-s seconds in the past.
#
# FAIL-CLOSED on a missing/unreadable/CORRUPT state/active.json: the not-active
# half of the predicate is load-bearing, so without a TRUSTWORTHY file the script
# removes NOTHING (--apply exits 1; --dry-run reports zero candidates with a
# note). "Corrupt" means present + readable but not valid JSON — e.g. truncated by
# a crash mid-rewrite; treating it as empty would expose LIVE worktrees to
# deletion, so it fails closed exactly like missing/unreadable. state/active.json
# is gitignored runtime state, so it is also legitimately absent in a fresh
# checkout — failing closed is the safe default there too.
#
# It REPORTS by default; it only deletes under --apply, and only dirs under the
# worktrees root that match agent-* and pass BOTH gates. Removal prefers
# `git worktree remove --force` (so git's own bookkeeping stays consistent) and
# falls back to a constrained `rm -rf` ONLY for a truly orphaned dir git does not
# track.
#
# Usage:
#   scripts/gc-stale-worktrees.sh [--dry-run|--apply] [--json]
#       [--root <path>] [--state-dir <path>] [--worktrees-dir <path>]
#       [--max-age-s <n>]
#
# Output:
#   default   human report (one line per candidate + a summary)
#   --json    {root, dry_run, max_age_s, active_count, fail_closed,
#              candidates:[{path,age_s,reason}], removed:[...]}
#
# Test seams (offline, mirror the sibling scripts):
#   --root <path>           repo root (default: <script>/.. )
#   --state-dir <path>      override state/ (default <root>/state)
#   --worktrees-dir <path>  override the worktrees root
#                           (default <root>/.claude/worktrees)
#   --max-age-s <n>         staleness threshold in seconds (default 86400 = 24h)
#
# Exit codes:
#   0   ran (candidates/removals reported)
#   1   I/O error (missing active.json in --apply, jq missing, removal failed)
#   2   usage error (unknown flag / missing value / bad number)
#
# Spec: docs/specs/2026-06-07-tick-stall-robustness.md (ticket #242)
# Style mirrors scripts/pr-shepherd.sh and scripts/rescue-worker.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: gc-stale-worktrees.sh [options]

Reclaim zombie worker worktrees: list (--dry-run, default) or remove (--apply)
.claude/worktrees/agent-* dirs that are BOTH not referenced by state/active.json
AND older than 24h. Fails closed (removes nothing) if active.json is missing,
unreadable, or corrupt (present but not valid JSON).

Options:
  --dry-run             List stale candidates without removing (DEFAULT).
  --apply               Remove the stale candidates.
  --json                Emit machine-readable JSON instead of the human report.
  --root <path>         Repo root (default: the script's parent dir).
  --state-dir <path>    Override state/ dir (default <root>/state).
  --worktrees-dir <path> Override the worktrees root
                        (default <root>/.claude/worktrees).
  --max-age-s <n>       Staleness threshold in seconds (default 86400 = 24h).
  -h, --help            Show this help.

Exit codes:
  0 ran · 1 I/O error (missing/corrupt active.json under --apply, jq missing) · 2 usage error

Spec: docs/specs/2026-06-07-tick-stall-robustness.md (ticket #242)
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
root="$DEFAULT_ROOT"
state_dir_override=""
worktrees_dir_override=""
max_age_s=86400
json_mode=0
apply=0

need_val() {
  if [[ $# -lt 2 ]]; then
    echo "gc-stale-worktrees: option '$1' requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)            usage; exit 0 ;;
    --dry-run)            apply=0; shift ;;
    --apply)              apply=1; shift ;;
    --json)              json_mode=1; shift ;;
    --root)               need_val "$@"; root="$2"; shift 2 ;;
    --root=*)             root="${1#--root=}"; shift ;;
    --state-dir)          need_val "$@"; state_dir_override="$2"; shift 2 ;;
    --state-dir=*)        state_dir_override="${1#--state-dir=}"; shift ;;
    --worktrees-dir)      need_val "$@"; worktrees_dir_override="$2"; shift 2 ;;
    --worktrees-dir=*)    worktrees_dir_override="${1#--worktrees-dir=}"; shift ;;
    --max-age-s)          need_val "$@"; max_age_s="$2"; shift 2 ;;
    --max-age-s=*)        max_age_s="${1#--max-age-s=}"; shift ;;
    *) echo "gc-stale-worktrees: unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$max_age_s" =~ ^[0-9]+$ ]]; then
  echo "gc-stale-worktrees: --max-age-s must be a non-negative integer, got '$max_age_s'" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "gc-stale-worktrees: jq not found on PATH" >&2; exit 1; }

STATE_DIR="${state_dir_override:-$root/state}"
ACTIVE_FILE="$STATE_DIR/active.json"
WORKTREES_DIR="${worktrees_dir_override:-$root/.claude/worktrees}"

# Resolve a path to its absolute form without requiring it to exist beyond the
# leaf (so we can compare active.json entries even if a dir was already removed).
abspath() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd -- "$p" 2>/dev/null && pwd)
  else
    printf '%s' "$p"
  fi
}

# mtime epoch of a path (GNU/BSD stat compatible, numerically guarded).
#
# Order matters: try the GNU form (`stat -c %Y`) FIRST, the BSD/macOS form
# (`stat -f %m`) second. On Linux/GNU coreutils `stat -c` succeeds and the BSD
# branch never runs. On macOS `stat -c` fails cleanly to stderr, so the BSD
# branch takes over. Doing it the other way round breaks on Linux CI: GNU stat
# reads `-f` as --file-system, treats `%m` as a FILE operand, prints a human
# "  File: ..." block to STDOUT and exits 0 — so the `||` fallback never fires,
# the human text is captured here, and the caller's `$(( now - mt ))` aborts
# under `set -u` with "File: unbound variable".
#
# The `=~ ^[0-9]+$` guard is defense-in-depth: if any branch ever yields
# non-numeric output, collapse it to 0 so a stray capture can never poison the
# arithmetic in the caller. Spec: docs/specs/2026-06-07-tick-stall-robustness.md.
mtime_epoch() {
  local p="$1" m
  m="$(stat -c %Y "$p" 2>/dev/null)" || m="$(stat -f %m "$p" 2>/dev/null)" || m=0
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s' "$m"
}

now_epoch="$(date +%s)"

# -----------------------------------------------------------------------------
# FAIL-CLOSED: the not-active predicate needs a TRUSTWORTHY active.json. Without
# one, removing would be unsafe (we couldn't tell which dirs are live). Report +
# refuse. We fail closed on THREE conditions:
#   - missing             (-f false)
#   - unreadable          (-r false)
#   - present but CORRUPT  (does not parse as JSON)
# The corrupt case is the data-loss trap: a crash mid-rewrite leaves active.json
# present + readable but truncated. If we only guarded missing/unreadable, the
# in-loop `jq ... 2>/dev/null` would swallow the parse error, yield an EMPTY
# active set with fail_closed=false, and then every >24h agent-* dir — INCLUDING
# live workers whose entries were in the now-corrupt file — would become a
# deletion candidate. Validating the parse up front closes that hole.
# -----------------------------------------------------------------------------
fail_closed=false
active_paths=""   # newline-separated absolute paths of active worktrees
active_count=0
if [[ -f "$ACTIVE_FILE" && -r "$ACTIVE_FILE" ]] && jq empty "$ACTIVE_FILE" >/dev/null 2>&1; then
  # Collect each worker's .worktree (absolute, resolved). Branchless/worktree-less
  # entries contribute nothing.
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    rp="$(abspath "$wt")"
    active_paths+="$rp"$'\n'
    active_count=$(( active_count + 1 ))
  done < <(jq -r '(.workers // [])[] | .worktree // empty' "$ACTIVE_FILE" 2>/dev/null)
else
  fail_closed=true
fi

is_active_path() {
  local target="$1"
  [[ -n "${active_paths//[$'\n']/}" ]] || return 1
  while IFS= read -r ap; do
    [[ -n "$ap" ]] || continue
    [[ "$ap" == "$target" ]] && return 0
  done <<<"$active_paths"
  return 1
}

# -----------------------------------------------------------------------------
# Enumerate candidates: <worktrees-dir>/agent-* that are not-active AND >max-age.
# When fail_closed, we enumerate NOTHING (safe default).
# -----------------------------------------------------------------------------
candidates_jsonl=""
if [[ "$fail_closed" == false && -d "$WORKTREES_DIR" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ -d "$d" ]] || continue
    base="$(basename -- "$d")"
    # Only agent-* dirs are in scope.
    case "$base" in
      agent-*) ;;
      *) continue ;;
    esac
    rp="$(abspath "$d")"
    # (a) not active
    if is_active_path "$rp"; then continue; fi
    # (b) older than max-age
    mt="$(mtime_epoch "$d")"
    age=$(( now_epoch - mt ))
    (( age < 0 )) && age=0
    if (( age <= max_age_s )); then continue; fi
    row="$(jq -nc --arg path "$rp" --argjson age_s "$age" \
      '{path:$path, age_s:$age_s, reason:"not-active-and-stale"}')"
    candidates_jsonl+="$row"$'\n'
  done < <(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d -name 'agent-*' 2>/dev/null | sort)
fi

if [[ -n "${candidates_jsonl//[$'\n']/}" ]]; then
  candidates_array="$(printf '%s' "$candidates_jsonl" | jq -sc '.')"
else
  candidates_array='[]'
fi

# -----------------------------------------------------------------------------
# APPLY: remove each candidate. git worktree remove --force when git tracks it,
# else a constrained rm -rf (only for an agent-* dir under the worktrees root).
# -----------------------------------------------------------------------------
removed_jsonl=""
if [[ "$apply" -eq 1 ]]; then
  if [[ "$fail_closed" == true ]]; then
    echo "gc-stale-worktrees: refusing to --apply — $ACTIVE_FILE missing/unreadable/corrupt (fail-closed)" >&2
    exit 1
  fi
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    path="$(printf '%s' "$c" | jq -r '.path')"
    [[ -n "$path" && -d "$path" ]] || continue
    base="$(basename -- "$path")"
    # Belt-and-suspenders: never remove a path outside the worktrees root or not
    # matching agent-*.
    case "$base" in agent-*) ;; *) continue ;; esac
    parent="$(cd -- "$path/.." 2>/dev/null && pwd)"
    wt_root_abs="$(abspath "$WORKTREES_DIR")"
    [[ "$parent" == "$wt_root_abs" ]] || continue

    removed_ok=0
    # Prefer git worktree remove so git's bookkeeping stays consistent.
    if git -C "$root" worktree remove --force "$path" >/dev/null 2>&1; then
      removed_ok=1
    elif [[ -d "$path" ]]; then
      # Truly orphaned dir git does not track — constrained rm.
      rm -rf -- "$path" && removed_ok=1
    fi
    if [[ "$removed_ok" -eq 1 ]]; then
      removed_jsonl+="$(jq -nc --arg path "$path" '$path')"$'\n'
    else
      echo "gc-stale-worktrees: failed to remove $path" >&2
      exit 1
    fi
  done < <(printf '%s' "$candidates_array" | jq -c '.[]')
fi

if [[ -n "${removed_jsonl//[$'\n']/}" ]]; then
  removed_array="$(printf '%s' "$removed_jsonl" | jq -sc '.')"
else
  removed_array='[]'
fi

# -----------------------------------------------------------------------------
# OUTPUT
# -----------------------------------------------------------------------------
dry_run_bool=true
[[ "$apply" -eq 1 ]] && dry_run_bool=false

if [[ "$json_mode" -eq 1 ]]; then
  jq -nc \
    --arg root "$(abspath "$root")" \
    --argjson dry_run "$dry_run_bool" \
    --argjson max_age_s "$max_age_s" \
    --argjson active_count "$active_count" \
    --argjson fail_closed "$fail_closed" \
    --argjson candidates "$candidates_array" \
    --argjson removed "$removed_array" \
    '{root:$root, dry_run:$dry_run, max_age_s:$max_age_s,
      active_count:$active_count, fail_closed:$fail_closed,
      candidates:$candidates, removed:$removed}'
  exit 0
fi

# ---- human report ----
echo "▸ gc-stale-worktrees — ${WORKTREES_DIR}"
echo "  mode: $([[ "$apply" -eq 1 ]] && echo apply || echo dry-run) · max-age ${max_age_s}s · active workers ${active_count}"
if [[ "$fail_closed" == true ]]; then
  echo "  FAIL-CLOSED: $ACTIVE_FILE missing/unreadable/corrupt — removing nothing."
  exit 0
fi
ncand="$(printf '%s' "$candidates_array" | jq 'length')"
if [[ "$ncand" -eq 0 ]]; then
  echo "  (no stale worktrees)"
else
  echo "  stale candidates ($ncand):"
  printf '%s' "$candidates_array" | jq -r '.[] | "    \(.path)  (age \(.age_s)s)"'
fi
if [[ "$apply" -eq 1 ]]; then
  nrem="$(printf '%s' "$removed_array" | jq 'length')"
  echo "  removed ($nrem):"
  printf '%s' "$removed_array" | jq -r '.[] | "    \(.)"'
elif [[ "$ncand" -gt 0 ]]; then
  echo "  ↳ run with --apply to reclaim."
fi
exit 0
