---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 145
tier: T2
---

# Skill promotion automation: citations ≥ 3 triggers a promotion PR

**Ticket:** [#145](https://github.com/tonychang04/hydra/issues/145)

## Problem

`CLAUDE.md` § identity and `memory/memory-lifecycle.md` both promise a learning
loop: when a memory entry hits `count >= 3` across 3+ distinct tickets,
Commander drafts a PR that lands a `.claude/skills/<slug>/SKILL.md` in the
target repo and labels it `commander-skill-promotion`. The counter ticks on
every worker report (via `scripts/parse-citations.sh` → merged into
`state/memory-citations.json`), but **no code fires the promotion**. Entries
reach the threshold and sit there forever. The learning loop is open.

Ticket #150 just landed the `.claude/skills/` bootstrap (one seed skill,
`worker-emit-memory-citations`, plus a README that documents the shape
promotion is supposed to emit). That PR closed the authoring question —
"what does a promoted skill look like?" — which was the last blocker to
shipping promotion itself. This spec wires the pipeline.

## Goals / non-goals

**Goals**

1. `scripts/promote-citations.sh` — reads `state/memory-citations.json`,
   scans for entries where `count >= 3` AND `len(unique(tickets)) >= 3`, and
   for each eligible entry drafts a `.claude/skills/<slug>/SKILL.md` plus a
   draft PR labeled `commander-skill-promotion`.
2. Idempotent on re-run. If the skill file already exists, `--mode=update`
   edits in place with a commit-amendable diff (and reuses the open PR if
   one exists) rather than clobbering. If no change is needed, exit 0
   silently.
3. Hook into the existing autopickup tick. Run **once per calendar day**
   (not every tick). Counts against the same concurrency budget as ticket
   spawns; preflight failures defer, never bypass.
4. On session start (the greeting in CLAUDE.md § "Session greeting"),
   surface a one-liner when there are unmerged skill-promotion PRs across
   configured repos: `Skill promotion: N PR(s) awaiting your review.`
5. Add a `--dry-run` mode that prints the list of eligible entries plus
   what would happen, without mutating anything, so operators and tests can
   exercise the selection logic without `gh` side effects.

**Non-goals**

- Writing the full skill body from the learning entry. Promotion drafts
  the SKILL.md scaffold and pastes in the learning + its citations; the
  operator (or a follow-up worker) tightens the prose during PR review.
  Auto-generation of a polished skill body is out of scope — the human
  review loop is load-bearing while the loop is new.
- Auto-merging skill-promotion PRs. Per `policy.md`, T2-equivalent changes
  need operator approval. Promotion PRs are `commander-skill-promotion` and
  always go to the review queue.
- Auto-deleting the memory entry on merge. The lifecycle doc says
  "removes from commander memory once merged, with a trailing note" — that
  annotation path is already described in `memory/memory-lifecycle.md` § 6
  and can be handled separately (cleanup is a post-merge follow-up; not
  blocking on it here).
- Cross-repo promotion. A citation keyed
  `learnings-InsForge.md#"..."` promotes into the `InsForge` repo, not into
  hydra. The target repo is derived from the citation key's file basename
  (learnings-`<slug>`.md → the repo whose `repos.json` entry has matching
  basename for its learnings file). Repos that are disabled in
  `state/repos.json` are skipped with a warning.
- Creating GitHub labels from scratch. Following the pattern of
  `commander-rescued`, `commander-skill-promotion` is created lazily on
  first use via `gh label create` inside the script, with a fixed color
  (the same teal as `commander-review` so it groups visually).

## Proposed approach

Shell script + jq, no new daemon. Commander invokes the script; the script
does the selection, worktree setup, skill authoring, PR creation, and
idempotence check. The autopickup tick gains a once-a-day gate that fires
the script.

**`scripts/promote-citations.sh`** — synopsis:

```
promote-citations.sh [options]

  --state-dir <path>       (default: ./state)
  --memory-dir <path>      (default: $HYDRA_EXTERNAL_MEMORY_DIR or ./memory)
  --repos-file <path>      (default: ./state/repos.json)
  --dry-run                print plan only, no gh/git side effects
  --only <key>             only consider one citation key (for tests)
  --author                 default: "hydra worker" (for commit trailer)
  --now <YYYY-MM-DD>       deterministic-tests override
  -h | --help
```

Flow per eligible citation entry:

1. **Selection.** Parse `state/memory-citations.json` with jq. An entry is
   eligible when `count >= 3` AND `(tickets | unique | length) >= 3`. This
   is the authoritative rule from `memory/memory-lifecycle.md`.
2. **Resolve target repo.** The citation key is
   `<file>#<quote>`. Split on `#`; the file part is `learnings-<slug>.md`
   (for repo-scoped entries) or one of `escalation-faq.md` /
   `memory-lifecycle.md` / `tier-edge-cases.md` / `worker-failures.md` (for
   cross-cutting entries). Repo-scoped: look up a `repos[]` entry whose
   `<owner>/<name>` basename matches `<slug>` (case-insensitive fallback;
   exact match first). Cross-cutting: skip for now — cross-repo promotion
   is a non-goal; emit a warning and continue.
3. **Skill naming.** Slugify the quote: lowercase,
   `[^a-z0-9]+` → `-`, trim leading/trailing `-`, cap at 60 chars. Prefix
   with the memory file shorthand so two entries from different files
   can't collide (`learnings-hydra.md#"rescue stale index lock"` →
   `skills/learnings-hydra-rescue-stale-index-lock/SKILL.md`).
4. **Worktree + branch.** `git -C <local_path> worktree add
   .claude/worktrees/promote-<slug> -b commander/skill-promote/<slug>`.
   Re-use an existing worktree if one already exists at that path (so
   retries don't explode). `local_path` from `state/repos.json:repos[]`.
5. **Author SKILL.md.** Read the learning entry's full text from the
   source memory file (quote + 5 surrounding lines for context —
   `grep -n` for the quote, take `[lineno-2, lineno+5]` clamped to file
   bounds). Build the SKILL.md body from a fixed template that matches
   the shape documented in `.claude/skills/README.md` § "Skill shape":
   frontmatter (name, description), Overview, When to Use, Process,
   Citations block listing the tickets that cited it, Verification hint.
6. **Idempotent update.** If the file already exists at
   `.claude/skills/<slug>/SKILL.md`, re-read it, splice the citations
   block (regenerate from current ticket list), and write back. If byte
   contents are identical, exit 0 without committing. Never overwrite the
   frontmatter `description:` — that may have been edited by the operator.
   Touch only the citations block (delimited by
   `<!-- hydra:citations-start -->` / `<!-- hydra:citations-end -->`) and
   the "Last promoted" date line.
7. **Commit.** `git add .claude/skills/<slug>/SKILL.md`,
   `git commit -m "chore(skills): promote <slug> (cited N times across M
   tickets)"` with the standard hydra trailer.
8. **Push + PR.**
   `git push -u origin commander/skill-promote/<slug>`;
   `gh pr create --draft --title "skill promotion: <quote>" --body <body>`.
   The body links: citation key, source memory file, all citing tickets,
   the learning-entry quote, and a verification hint. Label via the REST
   API (per the footgun in CLAUDE.md § labels). If a draft PR on that
   branch already exists, `gh pr view --json number` finds it; we update
   the body in place via `gh pr edit --body-file`.
9. **Return code.**
   - `0` — selection ran; zero or more PRs opened/updated. (Empty-list
     day is success.)
   - `1` — unexpected error (git/gh failure, malformed citations file).
   - `2` — usage error.

**Autopickup hook.** `state/autopickup.json` gains (back-compat, optional):

```
"last_promotion_run": "YYYY-MM-DD" | null   // added by this spec
```

In the existing tick procedure (spec
`docs/specs/2026-04-16-scheduled-autopickup.md` step 4), after the ticket
pickup loop, Commander compares `last_promotion_run` to today. If
different (or null), invoke `scripts/promote-citations.sh` once, update
the field, and move on. A single tick per day, aligned with the first
tick of the day. Quiet by default — only reports when a PR is actually
opened or updated.

**Session greeting hook.** In the greeting path (CLAUDE.md § "Session
greeting"), after the connector-status line, run
`gh pr list --search "label:commander-skill-promotion is:open is:draft"
--json number -R <owner>/<name>` across enabled repos, sum counts. If
`>0`, append `Skill promotion: N PR(s) awaiting your review.`. Silent at
N=0. This matches the connector-status pattern exactly.

**CLAUDE.md.** The "Memory hygiene" section currently has the line:

> Every 10 tickets (or on `compact memory`): merge near-duplicates,
> archive stale (30+ days, uncited last 10) → `memory/archive/`, draft
> skill-promotion PRs labeled `commander-skill-promotion`.

This spec makes that last clause operational. We append **one line**
after the existing Skill-library pointer to reference this spec — ~120
chars, well under the size budget.

### Alternatives considered

**A. A new cron job / systemd timer.** Rejected — the Hydra architecture
avoids standalone daemons (see spec
`2026-04-16-scheduled-autopickup.md` § "Proposed approach" alt A).
Autopickup is already the one scheduler; promotion piggybacks.

**B. Inline promotion into `parse-citations.sh`.** Rejected — parse is
intentionally stateless and per-report; promotion needs the aggregate
view and has side effects (worktrees, PRs). Separate scripts, separate
concerns.

**C. Python instead of bash+jq.** Rejected — every other script in
`scripts/` is bash + jq (parse-citations, validate-*,
build-memory-brief, alloc-worker-port, rescue-worker, etc.). Python
would introduce a toolchain that the rest of Hydra avoids. The citations
JSON is shallow; jq handles it fine.

**D. Auto-generate the full skill body with an LLM call.** Rejected for
v1 — the human review loop is load-bearing for the first few months of
promotions; we want the operator to have to look at every promoted
skill to catch bad selections early. A v2 can add LLM polish under an
opt-in flag once we have ground truth on what a good promoted skill
looks like.

## Test plan

Per AC #6: a fixture with 3 citations of the same entry across 3 tickets
should trigger exactly one PR proposal. Implemented as
`scripts/test-promote-citations.sh` (matches the bash test-harness
pattern of `scripts/test-check-claude-md-size.sh` — no external harness,
colored pass/fail, temp fixtures).

Concrete tests:

1. **Fixture: 3 citations across 3 tickets.** One entry in a minimal
   `memory-citations.json` with `count=3`, `tickets=["#1","#2","#3"]`,
   `promotion_threshold_reached=true`. Under `--dry-run`, expect stdout
   to list exactly that key and exactly one `would open PR` line.
2. **Fixture: 3 citations but only 2 distinct tickets.** Same count, but
   `tickets=["#1","#1","#2"]`. Under `--dry-run`, selection yields zero
   entries (dedup applied). This regression test catches the off-by-one
   between "count" and "distinct tickets" which is easy to miss.
3. **Fixture: already-promoted skill.** Pre-create
   `.claude/skills/<slug>/SKILL.md` in a fixture worktree. Run with
   `--dry-run`, expect the plan to say `would update (no byte change)`
   or `would update (citations block changed)` — never `would create`.
4. **Usage errors exit 2.** Missing `--state-dir` pointing to a missing
   file, unknown flag, multiple positional args.
5. **Session-greeting stub.** A small test fixture with a mocked `gh pr
   list --label commander-skill-promotion` JSON output, verify the
   greeting constructor prints `Skill promotion: 2 PR(s)...` for a
   count of 2 and is silent on 0. (Implemented as an inline helper
   function the greeting path calls; the test hits the helper directly
   with a mocked count.)
6. **Slug collision.** Two learning files with identical quote text
   produce different slugs (the file prefix disambiguates).
   `memory-lifecycle.md#"foo"` → `memory-lifecycle-foo/`;
   `learnings-hydra.md#"foo"` → `learnings-hydra-foo/`.

Golden path: `scripts/test-promote-citations.sh` exits 0, printing all
tests green, inside CI (and can be added to `self-test/run.sh` as a
follow-up).

## Risks / rollback

- **Risk:** Overly aggressive promotion (e.g. noise entries crossing the
  threshold). **Mitigation:** the 3-across-3 rule is the gate; draft
  PRs are never auto-merged; the operator reviews every one. If noise
  starts appearing, we raise the threshold by editing
  `memory/memory-lifecycle.md` and the selection query in one place.
- **Risk:** Wrong target repo. A citation key uses the `<slug>`
  convention, but fresh repos may have inconsistent naming.
  **Mitigation:** case-insensitive basename match; unmatched entries
  log a warning and skip (do not crash).
- **Risk:** Idempotence bug on re-run — clobbers an operator's hand-
  edited skill. **Mitigation:** only the delimited citations block is
  ever rewritten; everything outside the delimiters is read-modify-
  write with a byte-identical check. A diff that touches anything
  outside the markers is a bug.
- **Risk:** Label creation races. Two promotion ticks creating the
  label at the same time. **Mitigation:** `gh label create` 422s on
  conflict; script tolerates.
- **Rollback.** Revert the commit; `state/autopickup.json` safely
  ignores the `last_promotion_run` key; open draft PRs remain but
  nothing fires automatically anymore. Zero-risk revert.

## Implementation notes

(Fill in after the PR lands.)
