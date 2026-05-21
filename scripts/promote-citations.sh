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
#   --check-due              once/day gate for the autopickup tick: compare
#                            state/autopickup.json:last_promotion_run to today.
#                            Exit 0 = due (run promotion); exit 10 = already
#                            ran today (skip). No side effects.
#   --greeting-count         print the number of open draft commander-skill-
#                            promotion PRs across enabled repos (for the
#                            session-greeting one-liner). Always exits 0;
#                            best-effort (prints 0 on any error).
#   -h, --help               show this help
#
# Exit codes:
#   0  success (PRs may have been opened; empty-list days are success too).
#      For --check-due: "due" (promotion should run today).
#   1  unexpected error (git/gh failure, malformed JSON)
#   2  usage error
#   10 (--check-due only) not due — promotion already ran today

set -euo pipefail

STATE_DIR_DEFAULT="./state"
MEMORY_DIR_DEFAULT="./memory"
SKILL_LABEL="commander-skill-promotion"
SKILL_LABEL_COLOR="1D76DB"
SKILL_LABEL_DESC="PR promotes a frequently-cited memory entry to a repo skill (#145)"
CITATIONS_START="<!-- hydra:citations-start -->"
CITATIONS_END="<!-- hydra:citations-end -->"

usage() {
  sed -n '5,43p' "$0" | sed 's/^# \{0,1\}//'
}

state_dir=""
memory_dir=""
repos_file=""
dry_run=0
only_key=""
author="hydra worker"
now_override=""
check_due=0
greeting_count=0

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
    --check-due)
      check_due=1; shift ;;
    --greeting-count)
      greeting_count=1; shift ;;
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

if [[ "$check_due" -eq 1 && "$greeting_count" -eq 1 ]]; then
  echo "promote-citations: --check-due and --greeting-count are mutually exclusive" >&2
  exit 2
fi

# Today (ISO). Override for tests. Resolved early so the gate modes can use it.
if [[ -n "$now_override" ]]; then
  today="$now_override"
else
  today="$(date -u +%Y-%m-%d)"
fi

# --- Mode: --check-due -----------------------------------------------------
# Once/day gate for the autopickup tick. Compares
# state/autopickup.json:last_promotion_run to today. The tick runs this; on
# exit 0 it runs the real promotion and stamps last_promotion_run=today. A
# missing autopickup.json (or missing/null last_promotion_run) means promotion
# has never run today → due. No mutation here — stamping is the tick's job.
if [[ "$check_due" -eq 1 ]]; then
  autopickup_file="$state_dir/autopickup.json"
  if [[ ! -f "$autopickup_file" ]]; then
    # Fresh install — never promoted. Due.
    exit 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "promote-citations: jq is required for --check-due" >&2
    exit 2
  fi
  last_run="$(jq -r '.last_promotion_run // ""' "$autopickup_file" 2>/dev/null || true)"
  if [[ "$last_run" == "$today" ]]; then
    exit 10   # already promoted today — not due
  fi
  exit 0      # null / missing / stale → due
fi

# --- Mode: --greeting-count ------------------------------------------------
# Print the number of open draft commander-skill-promotion PRs across enabled
# repos, for the session-greeting one-liner. Best-effort: always exits 0 and
# prints an integer (0 on any error). Tests inject HYDRA_PROMOTION_COUNT_CMD
# to avoid network: it is invoked once per enabled repo with the repo's
# <owner>/<name> as $1 and is expected to print that repo's count.
if [[ "$greeting_count" -eq 1 ]]; then
  total=0
  if [[ -f "$repos_file" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r nwo; do
      [[ -z "$nwo" ]] && continue
      n=0
      if [[ -n "${HYDRA_PROMOTION_COUNT_CMD:-}" ]]; then
        # Test/override hook: run the command with the repo nwo available as
        # $1. The command's stdout is taken as that repo's count.
        n="$(bash -c "$HYDRA_PROMOTION_COUNT_CMD" _ "$nwo" 2>/dev/null || echo 0)"
      else
        n="$(gh pr list --repo "$nwo" --state open --draft \
              --label "$SKILL_LABEL" --json number \
              --jq 'length' 2>/dev/null || echo 0)"
      fi
      # Coerce to a non-negative integer; ignore garbage.
      [[ "$n" =~ ^[0-9]+$ ]] || n=0
      total=$((total + n))
    done < <(jq -r '
      .repos // []
      | map(select(.enabled != false))
      | .[]
      | "\(.owner)/\(.name)"
    ' "$repos_file" 2>/dev/null)
  fi
  printf '%d\n' "$total"
  exit 0
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

# ($today is resolved above, before the --check-due / --greeting-count modes.)

# --- Selection -------------------------------------------------------------
# Emit TSV of eligible keys: <key>\t<count>\t<tickets_csv>\t<last_cited>
# where tickets_csv is comma-separated distinct tickets.

select_eligible() {
  # The optional --only filter is applied inline in the jq pipeline below via
  # --arg only (the "if ($only | length) > 0" branch); there is no separate
  # bash-side filter string.
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
    echo "promote-citations: warning: memory file not found, no context for quote: $memfile" >&2
    return 0
  fi
  local lineno
  lineno="$(grep -nF -- "$quote" "$memfile" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [[ -z "$lineno" ]]; then
    echo "promote-citations: warning: quote not found in $memfile — skill will have empty context: \"$quote\"" >&2
    return 0
  fi
  local start=$((lineno - 2))
  local end=$((lineno + 5))
  (( start < 1 )) && start=1
  sed -n "${start},${end}p" "$memfile"
}

# Build the SKILL.md body. Uses the shape documented in .claude/skills/README.md.
# Inputs: name, description, quote, source_file, context_block, citations_block.
#
# HARDENING (#166): the template is a QUOTED heredoc (<<'TEMPLATE') so none of
# the worker-controlled inputs ($quote, $description, $context, $citations) are
# subject to shell expansion or command substitution. Values are spliced in
# afterwards via bash parameter-expansion replacement (${t//@@X@@/$v}), which
# treats the replacement as literal data — no eval, no second pass.
build_skill_body() {
  local name="$1"
  local description="$2"
  local quote="$3"
  local source_file="$4"
  local context="$5"
  local citations="$6"

  # Build the Process section (literal data, never expanded).
  local process_block
  if [[ -n "$context" ]]; then
    process_block="$(printf 'Context excerpt from the source memory entry:\n\n```\n%s\n```' "$context")"
  else
    process_block='_No extra context was found in the source memory file — edit this section to fill in the procedure._'
  fi

  # Static template with @@PLACEHOLDERS@@. Quoted heredoc → zero expansion of
  # the literal backticks and the placeholder names themselves. We read it
  # straight into the variable via `read -d ''` rather than `$(cat <<'…')` —
  # nesting a backtick-containing heredoc inside $( ) trips the bash parser.
  local template
  IFS= read -r -d '' template <<'TEMPLATE' || true
---
name: @@NAME@@
description: |
  @@DESCRIPTION@@
---

# @@NAME@@

## Overview

Promoted from `memory/@@SOURCE_FILE@@` — the operator cited this pattern 3+
times across 3+ distinct tickets, so it graduates here for every worker
to pick up automatically (Step 0 reads `.claude/skills/*`).

The load-bearing quote from memory is:

> @@QUOTE@@

## When to Use

Apply this pattern whenever the condition described below is active.
(The operator should edit this section to make the trigger explicit —
the promotion script leaves the Overview/context intact but this section
is the one that Claude's skill matcher keys on.)

## Process

@@PROCESS@@

## Citations

@@CITATIONS_START@@
@@CITATIONS@@
@@CITATIONS_END@@

## Verification

How to confirm a worker applied this skill correctly. (Edit post-merge.)
TEMPLATE

  # Literal substitution. ${var//search/replace} does NOT re-expand the
  # replacement, so command substitution inside any input is inert.
  template="${template//@@NAME@@/$name}"
  template="${template//@@DESCRIPTION@@/$description}"
  template="${template//@@SOURCE_FILE@@/$source_file}"
  template="${template//@@QUOTE@@/$quote}"
  template="${template//@@PROCESS@@/$process_block}"
  template="${template//@@CITATIONS_START@@/$CITATIONS_START}"
  template="${template//@@CITATIONS@@/$citations}"
  template="${template//@@CITATIONS_END@@/$CITATIONS_END}"

  printf '%s\n' "$template"
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
# #166: dropped the redundant `gh label list` pre-check — `gh label create`
# already 422s harmlessly when the label exists, and the call is `|| true`, so
# the pre-check was a wasted API round-trip with no behavioral effect.
ensure_label() {
  local repo_nwo="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    return 0
  fi
  gh label create "$SKILL_LABEL" \
    --repo "$repo_nwo" \
    --color "$SKILL_LABEL_COLOR" \
    --description "$SKILL_LABEL_DESC" 2>/dev/null || true
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

  # Slug = file-prefix + slugified-quote. Per the spec ("Skill naming"), the
  # QUOTE slug is capped at 60 by slugify(); the file prefix is additive and
  # disambiguates same-quote entries from different memory files. We do NOT
  # re-truncate the combined string — the prior code applied a second,
  # undocumented 80-char cap (#166 reconciliation), which could chop a slug
  # mid-word and silently collide two distinct entries.
  local file_prefix_slug quote_slug combined_slug
  file_prefix_slug="$(file_prefix "$file")"
  quote_slug="$(slugify "$quote")"
  combined_slug="${file_prefix_slug}-${quote_slug}"

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
  # HARDENING (#166): build the commit message with printf passing the
  # worker-controlled values ($quote, $combined_slug, $file, $tickets_csv) as
  # literal arguments — no heredoc expansion, so command substitution inside a
  # citation quote cannot execute.
  local msg
  msg="$(printf '%s\n\n%s\n%s\n%s\n\n%s\n%s\n' \
    "chore(skills): promote $combined_slug (cited $count times)" \
    "Source: memory/$file" \
    "Quote: \"$quote\"" \
    "Tickets: $tickets_csv" \
    "Spec: docs/specs/2026-04-17-skill-promotion-automation.md" \
    "Closes: none (automated skill promotion; operator reviews before merge)")"
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
