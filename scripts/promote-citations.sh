#!/usr/bin/env bash
#
# promote-citations.sh — skill-promotion pipeline.
#
# Scans state/memory-citations.json for entries where
#   count >= 3 AND len(unique(tickets)) >= 3
# and, for each eligible entry, drafts a .claude/skills/<slug>/SKILL.md in
# the target repo + opens a draft PR labeled commander-skill-promotion.
#
# Idempotent on re-run: if the SKILL.md already exists, only the delimited
# citations block is rewritten (and only if it changed). Pre-existing
# operator edits outside the markers are preserved.
#
# Spec: docs/specs/2026-04-17-skill-promotion-automation.md
# Lifecycle rule: memory/memory-lifecycle.md (3+ citations across 3+ distinct tickets)
#
# Usage:
#   promote-citations.sh [options]
#
# Options:
#   --state-dir <path>       default: ./state
#   --memory-dir <path>      default: $HYDRA_EXTERNAL_MEMORY_DIR or ./memory
#   --repos-file <path>      default: <state-dir>/repos.json
#   --dry-run                print plan only, no git/gh side effects
#   --only <key>             only consider one citation key (for tests)
#   --author <name>          default: "hydra worker"
#   --now <YYYY-MM-DD>       override today's date (for deterministic tests)
#   -h, --help               show this help
#
# Exit codes:
#   0  success (PRs may have been opened; empty-list days are success too)
#   1  unexpected error (git/gh failure, malformed JSON)
#   2  usage error

set -euo pipefail

STATE_DIR_DEFAULT="./state"
MEMORY_DIR_DEFAULT="./memory"
SKILL_LABEL="commander-skill-promotion"
SKILL_LABEL_COLOR="1D76DB"
SKILL_LABEL_DESC="PR promotes a frequently-cited memory entry to a repo skill (#145)"
CITATIONS_START="<!-- hydra:citations-start -->"
CITATIONS_END="<!-- hydra:citations-end -->"

usage() {
  sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//'
}

state_dir=""
memory_dir=""
repos_file=""
dry_run=0
only_key=""
author="hydra worker"
now_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 ]] || { echo "promote-citations: --state-dir needs a value" >&2; exit 2; }
      state_dir="$2"; shift 2 ;;
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "promote-citations: --memory-dir needs a value" >&2; exit 2; }
      memory_dir="$2"; shift 2 ;;
    --repos-file)
      [[ $# -ge 2 ]] || { echo "promote-citations: --repos-file needs a value" >&2; exit 2; }
      repos_file="$2"; shift 2 ;;
    --dry-run)
      dry_run=1; shift ;;
    --only)
      [[ $# -ge 2 ]] || { echo "promote-citations: --only needs a value" >&2; exit 2; }
      only_key="$2"; shift 2 ;;
    --author)
      [[ $# -ge 2 ]] || { echo "promote-citations: --author needs a value" >&2; exit 2; }
      author="$2"; shift 2 ;;
    --now)
      [[ $# -ge 2 ]] || { echo "promote-citations: --now needs a value" >&2; exit 2; }
      now_override="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "promote-citations: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      echo "promote-citations: no positional args accepted: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$state_dir" ]]; then
  state_dir="$STATE_DIR_DEFAULT"
fi
if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi
if [[ -z "$repos_file" ]]; then
  repos_file="$state_dir/repos.json"
fi

citations_file="$state_dir/memory-citations.json"

# Missing citations file is not an error — just means nothing to promote.
if [[ ! -f "$citations_file" ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    echo "promote-citations: no citations file at $citations_file (nothing to do)" >&2
  fi
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "promote-citations: jq is required" >&2
  exit 1
fi

# Today (ISO). Override for tests.
if [[ -n "$now_override" ]]; then
  today="$now_override"
else
  today="$(date -u +%Y-%m-%d)"
fi

# --- Selection -------------------------------------------------------------
# Emit TSV of eligible keys: <key>\t<count>\t<tickets_csv>\t<last_cited>
# where tickets_csv is comma-separated distinct tickets.

select_eligible() {
  local only_filter='.'
  if [[ -n "$only_key" ]]; then
    # Quote safely for jq via --arg.
    only_filter='select(.key == $only)'
  fi

  jq -r --arg only "$only_key" '
    .citations // {}
    | to_entries
    | map(select((.key | startswith("_")) | not))
    | map({
        key: .key,
        count: (.value.count // 0),
        tickets: ((.value.tickets // []) | unique),
        last_cited: (.value.last_cited // "n/a")
      })
    | map(select(.count >= 3 and (.tickets | length) >= 3))
    | if ($only | length) > 0
        then map(select(.key == $only))
        else .
      end
    | .[]
    | [.key, (.count | tostring), (.tickets | join(",")), .last_cited]
    | @tsv
  ' "$citations_file"
}

# --- Helpers ---------------------------------------------------------------

# Slug: lowercase, non-alnum → "-", trim, cap 60.
slugify() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  # Cap at 60 chars.
  printf '%s' "${s:0:60}"
}

# Memory-file → shorthand slug-prefix. Strips .md extension.
file_prefix() {
  local file="$1"
  local base="${file%.md}"
  printf '%s' "$(slugify "$base")"
}

# Parse a citation key "<file>#<quote>" → file + quote (stripped of surrounding quotes).
parse_key() {
  local key="$1"
  local file="${key%%#*}"
  local rest="${key#*#}"
  # Strip surrounding straight double quotes if present.
  if [[ "$rest" == \"*\" ]]; then
    rest="${rest%\"}"
    rest="${rest#\"}"
  fi
  printf '%s\t%s' "$file" "$rest"
}

# Resolve target repo: given a learnings-<slug>.md filename, find the matching
# repos[].local_path in repos_file. Cross-cutting files (escalation-faq.md,
# memory-lifecycle.md, tier-edge-cases.md, worker-failures.md) return empty —
# caller skips with a warning.
resolve_target_repo() {
  local file="$1"

  # Cross-cutting files have no single target.
  case "$file" in
    escalation-faq.md|memory-lifecycle.md|tier-edge-cases.md|worker-failures.md|MEMORY.md)
      return 1
      ;;
  esac

  # Only learnings-<slug>.md entries are per-repo.
  if [[ "$file" != learnings-*.md ]]; then
    return 1
  fi

  if [[ ! -f "$repos_file" ]]; then
    return 1
  fi

  local slug="${file#learnings-}"
  slug="${slug%.md}"
  local slug_lower
  slug_lower="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"

  # Match repos[] by basename (case-insensitive). Emit <local_path>\t<owner/name>.
  jq -r --arg s "$slug" --arg sl "$slug_lower" '
    .repos // []
    | map(select((.enabled // true) == true))
    | map(select(
        (.name // "") == $s
        or ((.name // "") | ascii_downcase) == $sl
        or (((.owner // "") + "-" + (.name // "")) == $s)
        or ((((.owner // "") + "-" + (.name // "")) | ascii_downcase) == $sl)
      ))
    | .[0]
    | if . == null then empty else "\(.local_path)\t\(.owner)/\(.name)" end
  ' "$repos_file"
}

# Grep the memory file for the quote and return a small context window
# (quote + up to 5 surrounding lines on each side). Prints the lines.
extract_context() {
  local memfile="$1" quote="$2"
  if [[ ! -f "$memfile" ]]; then
    return 0
  fi
  local lineno
  lineno="$(grep -nF -- "$quote" "$memfile" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [[ -z "$lineno" ]]; then
    return 0
  fi
  local start=$((lineno - 2))
  local end=$((lineno + 5))
  (( start < 1 )) && start=1
  sed -n "${start},${end}p" "$memfile"
}

# Build the SKILL.md body. Uses the shape documented in .claude/skills/README.md.
# Inputs: name, description, quote, source_file, context_block, citations_block.
build_skill_body() {
  local name="$1"
  local description="$2"
  local quote="$3"
  local source_file="$4"
  local context="$5"
  local citations="$6"

  cat <<EOF
---
name: $name
description: |
  $description
---

# $name

## Overview

Promoted from \`memory/$source_file\` — the operator cited this pattern 3+
times across 3+ distinct tickets, so it graduates here for every worker
to pick up automatically (Step 0 reads \`.claude/skills/*\`).

The load-bearing quote from memory is:

> $quote

## When to Use

Apply this pattern whenever the condition described below is active.
(The operator should edit this section to make the trigger explicit —
the promotion script leaves the Overview/context intact but this section
is the one that Claude's skill matcher keys on.)

## Process

$(if [[ -n "$context" ]]; then
    printf 'Context excerpt from the source memory entry:\n\n```\n%s\n```\n' "$context"
  else
    printf '_No extra context was found in the source memory file — edit this section to fill in the procedure._\n'
  fi)

## Citations

$CITATIONS_START
$citations
$CITATIONS_END

## Verification

How to confirm a worker applied this skill correctly. (Edit post-merge.)
EOF
}

# Render the citations block body: bullet list of tickets + last-promoted date.
render_citations_block() {
  local count="$1" tickets_csv="$2" last_cited="$3"
  printf 'Cited **%d** times across these tickets:\n\n' "$count"
  # Stable ordering.
  printf '%s' "$tickets_csv" | tr ',' '\n' | sort -u | sed 's/^/- /'
  printf '\n'
  printf 'Last citation: %s\n' "$last_cited"
  printf 'Last promoted: %s\n' "$today"
}

# Replace the block between CITATIONS_START and CITATIONS_END in a file with
# new content from stdin. If the markers are missing, appends the block.
splice_citations_block() {
  local target="$1"
  local new_block
  new_block="$(cat)"
  # If markers present, replace in place with awk (portable).
  if grep -qF -- "$CITATIONS_START" "$target" && grep -qF -- "$CITATIONS_END" "$target"; then
    local tmp
    tmp="$(mktemp)"
    awk -v start="$CITATIONS_START" -v end="$CITATIONS_END" -v replacement="$new_block" '
      BEGIN { in_block=0 }
      {
        if ($0 == start) {
          print start
          print replacement
          in_block=1
          next
        }
        if ($0 == end) {
          print end
          in_block=0
          next
        }
        if (!in_block) print
      }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
  else
    {
      printf '\n## Citations\n\n'
      printf '%s\n' "$CITATIONS_START"
      printf '%s\n' "$new_block"
      printf '%s\n' "$CITATIONS_END"
    } >> "$target"
  fi
}

# Ensure the skill-promotion label exists on the repo. Idempotent.
ensure_label() {
  local repo_nwo="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    return 0
  fi
  if ! gh label list --repo "$repo_nwo" --json name \
      | jq -e --arg n "$SKILL_LABEL" '.[] | select(.name == $n)' >/dev/null 2>&1; then
    gh label create "$SKILL_LABEL" \
      --repo "$repo_nwo" \
      --color "$SKILL_LABEL_COLOR" \
      --description "$SKILL_LABEL_DESC" 2>/dev/null || true
  fi
}

# Apply a label to a PR via the REST API (per CLAUDE.md § "Applying labels").
apply_label() {
  local repo_nwo="$1" pr_number="$2"
  if [[ "$dry_run" -eq 1 ]]; then
    return 0
  fi
  gh api --method POST "/repos/$repo_nwo/issues/$pr_number/labels" \
      -f "labels[]=$SKILL_LABEL" >/dev/null 2>&1 || true
}

# Find existing open draft PR on a branch. Echoes number or empty.
find_open_pr() {
  local repo_nwo="$1" branch="$2"
  gh pr list --repo "$repo_nwo" --head "$branch" --state open \
      --json number --jq '.[0].number // empty' 2>/dev/null || true
}

# --- Per-entry processor ---------------------------------------------------

process_entry() {
  local key="$1" count="$2" tickets_csv="$3" last_cited="$4"

  local file quote
  IFS=$'\t' read -r file quote < <(parse_key "$key")
  if [[ -z "$file" || -z "$quote" ]]; then
    echo "promote-citations: skip: malformed key '$key'" >&2
    return 0
  fi

  # Cross-cutting files → not supported in v1; warn and skip.
  local resolve_out
  resolve_out="$(resolve_target_repo "$file" || true)"
  if [[ -z "$resolve_out" ]]; then
    echo "promote-citations: skip: no single target repo for '$file' (cross-cutting or unmatched) — key=$key" >&2
    return 0
  fi
  local local_path repo_nwo
  IFS=$'\t' read -r local_path repo_nwo <<<"$resolve_out"

  # Slug = file-prefix + slugified-quote; caps each half.
  local file_prefix_slug quote_slug combined_slug
  file_prefix_slug="$(file_prefix "$file")"
  quote_slug="$(slugify "$quote")"
  combined_slug="${file_prefix_slug}-${quote_slug}"
  combined_slug="${combined_slug:0:80}"

  local skill_dir=".claude/skills/$combined_slug"
  local skill_path="$skill_dir/SKILL.md"
  local branch="commander/skill-promote/$combined_slug"

  local citations_block
  citations_block="$(render_citations_block "$count" "$tickets_csv" "$last_cited")"

  if [[ "$dry_run" -eq 1 ]]; then
    local full_skill_path="$local_path/$skill_path"
    local action
    if [[ -f "$full_skill_path" ]]; then
      action="would update"
    else
      action="would create"
    fi
    printf 'ELIGIBLE\tkey=%s\trepo=%s\tbranch=%s\tskill=%s\taction=%s\n' \
      "$key" "$repo_nwo" "$branch" "$skill_path" "$action"
    printf 'would open PR\ttitle=skill promotion: %s\tlabel=%s\n' \
      "$quote" "$SKILL_LABEL"
    return 0
  fi

  # Non-dry-run path: worktree + author + commit + push + PR.
  if [[ ! -d "$local_path" ]]; then
    echo "promote-citations: skip: local_path does not exist: $local_path" >&2
    return 0
  fi

  # Use a dedicated worktree inside the target repo's worktree area.
  local worktree_dir="$local_path/.claude/worktrees/promote-$combined_slug"
  if [[ ! -d "$worktree_dir" ]]; then
    git -C "$local_path" worktree add -B "$branch" "$worktree_dir" HEAD \
      >/dev/null 2>&1 \
      || {
        echo "promote-citations: failed to create worktree at $worktree_dir" >&2
        return 0
      }
  fi

  # Read source context from the memory file (one-level-up from the worktree
  # memory dir — we resolve memory-dir from the launcher's env, not the
  # target-repo worktree).
  local memfile="$memory_dir/$file"
  local context
  context="$(extract_context "$memfile" "$quote")"

  # Compose a minimal description for the SKILL.md frontmatter.
  local description
  description="Promoted memory entry (source: $file). Quote: \"$quote\". Cited $count times across $(printf '%s' "$tickets_csv" | tr ',' '\n' | sort -u | wc -l | tr -d ' ') distinct tickets. Edit the description after merge to tighten the skill trigger. (Hydra)"

  local full_skill_dir="$worktree_dir/$skill_dir"
  local full_skill_path="$worktree_dir/$skill_path"
  mkdir -p "$full_skill_dir"

  local changed=0

  if [[ -f "$full_skill_path" ]]; then
    # Idempotent update: rewrite citations block only.
    local before
    before="$(cat "$full_skill_path")"
    printf '%s\n' "$citations_block" | splice_citations_block "$full_skill_path"
    if [[ "$before" != "$(cat "$full_skill_path")" ]]; then
      changed=1
    fi
  else
    # First-time author: write a full SKILL.md from template.
    build_skill_body "$combined_slug" "$description" "$quote" "$file" "$context" "$citations_block" \
      > "$full_skill_path"
    changed=1
  fi

  if [[ "$changed" -eq 0 ]]; then
    echo "promote-citations: no change for $repo_nwo:$skill_path (already up to date)" >&2
    return 0
  fi

  # Commit + push + PR.
  git -C "$worktree_dir" add "$skill_path" >/dev/null
  local msg
  msg="$(cat <<EOM
chore(skills): promote $combined_slug (cited $count times)

Source: memory/$file
Quote: "$quote"
Tickets: $tickets_csv

Spec: docs/specs/2026-04-17-skill-promotion-automation.md
Closes: none (automated skill promotion; operator reviews before merge)
EOM
  )"
  git -C "$worktree_dir" commit -m "$msg" --author "$author <hydra@localhost>" >/dev/null 2>&1 || {
    echo "promote-citations: nothing to commit in $worktree_dir (skipping PR)" >&2
    return 0
  }

  git -C "$worktree_dir" push -u origin "$branch" >/dev/null 2>&1 || {
    echo "promote-citations: push failed for $branch on $repo_nwo" >&2
    return 1
  }

  ensure_label "$repo_nwo"

  local existing_pr
  existing_pr="$(find_open_pr "$repo_nwo" "$branch")"
  local body_file
  body_file="$(mktemp)"
  {
    printf 'Automated skill promotion — citations crossed threshold.\n\n'
    printf '- Source memory file: `memory/%s`\n' "$file"
    printf '- Quote: `%s`\n' "$quote"
    printf '- Citation count: %s\n' "$count"
    printf '- Tickets that cited this entry:\n'
    printf '%s' "$tickets_csv" | tr ',' '\n' | sort -u | sed 's/^/  - /'
    printf '\n\n'
    printf 'Spec: `docs/specs/2026-04-17-skill-promotion-automation.md`\n'
    printf 'Lifecycle: `memory/memory-lifecycle.md`\n\n'
    printf 'The operator should tighten the `description:` frontmatter and\n'
    printf 'the **When to Use** / **Verification** sections before merge — the\n'
    printf 'automated draft is a scaffold, not a final skill.\n'
  } > "$body_file"

  if [[ -n "$existing_pr" ]]; then
    gh pr edit "$existing_pr" --repo "$repo_nwo" --body-file "$body_file" >/dev/null 2>&1 || true
    echo "promote-citations: updated PR #$existing_pr on $repo_nwo" >&2
  else
    local pr_url
    pr_url="$(gh pr create --repo "$repo_nwo" --draft \
      --title "skill promotion: $quote" \
      --head "$branch" \
      --base main \
      --body-file "$body_file" 2>&1 || true)"
    echo "promote-citations: opened $pr_url" >&2
    local pr_number
    pr_number="$(printf '%s' "$pr_url" | grep -oE '/pull/[0-9]+' | tr -cd '0-9' || true)"
    if [[ -n "$pr_number" ]]; then
      apply_label "$repo_nwo" "$pr_number"
    fi
  fi
  rm -f "$body_file"
}

# --- Main ------------------------------------------------------------------

# Selection.
eligible_tsv="$(select_eligible)"

if [[ -z "$eligible_tsv" ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    echo "promote-citations: no eligible entries (count >= 3 AND distinct tickets >= 3)" >&2
  fi
  exit 0
fi

exit_code=0
while IFS=$'\t' read -r key count tickets_csv last_cited; do
  [[ -z "$key" ]] && continue
  if ! process_entry "$key" "$count" "$tickets_csv" "$last_cited"; then
    exit_code=1
  fi
done <<<"$eligible_tsv"

exit "$exit_code"
