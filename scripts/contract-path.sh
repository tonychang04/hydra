#!/usr/bin/env bash
#
# contract-path.sh — the SINGLE SOURCE OF TRUTH for where a ticket's
# validation-contract lives (#262).
#
# #255 placed the per-ticket validation-contract.md at the committed repo ROOT
# and told workers to commit it. A single committed path cannot represent N
# concurrent tickets' contracts: workers branching off main saw the PREVIOUS
# ticket's contract, then either overwrote it (churn in every PR) or failed
# their own dogfood gate (this blocked #261). The fix: a per-ticket, gitignored
# location, resolved here so every caller (the worker agents,
# validate-contract.sh, revalidate-contract.sh) agrees on the convention.
#
#     <worktree>/.hydra/contracts/<ticket>.md
#
# `.hydra/` is gitignored (see .gitignore), so the artifact never lands in a PR
# diff and never reaches main — for Hydra's own tickets AND downstream repos
# (mirrors the worktree-local docker-compose.override.yml guardrail).
#
# Spec: docs/specs/2026-06-08-contract-artifact-location.md
# Callers: scripts/validate-contract.sh (--ticket), scripts/revalidate-contract.sh
#          (--ticket), .claude/agents/worker-{implementation,review,validator}.md
#
# Usage:
#   contract-path.sh <ticket> [--worktree <dir>] [--mkdir]
#
#   <ticket>          bare ticket number (digits only — a non-numeric value is
#                     rejected so a path can never be smuggled into the filename).
#   --worktree <dir>  the worktree root (default: `git rev-parse --show-toplevel`,
#                     falling back to the current directory outside a git repo).
#   --mkdir           create the .hydra/contracts/ parent dir before printing.
#   -h, --help        show this help.
#
# Output: the resolved path on stdout, exit 0.
#
# Exit codes:
#   0 = path printed
#   2 = usage error (missing/non-numeric ticket, bad flag, unreadable worktree)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: contract-path.sh <ticket> [--worktree <dir>] [--mkdir]

Prints the canonical per-ticket validation-contract path:
  <worktree>/.hydra/contracts/<ticket>.md

The single source of truth for the #262 convention (artifact moved off the
committed repo root to a per-ticket, gitignored location).

Arguments:
  <ticket>          bare ticket number (digits only).
  --worktree <dir>  worktree root (default: git toplevel, else current dir).
  --mkdir           create the .hydra/contracts/ parent dir first.
  -h, --help        show this help.

Exit codes:
  0 = path printed
  2 = usage error (missing/non-numeric ticket, bad flag, unreadable worktree)

Spec: docs/specs/2026-06-08-contract-artifact-location.md
EOF
}

ticket=""
worktree=""
do_mkdir=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)
      [[ $# -ge 2 ]] || { echo "contract-path: --worktree needs a value" >&2; exit 2; }
      worktree="$2"; shift 2
      ;;
    --worktree=*)
      worktree="${1#--worktree=}"; shift
      ;;
    --mkdir)
      do_mkdir=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift
      # Remaining positionals (if any) are treated as the ticket below.
      while [[ $# -gt 0 ]]; do
        if [[ -z "$ticket" ]]; then ticket="$1"; else
          echo "contract-path: unexpected extra argument: $1" >&2; exit 2
        fi
        shift
      done
      break
      ;;
    -*)
      echo "contract-path: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$ticket" ]]; then
        ticket="$1"; shift
      else
        echo "contract-path: unexpected extra argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

# Ticket must be present and digits-only (no path traversal into the filename).
if [[ -z "$ticket" ]]; then
  echo "contract-path: missing <ticket> (bare ticket number)" >&2
  usage >&2
  exit 2
fi
if [[ ! "$ticket" =~ ^[0-9]+$ ]]; then
  echo "contract-path: <ticket> must be digits only, got: $ticket" >&2
  exit 2
fi

# Resolve the worktree: explicit flag wins; else git toplevel; else cwd.
if [[ -z "$worktree" ]]; then
  if worktree="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$worktree" ]]; then
    : # use git toplevel
  else
    worktree="."
  fi
fi

if [[ ! -d "$worktree" ]]; then
  echo "contract-path: --worktree is not a directory: $worktree" >&2
  exit 2
fi

path="$worktree/.hydra/contracts/$ticket.md"

if [[ "$do_mkdir" -eq 1 ]]; then
  mkdir -p "$worktree/.hydra/contracts"
fi

printf '%s\n' "$path"
