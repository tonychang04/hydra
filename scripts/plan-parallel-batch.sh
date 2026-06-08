#!/usr/bin/env bash
#
# plan-parallel-batch.sh — anti-drift parallelism: pre-spawn file-overlap
# detection (ticket #257).
#
# Given a candidate BATCH of tickets, estimate each ticket's likely file/path
# footprint (deterministically, offline, from the ticket title+body) and
# partition the batch into:
#   - a PARALLEL set     — tickets whose footprints are mutually disjoint
#                          (safe to spawn concurrently); and
#   - SERIALIZED groups  — tickets whose footprints overlap (run one-at-a-time,
#                          in ascending ticket-number order).
#   - an UNKNOWN list    — tickets whose footprint could not be estimated
#                          (surfaced, NOT silently parallelized — Commander
#                          writes a coordinate-with hint by hand).
#
# REPORT-ONLY discipline (same as scripts/autopickup-tick.sh): this helper
# RECOMMENDS a partition. It does NOT spawn workers, merge, label, or mutate any
# state. Commander reads the recommendation and actuates. Keeping actuation out
# keeps every irreversible decision in Commander's hands and makes the helper
# trivially testable offline.
#
# It COMPLEMENTS worker-conflict-resolver (it does not replace it):
#   this helper  = PREVENT  — avoid the collision before spawn (serialize overlaps)
#   conflict-res = CURE     — merge the collision after two PRs already conflict
# Two halves of one anti-drift strategy. See the spec table.
#
# Usage:
#   scripts/plan-parallel-batch.sh [--file <path> | (stdin)] [--json]
#
# Input (JSON; --file or stdin):
#   { "tickets": [ { "number": <int>, "title": "...", "body": "...",
#                    "footprint": ["path/a", ...]   # optional explicit override
#                  }, ... ] }
#   The shape is a subset of `gh api /repos/.../issues` (number/title/body), so a
#   small jq projection of gh output pipes straight in.
#
# Output:
#   default   grouped human report
#   --json    one stable object: {generated_at, batch_size, parallel,
#             serialize_groups:[{group,shared,order}], unknown, footprints,
#             recommendation}
#
# Exit codes:
#   0 = partition produced (report printed)
#   2 = usage / parse error (bad flag, unreadable file, malformed JSON, empty batch)
#
# Spec: docs/specs/2026-06-07-anti-drift-parallelism.md
# Style mirrors scripts/autopickup-tick.sh and scripts/pr-shepherd.sh.

set -euo pipefail

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_YELLOW=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

usage() {
  cat <<'EOF'
Usage: plan-parallel-batch.sh [--file <path>] [--json]

Anti-drift parallelism (#257): partition a candidate ticket batch into a
parallel-safe set (disjoint file footprints) + serialized groups (overlapping
footprints) + an unknown list, by deterministically estimating each ticket's
file footprint from its title+body. REPORT-ONLY — recommends, never spawns.

Input (JSON; --file or stdin):
  { "tickets": [ { "number": 301, "title": "...", "body": "...",
                   "footprint": ["scripts/x.sh"]   # optional override
                 }, ... ] }

Options:
  --file <path>   read the batch JSON from a file (default: stdin)
  --json          emit machine-readable JSON instead of the human report
  -h, --help      show this help

Output (--json):
  {generated_at, batch_size, parallel:[...], unknown:[...],
   serialize_groups:[{group:[...], shared:[...], order:[...]}],
   footprints:{"<n>":{paths:[...], source:"..."}}, recommendation:"..."}

Exit codes:
  0 = partition produced     2 = usage / parse error (bad flag, unreadable file,
                                 malformed JSON, empty batch)

Composes with worker-conflict-resolver: this PREVENTS collisions before spawn;
the conflict-resolver CURES collisions after two PRs conflict. Both stay.

Spec: docs/specs/2026-06-07-anti-drift-parallelism.md
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
src_file=""
json_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { echo "plan-parallel-batch: --file needs a value" >&2; exit 2; }
      src_file="$2"; shift 2 ;;
    --file=*)
      src_file="${1#--file=}"; shift ;;
    --json)
      json_mode=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "plan-parallel-batch: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "plan-parallel-batch: jq not found on PATH" >&2; exit 2; }

# -----------------------------------------------------------------------------
# read the batch
# -----------------------------------------------------------------------------
if [[ -n "$src_file" ]]; then
  [[ -r "$src_file" ]] || { echo "plan-parallel-batch: file not readable: $src_file" >&2; exit 2; }
  batch="$(cat -- "$src_file")"
else
  batch="$(cat)"
fi

printf '%s' "$batch" | jq empty 2>/dev/null \
  || { echo "plan-parallel-batch: input is not valid JSON" >&2; exit 2; }

batch_size="$(printf '%s' "$batch" | jq -r '(.tickets // []) | length')"
if [[ "$batch_size" -eq 0 ]]; then
  echo "plan-parallel-batch: empty batch (no .tickets[])" >&2
  exit 2
fi

# Every ticket must have an integer number.
if ! printf '%s' "$batch" | jq -e '(.tickets // []) | all(.number != null and (.number | type == "number"))' >/dev/null 2>&1; then
  echo "plan-parallel-batch: every ticket needs an integer .number" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# keyword -> directory-bucket table (the one place to extend). Conservative on
# purpose: a coarse bucket means "in doubt, serialize" (cheaper error).
# -----------------------------------------------------------------------------
# Each entry: "<keyword regex>=<bucket path>". Matching is case-insensitive over
# the lowercased title+body. A bucket ending in "/" is a directory prefix.
KEYWORD_BUCKETS=(
  'autopickup tick=scripts/autopickup-tick.sh'
  'autopickup=scripts/autopickup-tick.sh'
  ' tick =scripts/autopickup-tick.sh'
  'self-test=self-test/'
  'self test=self-test/'
  'golden=self-test/'
  'fixture=self-test/'
  'claude.md=CLAUDE.md'
  'routing table=CLAUDE.md'
  'commander rules=CLAUDE.md'
  'spec=docs/specs/'
  ' docs=docs/'
  'memory=memory/'
  'learnings=memory/'
  'citation=memory/'
  'escalation-faq=memory/escalation-faq.md'
  'schema=state/'
  'state file=state/'
  'subagent=.claude/agents/'
  'worker agent=.claude/agents/'
  ' agent =.claude/agents/'
  'skill=.claude/skills/'
)

# -----------------------------------------------------------------------------
# footprint_for <number> -> prints "<source>\t<path>\n<path>..." (paths one/line)
# Order of precedence: explicit override > explicit-path tokens > keyword buckets.
# When explicit-path AND keyword both fire, source = "explicit-path+keyword".
# Empty result => source "none".
# -----------------------------------------------------------------------------
footprint_for() {
  local num="$1"
  local ticket title body override_n
  ticket="$(printf '%s' "$batch" | jq -c --argjson n "$num" '(.tickets // [])[] | select(.number == $n)')"

  # 1. explicit override
  override_n="$(printf '%s' "$ticket" | jq -r '(.footprint // []) | length')"
  if [[ "$override_n" -gt 0 ]]; then
    printf 'override\n'
    printf '%s' "$ticket" | jq -r '(.footprint // [])[]' | sort -u
    return
  fi

  title="$(printf '%s' "$ticket" | jq -r '.title // ""')"
  body="$(printf '%s' "$ticket" | jq -r '.body // ""')"
  local text="$title $body"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  local -a paths=()
  local got_explicit=0 got_keyword=0

  # 2. explicit-path tokens: foo/bar.ext and bare well-known top-level files.
  # Extract path-like tokens with a known source extension.
  local tok
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    paths+=("$tok"); got_explicit=1
  done < <(printf '%s' "$text" \
            | grep -oE '[A-Za-z0-9_][A-Za-z0-9_./-]*\.(sh|bash|md|json|py|js|ts|tsx|yml|yaml|toml)' \
            | sort -u)

  # bare well-known top-level files (no slash) — only if spelled exactly.
  local wk
  for wk in CLAUDE.md policy.md budget.json AGENTS.md README.md; do
    if printf '%s' "$lower" | grep -qiF -- "$wk"; then
      # avoid double-add when already matched as a path token
      local already=0 p
      for p in "${paths[@]:-}"; do [[ "$p" == "$wk" ]] && already=1; done
      [[ "$already" -eq 0 ]] && { paths+=("$wk"); got_explicit=1; }
    fi
  done

  # 3. keyword buckets
  # NOTE (#257 review): matching is plain SUBSTRING (grep -qF), not word-boundary
  # aware. A short keyword can therefore match inside a longer unrelated word —
  # e.g. ' docs' matches ' docstring' and would mis-bucket it under docs/. This
  # is deliberately tolerated: a false keyword hit can only ADD a bucket, which
  # at worst over-serializes two tickets (the cheaper error this helper biases
  # toward — see "Risks / rollback" in the spec), never causes a missed
  # collision. If a specific keyword proves too greedy, tighten it in the
  # KEYWORD_BUCKETS table above (e.g. add surrounding spaces, as ' tick ' and
  # ' docs' already do) rather than reworking the matcher.
  local entry kw bucket
  for entry in "${KEYWORD_BUCKETS[@]}"; do
    kw="${entry%%=*}"
    bucket="${entry#*=}"
    if printf '%s' "$lower" | grep -qF -- "$kw"; then
      local already=0 p
      for p in "${paths[@]:-}"; do [[ "$p" == "$bucket" ]] && already=1; done
      [[ "$already" -eq 0 ]] && { paths+=("$bucket"); got_keyword=1; }
    fi
  done

  if [[ ${#paths[@]} -eq 0 ]]; then
    printf 'none\n'
    return
  fi

  local source="unknown"
  if [[ "$got_explicit" -eq 1 && "$got_keyword" -eq 1 ]]; then
    source="explicit-path+keyword"
  elif [[ "$got_explicit" -eq 1 ]]; then
    source="explicit-path"
  elif [[ "$got_keyword" -eq 1 ]]; then
    source="keyword"
  fi
  printf '%s\n' "$source"
  printf '%s\n' "${paths[@]}" | sort -u
}

# -----------------------------------------------------------------------------
# gather per-ticket footprints into ONE JSON array. Bash 3.2-portable: no
# associative arrays, no mapfile — iterate jq-extracted numbers via a read loop
# and accumulate a JSON list, then hand the whole graph problem to jq.
#   foots = [ { number, paths:[...], source } ]  (sorted by number)
# -----------------------------------------------------------------------------
foots="[]"
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  out="$(footprint_for "$n")"
  src="$(printf '%s' "$out" | head -n1)"
  # tail+grep may emit nothing (empty footprint); guard so the pipe never fails.
  paths_json="$(printf '%s' "$out" | tail -n +2 | { grep -v '^$' || true; } | jq -R '.' | jq -sc '.')"
  if [[ -z "$paths_json" || "$paths_json" == "null" ]]; then paths_json="[]"; fi
  foots="$(printf '%s' "$foots" | jq -c \
    --argjson num "$n" --argjson paths "$paths_json" --arg src "$src" \
    '. + [{number:$num, paths:$paths, source:$src}]')"
done < <(printf '%s' "$batch" | jq -r '(.tickets // [])[].number' | sort -n)

# -----------------------------------------------------------------------------
# Partition entirely in jq (deterministic): overlap graph -> connected
# components -> parallel / serialize / unknown.
#
# overlap(a;b): true if any path in a's footprint and any in b's are equal OR one
# is a directory-prefix (a bucket ending in "/") of the other. Unknown-footprint
# tickets (source=="none") are excluded from the graph and surfaced separately.
#
# Connected components via iterative closure: seed each known ticket's component
# with itself + its direct overlap neighbors, then repeatedly merge components
# that intersect until a fixpoint. n is single-digit so this is trivial.
# -----------------------------------------------------------------------------
GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

result_json="$(printf '%s' "$foots" | jq -c \
  --arg generated_at "$GEN_TS" \
  --argjson batch_size "$batch_size" '
  # --- helpers ---------------------------------------------------------------
  def path_overlap($p; $q):
    ($p == $q)
    or (($p|endswith("/")) and ($q|startswith($p)))
    or (($q|endswith("/")) and ($p|startswith($q)));
  def foot_overlap($a; $b):
    any($a.paths[]; . as $pa | any($b.paths[]; path_overlap($pa; .)));
  def shared($a; $b):
    [ $a.paths[] as $pa | $b.paths[] as $pb
      | select(path_overlap($pa; $pb))
      | (if ($pa|length) >= ($pb|length) then $pa else $pb end) ]
    | unique;

  . as $foots
  | ($foots | map(select(.source != "none"))) as $known
  | ($foots | map(select(.source == "none")) | map(.number) | sort) as $unknown

  # adjacency: for each known ticket, the set of known numbers it overlaps
  # (including itself) -> initial component sets.
  | ( [ $known[] as $a
        | { ($a.number|tostring):
            ( [ $a.number ] + [ $known[] as $b
                                | select($b.number != $a.number and foot_overlap($a; $b))
                                | $b.number ] | unique ) } ]
      | add // {} ) as $adj

  # merge overlapping component sets to a fixpoint (union-find by iteration).
  | ( [ $adj[] ] ) as $comps0
  | def merge_once($cs):
      # Fold each set into an accumulator of disjoint sets: a new set is unioned
      # into any existing accumulator sets it intersects, else appended.
      reduce $cs[] as $c ([];
        . as $acc
        | ( [ $acc[] | select( any(.[]; . as $x | $c | index($x)) ) ] ) as $hit
        | ( [ $acc[] | select( (any(.[]; . as $x | $c | index($x))) | not) ] ) as $miss
        | if ($hit | length) == 0
          then $acc + [ ($c | unique | sort) ]
          else $miss + [ ( ($hit | add) + $c ) | unique | sort ]
          end );
    def fixpoint($cs):
      merge_once($cs) as $next
      | if ($next | length) == ($cs | length) then $next else fixpoint($next) end;
    (fixpoint($comps0)) as $components

  # classify components: size 1 -> parallel; size >=2 -> serialize group.
  | ( $components | map(select(length == 1)) | map(.[0]) | sort ) as $parallel
  | ( $components | map(select(length >= 2)) | sort_by(.[0]) ) as $serial_sets

  | { generated_at: $generated_at,
      batch_size: $batch_size,
      parallel: $parallel,
      serialize_groups:
        [ $serial_sets[] as $grp
          | ($grp | sort) as $g
          | { group: $g,
              shared:
                ( [ range(0; ($g|length)) as $i
                    | range($i+1; ($g|length)) as $j
                    | ($known[] | select(.number == $g[$i])) as $fa
                    | ($known[] | select(.number == $g[$j])) as $fb
                    | shared($fa; $fb)[] ] | unique ),
              order: $g } ],
      unknown: $unknown,
      footprints:
        ( [ $foots[] | { key: (.number|tostring),
                         value: { paths: .paths, source: .source } } ] | from_entries )
    }
  # recommendation one-liner
  | . as $r
  | .recommendation =
      ( [ ( if ($r.parallel|length) > 0
            then "spawn " + ($r.parallel|map(tostring)|join(", ")) + " in parallel" else empty end ),
          ( $r.serialize_groups[]
            | "serialize [" + (.order|map(tostring)|join(" -> ")) + "]"
              + (if (.shared|length) > 0 then " (share " + (.shared|join(", ")) + ")" else "" end) ),
          ( if ($r.unknown|length) > 0
            then "unknown footprint: " + ($r.unknown|map(tostring)|join(", "))
                 + " — write a coordinate-with hint by hand" else empty end )
        ]
        | if length == 0 then "no tickets to partition" else join("; ") end )
')"

# convenience extracts for the human report
gn="$(printf '%s' "$result_json" | jq '.serialize_groups | length')"

# -----------------------------------------------------------------------------
# output
# -----------------------------------------------------------------------------
if [[ "$json_mode" -eq 1 ]]; then
  printf '%s\n' "$result_json"
  exit 0
fi

# human report
echo "${C_BOLD}▸ Parallel-batch plan — $batch_size ticket(s)  ($GEN_TS)${C_RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "${C_GREEN}Parallel-safe (disjoint footprints — spawn concurrently):${C_RESET}"
if [[ "$(printf '%s' "$result_json" | jq '.parallel | length')" -eq 0 ]]; then
  echo "  (none)"
else
  printf '%s' "$result_json" | jq -r '.parallel[] as $n | "  #\($n)  " + (.footprints[($n|tostring)].paths | join(", "))'
fi
echo

echo "${C_YELLOW}Serialize (overlapping footprints — one-at-a-time, in order):${C_RESET}"
if [[ "$gn" -eq 0 ]]; then
  echo "  (none)"
else
  printf '%s' "$result_json" | jq -r '.serialize_groups[] | "  [" + (.order|map("#"+tostring)|join(" -> ")) + "]" + (if (.shared|length)>0 then "   shared: " + (.shared|join(", ")) else "" end)'
fi
echo

echo "Unknown footprint (NOT auto-parallelized — write a coordinate-with hint):"
if [[ "$(printf '%s' "$result_json" | jq '.unknown | length')" -eq 0 ]]; then
  echo "  (none)"
else
  printf '%s' "$result_json" | jq -r '.unknown[] | "  #\(.)"'
fi
echo

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "${C_DIM}Recommendation (report-only — Commander actuates):${C_RESET}"
printf '%s' "$result_json" | jq -r '"  " + .recommendation'
echo "${C_DIM}Complements worker-conflict-resolver: this PREVENTS collisions pre-spawn;${C_RESET}"
echo "${C_DIM}the conflict-resolver CURES collisions after PRs conflict.${C_RESET}"
exit 0
