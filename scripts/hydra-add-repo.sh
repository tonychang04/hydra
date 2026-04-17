#!/usr/bin/env bash
#
# hydra-add-repo.sh — interactive wizard to add a repo to state/repos.json.
#
# Usage: ./hydra add-repo <owner>/<name> [options]
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)
#
# Hard rules:
#   - set -euo pipefail
#   - Bash + jq only
#   - Atomic writes on state/repos.json (tmp + mv)
#   - Never edits CLAUDE.md, policy.md, budget.json, settings.local.json,
#     worker subagents
#   - Validates against state/schemas/repos.schema.json if present; skips gracefully if not

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Source .hydra.env if present, so HYDRA_ROOT / HYDRA_EXTERNAL_MEMORY_DIR are visible.
# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra add-repo <owner>/<name> [options]

Interactive wizard that adds a repo entry to state/repos.json. Prompts for
local_path (with an auto-suggested default from `git remote get-url origin`
lookups under common parent dirs), ticket_trigger, and enabled state. Writes
atomically via tmp + mv — the file is never half-written on crash.

Arguments:
  <owner>/<name>          Required. Repo slug, e.g. tonychang04/hydra

Options:
  --local-path <path>     Absolute path to the local clone. Skips prompt.
                          Must exist and contain a .git directory.
  --trigger <t>           ticket_trigger: assignee | label | linear.
                          Default: assignee.
  --assignee <user>       Optional. GitHub username to poll via
                          `gh issue list --assignee <user>` instead of @me.
                          Bot-account mode (ticket #26). Only meaningful when
                          --trigger is 'assignee'. Omit to use @me (default).
                          See docs/specs/2026-04-17-assignee-override.md.
  --state-file <path>     Write to this repos.json instead of state/repos.json.
                          Used by self-tests so they don't mutate committed
                          state; also useful for staging / scripted ops.
                          Does NOT bootstrap from state/repos.example.json
                          when --state-file is set — create the target file
                          yourself first (minimal: '{"repos":[]}').
  --enabled               Enable the repo (default for new entries).
  --disabled              Add the entry in disabled state.
  --force                 Overwrite an existing entry with the same owner/name.
  --non-interactive       Never prompt — fail if a required field is missing.
  -h, --help              Show this help.

Exit codes:
  0   entry added (or replaced with --force)
  1   I/O or validation error (bad slug, missing path, missing state file)
  2   duplicate entry without --force, or usage error

Example:
  ./hydra add-repo tonychang04/hydra \
    --local-path ~/projects/hydra \
    --trigger assignee \
    --assignee hydra-bot-example \
    --non-interactive
EOF
}

# -----------------------------------------------------------------------------
# color
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

err() { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
ok()  { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn(){ printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }

# -----------------------------------------------------------------------------
# args
# -----------------------------------------------------------------------------
slug=""
local_path=""
trigger=""
enabled=""
assignee_override=""
assignee_override_set=0
state_file_override=""
force=0
non_interactive=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --local-path) [[ $# -ge 2 ]] || { err "--local-path needs a value"; usage >&2; exit 2; }; local_path="$2"; shift 2 ;;
    --local-path=*) local_path="${1#--local-path=}"; shift ;;
    --trigger) [[ $# -ge 2 ]] || { err "--trigger needs a value"; usage >&2; exit 2; }; trigger="$2"; shift 2 ;;
    --trigger=*) trigger="${1#--trigger=}"; shift ;;
    --assignee) [[ $# -ge 2 ]] || { err "--assignee needs a value"; usage >&2; exit 2; }; assignee_override="$2"; assignee_override_set=1; shift 2 ;;
    --assignee=*) assignee_override="${1#--assignee=}"; assignee_override_set=1; shift ;;
    --state-file) [[ $# -ge 2 ]] || { err "--state-file needs a value"; usage >&2; exit 2; }; state_file_override="$2"; shift 2 ;;
    --state-file=*) state_file_override="${1#--state-file=}"; shift ;;
    --enabled) enabled="true"; shift ;;
    --disabled) enabled="false"; shift ;;
    --force) force=1; shift ;;
    --non-interactive) non_interactive=1; shift ;;
    --) shift; break ;;
    -*)
      err "unknown flag: $1"; usage >&2; exit 2 ;;
    *)
      if [[ -z "$slug" ]]; then
        slug="$1"
      else
        err "unexpected positional argument: $1"; usage >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$slug" ]]; then
  err "missing required <owner>/<name> argument"
  usage >&2
  exit 2
fi

# Validate slug shape.
if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  err "invalid slug '$slug' — expected <owner>/<name>"
  exit 1
fi
owner="${slug%%/*}"
name="${slug##*/}"

# Validate trigger if provided now.
if [[ -n "$trigger" ]]; then
  case "$trigger" in
    assignee|label|linear) ;;
    *) err "invalid --trigger '$trigger' (expected assignee|label|linear)"; exit 2 ;;
  esac
fi

# Validate --assignee if provided now. Bot-account mode (ticket #26):
# the override must look like a GitHub login. Mirrors the schema pattern.
# Empty string is explicitly rejected — the only two valid states are
# "unset" (default @me) and "a non-empty valid login".
if [[ "$assignee_override_set" -eq 1 ]]; then
  if [[ -z "$assignee_override" ]]; then
    err "--assignee cannot be empty (omit the flag for default @me behavior)"
    exit 2
  fi
  if ! [[ "$assignee_override" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]]; then
    err "invalid --assignee '$assignee_override' — expected a GitHub login (alphanumeric + dashes, optional [bot] suffix)"
    exit 2
  fi
fi

# -----------------------------------------------------------------------------
# locate state file
# -----------------------------------------------------------------------------
if [[ -n "$state_file_override" ]]; then
  # Caller-supplied path. We don't bootstrap — the caller owns the file.
  # This is the codepath self-tests use.
  repos_file="$state_file_override"
  if [[ ! -f "$repos_file" ]]; then
    err "--state-file path does not exist: $repos_file (create it first with '{\"repos\":[]}')"
    exit 1
  fi
else
  repos_file="$ROOT_DIR/state/repos.json"
  repos_example="$ROOT_DIR/state/repos.example.json"

  if [[ ! -f "$repos_file" ]]; then
    if [[ -f "$repos_example" ]]; then
      warn "state/repos.json missing — bootstrapping from example"
      cp "$repos_example" "$repos_file"
    else
      err "neither state/repos.json nor state/repos.example.json exists"
      exit 1
    fi
  fi
fi

if ! jq empty "$repos_file" 2>/dev/null; then
  err "state/repos.json is not valid JSON"
  exit 1
fi

# -----------------------------------------------------------------------------
# detect duplicate
# -----------------------------------------------------------------------------
existing_json="$(
  jq --arg o "$owner" --arg n "$name" \
    '.repos // [] | map(select(.owner == $o and .name == $n)) | .[0] // null' \
    "$repos_file"
)"
if [[ "$existing_json" != "null" ]]; then
  if [[ "$force" -ne 1 ]]; then
    err "entry already exists for $owner/$name:"
    jq --color-output '.' <<<"$existing_json" >&2 || jq '.' <<<"$existing_json" >&2
    err "re-run with --force to overwrite"
    exit 2
  fi
  warn "overwriting existing entry for $owner/$name (--force)"
fi

# -----------------------------------------------------------------------------
# auto-suggest local_path
# -----------------------------------------------------------------------------
suggest_local_path() {
  local target_owner="$1" target_name="$2"
  local parents=( "$HOME" "$HOME/projects" "$HOME/code" "$HOME/work" "$HOME/src" "$HOME/git" "$PWD" )
  local parent candidate remote
  for parent in "${parents[@]}"; do
    [[ -d "$parent" ]] || continue
    # First try an exact name match — one directory deep only.
    for candidate in "$parent/$target_name" "$parent/$target_owner-$target_name"; do
      if [[ -d "$candidate/.git" ]]; then
        remote="$(git -C "$candidate" remote get-url origin 2>/dev/null || true)"
        if [[ -n "$remote" ]] && [[ "$remote" == *"$target_owner/$target_name"* ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
  done
  return 1
}

# -----------------------------------------------------------------------------
# prompts / non-interactive resolution
# -----------------------------------------------------------------------------
if [[ -z "$local_path" ]]; then
  suggested="$(suggest_local_path "$owner" "$name" || true)"
  if [[ "$non_interactive" -eq 1 ]]; then
    if [[ -n "$suggested" ]]; then
      local_path="$suggested"
      warn "non-interactive: using auto-suggested local_path $local_path"
    else
      err "non-interactive: --local-path is required (no auto-suggestion found)"
      exit 2
    fi
  else
    default_display="${suggested:-}"
    if [[ -n "$default_display" ]]; then
      printf "%slocal_path%s [%s]: " "$C_BOLD" "$C_RESET" "$default_display"
    else
      printf "%slocal_path%s (absolute path to the local clone): " "$C_BOLD" "$C_RESET"
    fi
    IFS= read -r line || true
    local_path="${line:-$default_display}"
  fi
fi

if [[ -z "$local_path" ]]; then
  err "local_path is required"
  exit 1
fi

# Expand tilde if present.
case "$local_path" in
  "~") local_path="$HOME" ;;
  "~/"*) local_path="$HOME/${local_path#~/}" ;;
esac

if [[ ! -d "$local_path" ]]; then
  err "local_path does not exist: $local_path"
  exit 1
fi
if [[ ! -d "$local_path/.git" ]] && [[ ! -f "$local_path/.git" ]]; then
  err "local_path is not a git repo (no .git): $local_path"
  exit 1
fi

# trigger
if [[ -z "$trigger" ]]; then
  default_trigger="$(jq -r '.default_ticket_trigger // "assignee"' "$repos_file")"
  if [[ "$non_interactive" -eq 1 ]]; then
    trigger="$default_trigger"
  else
    printf "%sticket_trigger%s (assignee|label|linear) [%s]: " "$C_BOLD" "$C_RESET" "$default_trigger"
    IFS= read -r line || true
    trigger="${line:-$default_trigger}"
  fi
fi
case "$trigger" in
  assignee|label|linear) ;;
  *) err "invalid ticket_trigger '$trigger'"; exit 2 ;;
esac

# assignee_override (bot-account mode, ticket #26). Only relevant when the
# trigger is 'assignee' — the override is the username polled by
# `gh issue list --assignee <user>`. Absent = fall back to @me. Only prompt
# interactively; non-interactive mode uses whatever --assignee set (or nothing).
if [[ "$assignee_override_set" -eq 0 ]] && [[ "$trigger" == "assignee" ]] && [[ "$non_interactive" -eq 0 ]]; then
  printf "%sassignee_override%s (GitHub login, blank for @me) []: " "$C_BOLD" "$C_RESET"
  IFS= read -r line || true
  if [[ -n "$line" ]]; then
    if ! [[ "$line" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]]; then
      err "invalid assignee_override '$line' — expected a GitHub login"
      exit 2
    fi
    assignee_override="$line"
    assignee_override_set=1
  fi
fi

# If the user set --assignee but the trigger isn't 'assignee', warn that
# the override is unused. Don't refuse — it's persisted so flipping the
# trigger later doesn't lose the value.
if [[ "$assignee_override_set" -eq 1 ]] && [[ "$trigger" != "assignee" ]]; then
  warn "assignee_override '$assignee_override' recorded but ticket_trigger is '$trigger' — the override is only used with the 'assignee' trigger"
fi

# enabled
if [[ -z "$enabled" ]]; then
  if [[ "$non_interactive" -eq 1 ]]; then
    enabled="true"
  else
    printf "%senabled%s (true|false) [true]: " "$C_BOLD" "$C_RESET"
    IFS= read -r line || true
    line="${line:-true}"
    case "$line" in
      true|yes|y|1) enabled="true" ;;
      false|no|n|0) enabled="false" ;;
      *) err "invalid enabled value '$line'"; exit 2 ;;
    esac
  fi
fi

# -----------------------------------------------------------------------------
# write (atomic)
# -----------------------------------------------------------------------------
tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$tmp'" EXIT

# Build the entry. assignee_override is conditionally included — we omit it
# entirely when no override was set, so diffs stay minimal for operators who
# never use bot mode. Same reason we use jq's del(nulls) idiom rather than
# inserting `"assignee_override": null`.
if [[ "$assignee_override_set" -eq 1 ]]; then
  new_entry="$(
    jq -n \
      --arg owner "$owner" \
      --arg name  "$name" \
      --arg lp    "$local_path" \
      --arg trig  "$trigger" \
      --arg ao    "$assignee_override" \
      --argjson en "$enabled" \
      '{owner: $owner, name: $name, local_path: $lp, enabled: $en, ticket_trigger: $trig, assignee_override: $ao}'
  )"
else
  new_entry="$(
    jq -n \
      --arg owner "$owner" \
      --arg name  "$name" \
      --arg lp    "$local_path" \
      --arg trig  "$trigger" \
      --argjson en "$enabled" \
      '{owner: $owner, name: $name, local_path: $lp, enabled: $en, ticket_trigger: $trig}'
  )"
fi

jq \
  --arg owner "$owner" \
  --arg name  "$name" \
  --argjson entry "$new_entry" \
  '
  .repos = (
    ((.repos // []) | map(select(.owner != $owner or .name != $name)))
    + [$entry]
  )
  ' "$repos_file" > "$tmp"

# Validate the newly-written entry against the schema's required fields (if a
# schema file is present). We only check the entry we just wrote — pre-existing
# entries may be templates with missing optional keys (e.g. ticket_trigger on
# disabled/infra stubs); we don't retroactively reject those.
schema="$ROOT_DIR/state/schemas/repos.schema.json"
if [[ -f "$schema" ]]; then
  if ! jq -e --arg o "$owner" --arg n "$name" '
    .repos // []
    | map(select(.owner == $o and .name == $n))
    | .[0]
    | (has("owner") and has("name") and has("local_path")
        and has("enabled") and has("ticket_trigger"))
  ' "$tmp" >/dev/null; then
    err "resulting entry fails schema structural check (missing required keys)"
    exit 1
  fi
fi

# Atomic swap.
mv "$tmp" "$repos_file"
trap - EXIT

# -----------------------------------------------------------------------------
# summary
# -----------------------------------------------------------------------------
ok "added $owner/$name to state/repos.json"
printf "%s%s%s\n" "$C_DIM" "  $(jq -c --arg o "$owner" --arg n "$name" '.repos[] | select(.owner==$o and .name==$n)' "$repos_file")" "$C_RESET"
exit 0
