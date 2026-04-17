#!/usr/bin/env bash
#
# build-memory-brief.sh — compile a repo-scoped memory brief for a worker prompt.
#
# Commander runs this before spawning a worker (see CLAUDE.md "Memory hygiene"
# + docs/specs/2026-04-17-memory-preloading.md). Output is a markdown body
# that commander prepends under a `# Memory Brief` H1 in front of the
# ticket body.
#
# Usage:
#   scripts/build-memory-brief.sh <owner/name>
#     [--memory-dir <path>]
#     [--state-dir <path>]
#     [--now <YYYY-MM-DD>]   # for deterministic tests
#
# Inputs (read-only):
#   - <memory-dir>/learnings-<slug>.md           — repo learnings
#   - <memory-dir>/escalation-faq.md             — Q+A with optional Scope: tag
#   - <memory-dir>/retros/YYYY-WW.md             — most recent by lex sort
#   - <state-dir>/memory-citations.json          — citation counts
#
# Output:
#   - markdown on stdout, ≤ 2000 bytes. Never exits non-zero on missing
#     inputs (fresh repos get an empty brief — that's valid).
#
# Conventions (from docs/specs/2026-04-17-memory-preloading.md):
#   - Repo slug = basename after "/". Fall back to "<owner>-<name>" if the
#     basename file doesn't exist.
#   - Priority order when trimming to the budget: repo learnings → cross-repo
#     → escalation-faq → retro. Later sections truncate first on overflow.
#
# Depends on: bash 4+, jq, sed, awk, grep.

set -euo pipefail

MEMORY_DIR_DEFAULT="./memory"
STATE_DIR_DEFAULT="./state"
BUDGET_BYTES=2000
TRUNCATION_MARKER="[truncated — see full at memory/learnings-%s.md]"

usage() {
  cat <<'EOF'
Usage: build-memory-brief.sh <owner/name> [options]

Compile a repo-scoped memory brief (≤ 2000 bytes) for a worker prompt.

Arguments:
  <owner/name>          Target repo, e.g. tonychang04/hydra

Options:
  --memory-dir <path>   Override memory directory (default: $HYDRA_EXTERNAL_MEMORY_DIR,
                        falls back to ./memory).
  --state-dir <path>    Override state directory (default: ./state).
  --now <YYYY-MM-DD>    Override "today" for deterministic tests. Cross-repo
                        top-3 filters on last_cited >= now - 30 days.
  -h, --help            Show this help.

Output:
  Markdown body on stdout. Commander prepends a `# Memory Brief` H1 when
  injecting into a worker prompt. Never exits non-zero on missing inputs.

Exit codes:
  0  success (output may be empty if no memory exists yet)
  2  usage error
EOF
}

memory_dir=""
state_dir=""
now_override=""
repo_ref=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "build-memory-brief: --memory-dir needs a value" >&2; exit 2; }
      memory_dir="$2"; shift 2 ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "build-memory-brief: --state-dir needs a value" >&2; exit 2; }
      state_dir="$2"; shift 2 ;;
    --now)
      [[ $# -ge 2 ]] || { echo "build-memory-brief: --now needs a value" >&2; exit 2; }
      now_override="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "build-memory-brief: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$repo_ref" ]]; then
        echo "build-memory-brief: only one positional repo ref allowed" >&2; exit 2
      fi
      repo_ref="$1"; shift ;;
  esac
done

if [[ -z "$repo_ref" ]]; then
  echo "build-memory-brief: missing <owner/name>" >&2
  usage >&2
  exit 2
fi

if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi
if [[ -z "$state_dir" ]]; then
  state_dir="$STATE_DIR_DEFAULT"
fi

# Determine repo slug. Try basename first; fall back to owner-name dashed.
owner="${repo_ref%%/*}"
name="${repo_ref##*/}"
if [[ "$owner" == "$repo_ref" || -z "$name" ]]; then
  # No slash in repo_ref — treat whole thing as the slug.
  slug="$repo_ref"
  combined=""
else
  slug="$name"
  combined="${owner}-${name}"
fi

learnings_file="$memory_dir/learnings-$slug.md"
if [[ ! -f "$learnings_file" ]] && [[ -n "$combined" ]]; then
  alt="$memory_dir/learnings-$combined.md"
  if [[ -f "$alt" ]]; then
    learnings_file="$alt"
    slug="$combined"
  fi
fi
# If neither exists, slug stays as-is; downstream sections will note the absence.

citations_file="$state_dir/memory-citations.json"
faq_file="$memory_dir/escalation-faq.md"
retros_dir="$memory_dir/retros"

# Today date for 30-day cross-repo filter.
if [[ -n "$now_override" ]]; then
  today="$now_override"
else
  today="$(date -u +%Y-%m-%d)"
fi

# Compute the 30-day cutoff. Use python3 if available, otherwise BSD/GNU date.
cutoff="$(python3 -c "
from datetime import date, timedelta
y, m, d = '$today'.split('-')
print((date(int(y), int(m), int(d)) - timedelta(days=30)).isoformat())
" 2>/dev/null || true)"
if [[ -z "$cutoff" ]]; then
  # Fallback: BSD date (-v) or GNU date (-d).
  cutoff="$(date -u -v-30d -j -f "%Y-%m-%d" "$today" +%Y-%m-%d 2>/dev/null || true)"
  if [[ -z "$cutoff" ]]; then
    cutoff="$(date -u -d "$today -30 days" +%Y-%m-%d 2>/dev/null || true)"
  fi
fi
if [[ -z "$cutoff" ]]; then
  # Last resort: use today as cutoff (= only today counts as "within 30 days").
  cutoff="$today"
fi

# --- Section builders ------------------------------------------------------

# Emit: top-5 repo learnings by citation count.
# Filters citations JSON by file == "learnings-<slug>.md", sorts by count desc.
emit_top_repo_learnings() {
  if [[ ! -f "$citations_file" ]]; then
    return 0
  fi

  local top_json
  top_json="$(jq -c --arg prefix "learnings-$slug.md#" '
    .citations // {}
    | to_entries
    | map(select(.key | startswith($prefix)))
    | sort_by(-(.value.count // 0))
    | .[0:5]
  ' "$citations_file" 2>/dev/null || echo "[]")"

  if [[ "$top_json" == "[]" || -z "$top_json" ]]; then
    return 0
  fi

  printf '## Top repo learnings (by citation count)\n\n'
  jq -r --arg prefix "learnings-$slug.md#" '
    .[]
    | "- \(.key | sub($prefix; "") | gsub("^\""; "") | gsub("\"$"; "")) — cited \(.value.count) times (last: \(.value.last_cited // "n/a"))"
  ' <<<"$top_json"
  printf '\n'
}

# Emit: top-3 cross-repo patterns in the last 30 days.
# Filters citations by last_cited >= cutoff, sorts by count desc, top 3.
emit_cross_repo_patterns() {
  if [[ ! -f "$citations_file" ]]; then
    return 0
  fi

  local top_json
  top_json="$(jq -c --arg cutoff "$cutoff" '
    .citations // {}
    | to_entries
    | map(select((.value.last_cited // "1970-01-01") >= $cutoff))
    | sort_by(-(.value.count // 0))
    | .[0:3]
  ' "$citations_file" 2>/dev/null || echo "[]")"

  if [[ "$top_json" == "[]" || -z "$top_json" ]]; then
    return 0
  fi

  printf '## Cross-repo patterns (top 3, last 30 days)\n\n'
  jq -r '
    .[]
    | "- `\(.key)` — cited \(.value.count) times (last: \(.value.last_cited // "n/a"))"
  ' <<<"$top_json"
  printf '\n'
}

# Emit: scoped escalation-faq entries.
# Parses escalation-faq.md, keeping entries whose Scope: line matches the slug
# or equals "global", or that lack a Scope: line (default = global).
emit_escalation_faq() {
  if [[ ! -f "$faq_file" ]]; then
    return 0
  fi

  # Strategy: run awk to split file into per-### blocks, emit tagged
  # "QUESTION<TAB>ANSWER<TAB>SCOPE" lines.
  # Scope lookup: strip optional leading "- **", match "Scope:" (case-sensitive).
  local extracted
  extracted="$(awk -v slug="$slug" '
    /^### / {
      # flush previous block
      if (have_q) {
        printf "%s\t%s\t%s\n", q, (ans == "" ? "(no answer)" : ans), (scope == "" ? "global" : scope);
      }
      q = substr($0, 5);
      gsub(/^[ \t]+|[ \t]+$/, "", q);
      ans = ""; scope = ""; have_q = 1; next;
    }
    have_q && /^[[:space:]]*-[[:space:]]*\*\*Answer:\*\*/ {
      line = $0;
      sub(/^[[:space:]]*-[[:space:]]*\*\*Answer:\*\*[[:space:]]*/, "", line);
      ans = line; next;
    }
    have_q && /^[[:space:]]*-[[:space:]]*\*\*Scope:\*\*/ {
      line = $0;
      sub(/^[[:space:]]*-[[:space:]]*\*\*Scope:\*\*[[:space:]]*/, "", line);
      gsub(/^[ \t]+|[ \t]+$/, "", line);
      scope = line; next;
    }
    /^## / && have_q {
      printf "%s\t%s\t%s\n", q, (ans == "" ? "(no answer)" : ans), (scope == "" ? "global" : scope);
      have_q = 0; q = ""; ans = ""; scope = "";
    }
    END {
      if (have_q) {
        printf "%s\t%s\t%s\n", q, (ans == "" ? "(no answer)" : ans), (scope == "" ? "global" : scope);
      }
    }
  ' "$faq_file" 2>/dev/null || true)"

  if [[ -z "$extracted" ]]; then
    return 0
  fi

  # Filter entries: keep where scope == slug OR scope == "global".
  # Truncate the Answer to ~120 chars per line for compactness.
  local filtered
  filtered="$(awk -F'\t' -v slug="$slug" '
    $3 == slug || $3 == "global" {
      ans = $2;
      if (length(ans) > 120) { ans = substr(ans, 1, 117) "..."; }
      printf "- **Q:** %s → **A:** %s\n", $1, ans;
    }
  ' <<<"$extracted")"

  if [[ -z "$filtered" ]]; then
    return 0
  fi

  printf '## Escalation FAQ (scoped)\n\n'
  printf '%s\n\n' "$filtered"
}

# Emit: latest retro's "## Citation leaderboard" section (verbatim excerpt).
emit_retro_leaderboard() {
  if [[ ! -d "$retros_dir" ]]; then
    return 0
  fi

  # Find the most recent retro by lex-descending filename.
  local latest
  latest="$(find "$retros_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | sort -r | head -n1 || true)"
  if [[ -z "$latest" || ! -f "$latest" ]]; then
    return 0
  fi

  # Extract the "## Citation leaderboard" section body (until next H2 or EOF).
  local section
  section="$(awk '
    /^## Citation leaderboard[[:space:]]*$/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec { print }
  ' "$latest" 2>/dev/null || true)"

  # Trim leading/trailing blank lines.
  section="$(printf '%s' "$section" | awk '
    BEGIN{started=0}
    /^[[:space:]]*$/ { if (started) buf = buf "\n"; next }
    { started=1; if (buf != "") printf "%s", buf; buf=""; print $0 }
  ')"

  if [[ -z "$section" ]]; then
    return 0
  fi

  printf '## Latest retro — citation leaderboard\n\n'
  printf '%s\n\n' "$section"
}

# --- Assemble in priority order -------------------------------------------

full="$(
  emit_top_repo_learnings
  emit_cross_repo_patterns
  emit_escalation_faq
  emit_retro_leaderboard
)"

# Strip only trailing blank lines (keep inter-section separators).
full="$(printf '%s' "$full" | awk '
  { buf = buf $0 "\n" }
  END {
    sub(/\n+$/, "\n", buf)
    printf "%s", buf
  }
')"

# Enforce 2000-byte budget. Byte length via LC_ALL=C wc -c.
byte_len="$(printf '%s' "$full" | LC_ALL=C wc -c | tr -d ' ')"

# shellcheck disable=SC2059
marker="$(printf "$TRUNCATION_MARKER" "$slug")"
marker_bytes="$(printf '%s' "$marker" | LC_ALL=C wc -c | tr -d ' ')"

if (( byte_len > BUDGET_BYTES )); then
  # Cap at BUDGET_BYTES - marker_bytes - 2 (for \n\n before marker).
  cap=$(( BUDGET_BYTES - marker_bytes - 2 ))
  if (( cap < 0 )); then cap=0; fi
  truncated="$(printf '%s' "$full" | LC_ALL=C head -c "$cap")"
  # Back up to the last newline so we don't cut a line mid-character.
  # Find last \n offset; if present, trim to it.
  # shellcheck disable=SC2016
  last_nl="$(printf '%s' "$truncated" | awk 'BEGIN{RS="\n"} {last=NR; line[NR]=$0} END{for(i=1;i<last;i++) print line[i]}')"
  if [[ -n "$last_nl" ]]; then
    truncated="$last_nl"
  fi
  # Assemble with marker.
  printf '%s\n\n%s\n' "$truncated" "$marker"
  exit 0
fi

# Under budget — emit as-is, with a single trailing newline.
if [[ -z "$full" ]]; then
  # Fresh repo / empty memory — empty brief is valid.
  exit 0
fi

printf '%s\n' "$full"
exit 0
