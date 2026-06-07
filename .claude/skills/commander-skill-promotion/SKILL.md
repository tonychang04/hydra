---
name: commander-skill-promotion
version: 1.0.0
description: |
  Preview and steer the memory→skill promotion pipeline before a draft PR
  appears. Use when the operator asks "what's about to be promoted?", says
  `promote learnings`, wants to see what's trending toward the 3×3 citation
  threshold, or wants to tighten a learning entry before it scaffolds a
  SKILL.md. Layers operator visibility (trending + promotion-ready cohorts)
  and control (edit the learning first) over the existing
  scripts/promote-citations.sh — it does NOT reimplement promotion. Skip if
  you just want the daily autopickup tick to file PRs unattended. (Hydra)
---

# Preview & control citation→skill promotion

## Overview

`scripts/promote-citations.sh` promotes a learning to a `.claude/skills/<slug>/SKILL.md`
when its citation entry crosses the **3×3 threshold** — `count >= 3` AND ≥3
distinct tickets (the rule in `memory/memory-lifecycle.md`). On the autopickup
tick it runs once per calendar day and opens a draft PR for each eligible entry,
**silently**. Two operator pain points follow: an entry is invisible until the
day it crosses the threshold (no "trending" view), and the auto-PR scaffolds the
SKILL.md from the raw learning text with no chance to tighten it first.

This skill is the preview/control layer: (1) see what is *about* to promote,
(2) see what is *ready*, (3) tweak the source learning before filing, (4) file
with the same script the tick uses. **Do not reimplement the selection or PR
logic** — call `promote-citations.sh`. The only extra code is a read-only jq
one-liner for the trending cohort, with no side effects.

## When to Use

- Operator says `promote learnings`, "what's about to be promoted?", "show
  promotion candidates", or "anything close to becoming a skill?".
- Before letting the daily tick file a promotion PR, when you want to inspect or
  edit the learning entry first.
- During a retro, to report the citation leaderboard's promotion edge.

Skip when:

- You want fully unattended promotion — let the autopickup tick run the script.
- You are *authoring* `MEMORY_CITED:` markers — that is `worker-emit-memory-citations`.

## Process / How-To

State lives in `state/memory-citations.json` (gitignored runtime state; the
committed reference is `state/memory-citations.example.json`). For the jq step
below, set `CIT=state/memory-citations.json` (fall back to the `.example.json`
on a fresh install).

1. **Preview the promotion-ready cohort (authoritative selector).** Never
   hand-roll the 3×3 filter — run the script in dry-run; it resolves which
   entries are eligible *and* which target repo each maps to, with no git/gh
   side effects:

   ```
   scripts/promote-citations.sh --dry-run
   ```

   Each filed-able entry prints an `ELIGIBLE` line (key, target repo, branch,
   skill path, create/update action) and a `would open PR` line. Dry-run is the
   authoritative *eligibility + target-resolution* preview — it stops before the
   real run's checkout/context steps, so it does **not** prove the eventual
   scaffold or its `local_path` checkout are producible. No `ELIGIBLE` lines
   means either nothing is at the 3×3 threshold or every at-threshold entry is
   cross-cutting / unresolvable (those log a `skip:` line on stderr, not stdout).

2. **Preview the trending cohort (the new visibility surface).** These are
   entries with ≥2 cites across ≥2 tickets that have *not yet* hit 3×3. The ones
   that will *actually* promote on crossing are the `learnings-*.md` keys with a
   resolvable target repo (the script skips cross-cutting files like
   `escalation-faq.md` / `memory-lifecycle.md`); confirm with step 1's dry-run
   once an entry crosses. Read-only jq, no side effects:

   ```
   jq -r '.citations // {} | to_entries
     | map(select((.key|startswith("_"))|not))
     | map({key:.key, c:(.value.count//0), t:((.value.tickets//[])|unique|length)})
     | map(select(.c>=2 and .t>=2 and (.c<3 or .t<3)))
     | if length==0 then "(none trending)" else (.[]|"\(.c) cites / \(.t) tickets\t\(.key)") end' \
     "$CIT"
   ```

3. **Optionally tighten the source learning before filing.** The script copies
   the cited quote + a small context window from `memory/learnings-<repo>.md`
   into the SKILL.md scaffold (see `build_skill_body`/`extract_context` in the
   script). Editing the learning entry → a better draft. Keep the cited quote
   substring intact (so `extract_context`'s `grep -nF` still finds it). Note:
   dry-run does **not** re-read the learning text, so it can't confirm your edit
   survived — verify the quote is still present yourself
   (`grep -F "<quote>" memory/learnings-<repo>.md`) before filing.

4. **File.** Run the same script *without* `--dry-run` (or wait for the daily
   tick). It authors the SKILL.md, opens a draft PR, and labels it
   `commander-skill-promotion`:

   ```
   scripts/promote-citations.sh
   ```

   The PR is a *scaffold* — per the pipeline spec, the operator tightens the
   `description:`, **When to Use**, and **Verification** sections during review;
   promotion PRs are never auto-merged.

5. **For the exact flag set**, read `scripts/promote-citations.sh --help` — it is
   the source of truth (`--state-dir`, `--memory-dir`, `--repos-file`, `--only`,
   `--now`, `--author`). Do not duplicate the flag table; it drifts.

## Examples

### Good — preview, then file

```
$ scripts/promote-citations.sh --dry-run
ELIGIBLE  key=learnings-hydra.md#rescue stale index lock  repo=org/hydra  ...  action=would create
would open PR  title=skill promotion: rescue stale index lock  label=commander-skill-promotion
$ scripts/promote-citations.sh   # looks right → file it
promote-citations: opened https://github.com/org/hydra/pull/512
```

The trending one-liner does the same for *next*: a `learnings-*.md` entry at 2
cites / 2 tickets shows up so the operator can sharpen its quote ahead of the
crossing — visibility without commitment, no PR yet. (Confirm it will actually
file by re-running step 1's dry-run once it crosses 3×3.)

### Common failures

- **Hand-rolling the 3×3 verdict in jq** duplicates the script's selector and
  *will* drift (it dedupes tickets, skips `_` meta keys, skips cross-cutting
  files, resolves the target repo). Use `--dry-run` for eligibility; reserve raw
  jq for the read-only *trending* cohort only.
- **Editing the cited quote out from under the script:** `extract_context` does
  `grep -nF` for the quote, and dry-run won't catch a broken edit (step 3) — the
  scaffold silently loses its context block. Keep the quote substring intact.

## Verification

Authored against the committed fixture `state/memory-citations.example.json`
(portable — the real `.json` is gitignored). Point a temp state dir at the
fixture so the script treats it as the live citations file:

```
tmp=$(mktemp -d); cp state/memory-citations.example.json "$tmp/memory-citations.json"
printf '{"repos":[{"owner":"acme","name":"CLI","local_path":"/tmp/x","enabled":true}]}' > "$tmp/repos.json"
scripts/promote-citations.sh --state-dir "$tmp" --repos-file "$tmp/repos.json" --dry-run --now 2026-05-20
```

Expected (promotion-ready): exactly one entry —

```
ELIGIBLE  key=learnings-CLI.md#npm install strips peer markers  repo=acme/CLI  branch=commander/skill-promote/learnings-cli-npm-install-strips-peer-markers  skill=.claude/skills/learnings-cli-npm-install-strips-peer-markers/SKILL.md  action=would create
would open PR  title=skill promotion: npm install strips peer markers  label=commander-skill-promotion
```

Now run the step-2 trending one-liner against the same fixture — set `CIT` first
(it is unbound otherwise): `CIT=state/memory-citations.example.json`, then the
step-2 jq with `"$CIT"`.

Expected: `(none trending)` — the only sub-threshold entry
(`pnpm lockfile conflicts with npm i`) is at 1 cite / 1 ticket, below the ≥2/≥2
trending bar. This confirms the one-liner runs and that trending and
promotion-ready are disjoint cohorts.

Empty-`repos.json` run logs `skip: no single target repo for 'learnings-CLI.md'`
and exits 0 — a *skip*, not a failure (cross-cutting / unmatched entries are a
v1 non-goal per the pipeline spec).

## Related

- `scripts/promote-citations.sh` — the pipeline. Source of truth for selection,
  slug, idempotence, PR creation, and the flag set. This skill only drives it.
- `docs/specs/2026-04-17-skill-promotion-automation.md` (automation) and
  `docs/specs/2026-05-20-commander-skill-promotion-skill.md` (this skill's spec).
- `memory/memory-lifecycle.md` — the authoritative 3×3 promotion threshold.
- `worker-emit-memory-citations` — the upstream skill that feeds citation counts.
