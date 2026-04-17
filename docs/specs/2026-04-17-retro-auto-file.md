---
status: approved
date: 2026-04-17
author: hydra commander
ticket: 142
---

# Close the retro loop: auto-file tickets from the weekly retro's `## Proposed edits`

## Problem

The weekly retro (`docs/specs/2026-04-16-retro-workflow.md`, invoked by Commander's `retro` command) writes `memory/retros/YYYY-WW.md` with a six-section template. The final section — `## Proposed edits` — is where Commander names the concrete changes it thinks should happen next week (policy tweaks, worker-prompt fixes, new memory entries, recurring-failure mitigations). The template gates this section behind a ≥5-datapoint sample-size rule.

Today those bullets rot on disk. Nothing files them. That means:

- The meta-learning loop has no output that any other part of Hydra reads.
- The operator has to manually translate retro bullets into GitHub issues — friction that loses to "I'll do it later."
- Patterns Commander notices don't become work the next iteration of Commander picks up.

Combined with the `worker-auditor` auto-filing path (spec `docs/specs/2026-04-17-worker-auditor-subagent.md`), closing this loop gives Hydra a second auto-ticketing surface that fires once a week rather than per-ticket.

## Goals

1. After a retro writes `memory/retros/YYYY-WW.md`, a single script parses `## Proposed edits` and files one GitHub issue per bullet against the appropriate repo.
2. Deterministic, shell-scripted, dry-run-testable — so the retro procedure can call it unconditionally without fear of filing duplicates on re-run.
3. Safety-railed: retro-proposed edits above T2 are surfaced to the operator instead of auto-filed. T3 is **never** auto-filed by this path.
4. Fully integrated into the existing retro flow: one new CLAUDE.md one-liner, one new step in the retro procedure, no duplication of retro logic.

## Non-goals

- **Ranking / deduping across weeks.** Each week's edits are independent. Running the auditor across multiple retros is a follow-up.
- **Auto-picking-up the retro-filed tickets.** They land in the queue like any other `commander-ready` issue; autopickup + the usual tier classifier handle them.
- **Auto-assigning tier > T2.** Safety rail stands: retro-proposed infra/auth/migration edits surface to the operator, never auto-filed.
- **Running the retro itself.** This script is invoked AFTER the retro has been written; it does not call the retro procedure.
- **Updating the retro markdown after filing.** We do not annotate bullets with their issue numbers. Filed-or-not status is derivable from GitHub by title-match; the retro file stays as the human-readable record of what Commander noticed.

## Proposed approach

### Script: `scripts/retro-file-proposed-edits.sh <week>`

Single bash entrypoint. `<week>` is the ISO-8601 week tag (`YYYY-WW`) matching the retro filename. Resolution:

1. **Load retro.** Open `memory/retros/<week>.md`. If missing → exit 1 with a clear message. (Matches the rule that retro is always written before the auto-file step runs.)
2. **Extract `## Proposed edits` section.** Between the `## Proposed edits` header and the next `^## ` (or EOF). If the section body is empty OR contains the sentinel string `no pattern above minimum sample size this week` (case-insensitive substring match) → exit 0 filing nothing. This mirrors the retro's own sample-size gate — we file only when the retro itself has a non-empty section.
3. **Split into bullets.** Each top-level `- ` (or `* `) line starts a bullet. Continuation lines (indented by two or more spaces) fold into the preceding bullet's body. Blank lines end the current bullet.
4. **For each bullet:**
   - **Classify repo.** Default target is `tonychang04/hydra` (Commander-internal). Heuristic: if the bullet text contains a repo slug matching `[owner]/[repo]` pattern, use the first match. Spec-noted future extension: allow explicit `repo:<slug>` inline tags — for now, one slug in free text is enough.
   - **Classify tier.** Default T2. Heuristic:
     - If the bullet matches any keyword in the T3 tripwire list (`auth`, `authentication`, `migration`, `secret`, `credential`, `token`, `oauth`, `crypto`, `rls`, `.github/workflows`, `sudo`, `drop table`) → tier = `T3`, **do not file**, emit a `SURFACE:` line on stdout for the retro/operator to notice.
     - Else if the bullet opens with `fix typo`, `update README`, `bump `, `doc:`, `docs:` → tier = `T1`.
     - Else → tier = `T2`.
   - **Compose title.** `[retro <week>] <first 60 chars of bullet summary>`. The "summary" is the bullet's first line with the leading `- ` stripped and whitespace collapsed. Ellipsis `…` is appended if we truncate.
   - **Idempotency check.** Query `gh issue list --repo <slug> --search "[retro <week>]" --json title,number` and skip filing if any issue title equals the composed title byte-for-byte. This is per-repo — two repos legitimately can have a bullet with the same summary text.
   - **Compose body.** Markdown:
     ```
     ## Proposed edit (from retro YYYY-WW)

     <full bullet text, including folded continuation lines>

     ## Source

     - Retro file: `memory/retros/<week>.md`
     - Section: `## Proposed edits`
     - Sample size: <data-points count parsed from retro's Stuck + Escalations sections, see "Citation evidence" below>
     - Classifier: tier <T1|T2> (auto); repo <slug> (<"default hydra" | "matched inline slug">)
     ```
   - **File.** `gh issue create --repo <slug> --assignee tonychang04 --label commander-ready --label commander-auto-filed --label commander-retro --label <tier-label> --title "<title>" --body "<body>"`. Capture the new issue URL on stdout.
   - **Apply tier label via REST POST** only if `gh issue create --label` hits a deprecated GraphQL path on the target repo (see `memory/learnings-hydra.md:42`). The `gh issue create --label` call works on plain issues per the same note, so we try it first; the REST fallback runs only when the create call's exit code is non-zero AND its stderr contains the classic-deprecation marker.
5. **Summary.** Stdout is a newline-delimited list of `FILED: <url>` / `SKIPPED: <title> (duplicate)` / `SURFACE: <tier> <title>` lines — easy for the retro procedure (or a human) to grep. Exit 0 on success, exit 1 on unrecoverable errors (retro missing, `gh` auth broken, malformed retro).

### Citation evidence (ticket AC #4)

The bullet's body includes a "Sample size" line. Parsing the retro's `## Stuck` and `## Escalations` sections for their leading numeric counts (e.g. `K workers hit commander-stuck` and `Human answered N novel questions`) gives a single integer — `K + N` — that we print as the evidence base. When the retro is newly written there's always a count in those lines; if parsing fails (malformed retro), print `"unknown"` and continue.

### CLAUDE.md change (ticket AC #5)

Add ONE line to the `## Weekly retro` section listing `docs/specs/2026-04-17-retro-auto-file.md` alongside the two existing spec pointers. The retro procedure itself is documented as a multi-step inline rendering inside `docs/specs/2026-04-16-retro-workflow.md`'s template; that spec gains an "After write" sentence listing the script invocation.

The CLAUDE.md change is kept to one line per `memory/feedback_claudemd_bloat.md` and `docs/specs/2026-04-17-claudemd-size-guard.md`. CLAUDE.md currently sits at ~16,700 of 18,000 chars; the one-line addition is ~130 chars and stays under the cap.

### Labels

Three labels applied per filed issue: `commander-ready` (autopickup trigger), `commander-auto-filed` (marks it as produced by Commander-machinery rather than a human), `commander-retro` (distinguishes retro-source from auditor-source). The tier label (`T1`/`T2`) is also applied. All four labels must exist on the target repo; the script does NOT create them (consistent with the existing convention — Commander creates labels lazily on first use when it opens the issue from the appropriate label-applying path). If `gh issue create --label <x>` fails because the label doesn't exist, the script retries with `gh label create <x> --color <default>` then re-tries the create. `T1`/`T2` labels are not created automatically; if they don't exist, the create succeeds without the tier label and the script emits a `WARN: tier label missing` note — the issue is still filed.

### Alternatives considered

- **A — Inline the filing logic inside the retro procedure in CLAUDE.md.** Rejected for the same reason the retro workflow itself lives in a spec: CLAUDE.md scope rule. We want ONE spec pointer, not a twelve-step procedure inside the routing file.
- **B — A dedicated `worker-retro-filer` subagent.** Overkill: the work is pure bash + `gh` invocations, no worktree or LLM judgment needed. A subagent would introduce a spawn cost and a review gate for what's essentially a log-to-issue transform. Keep it deterministic.
- **C — Hook the filing into the retro procedure's WRITE step so they are a single transaction.** Rejected because the filing step talks to GitHub (network, auth, rate limits) while the retro write step is pure-local. Decoupling means a flaky network doesn't abort the retro.
- **D (picked):** Standalone script callable by hand OR from the retro procedure's final step. Retro procedure calls it unconditionally; the script no-ops when there's nothing to file.

## Test plan

Tests live at `scripts/test-retro-file-proposed-edits.sh`. Style matches `scripts/test-check-claude-md-size.sh` (bash, colored output, pass/fail counter). The subject script honors a `HYDRA_GH=<cmd>` env var to override the `gh` binary; tests point it at a stub that records argv and echoes a deterministic URL.

Cases:

1. **Empty `## Proposed edits` section.** Retro fixture has the heading but only the sentinel string. Script exits 0, no `gh` calls, stdout contains no `FILED:` lines.
2. **One T2 bullet, no inline slug.** Retro fixture has a single bullet. Script issues one `gh issue create` against `tonychang04/hydra` with the expected title / labels / body. Tier = T2.
3. **One bullet matching T1 heuristic.** Bullet opens with `docs:`. Tier label applied = `T1`.
4. **One bullet matching T3 tripwire.** Bullet contains "auth". Script emits `SURFACE: T3 …` on stdout, does NOT call `gh issue create` for that bullet, exit 0.
5. **Inline repo slug.** Bullet contains `owner/repo`. Target is that slug, not hydra.
6. **Idempotency.** Pre-seed the stub `gh issue list` response with a matching title. Script emits `SKIPPED: …` and does not call `gh issue create`.
7. **Retro missing.** `memory/retros/2026-99.md` does not exist. Script exits 1 with a clear stderr.
8. **Two bullets, mixed outcomes.** One T2 fileable, one T3 surface-only. Both emitted on stdout in order; only one `gh issue create` call recorded.

Self-test integration: add a `retro-file-proposed-edits-smoke` case to `self-test/golden-cases.example.json` with `kind: script`, wrapping the test harness. This keeps the test runnable under the CI `script` filter.

## Risks / rollback

- **Risk:** A malformed retro with a partial `## Proposed edits` heading (e.g. "## Proposed Edits" case-mismatch) silently extracts an empty section and files nothing. **Mitigation:** script's heading match is case-insensitive. The retro template in `docs/specs/2026-04-16-retro-workflow.md` pins the casing, so this is belt-and-suspenders. Unit test covers the mismatch case.
- **Risk:** Bullet text contains a real `owner/repo` reference that is NOT the intended target (e.g. "`foo/bar`'s approach was better"). We'd file the issue on the wrong repo. **Mitigation:** the heuristic is simple but the operator + audit trail surface the mistake quickly — the filed issue is visible to the operator via the normal triage flow, and `commander-retro` + `commander-auto-filed` labels make it easy to find and close. The retro bullet's original text is in the issue body, so re-filing on the correct repo is one copy-paste away. A stricter form (explicit `repo:<slug>` tag) is a follow-up.
- **Risk:** `gh issue create` rate-limits mid-script if there are many bullets. **Mitigation:** realistic week has ≤3 proposed edits (sample-size gate is ≥5 data points per edit; on a slow week the section is empty). No sleep / backoff in v1. If we ever see rate-limit errors in practice, add `gh api /rate_limit` pre-check + a brief sleep.
- **Risk:** Script is called twice in the same week (e.g. retro manually re-run). Idempotency by title match prevents duplicate issue creation; the second run is a no-op from GitHub's perspective. Already in AC.
- **Rollback:** Remove the CLAUDE.md one-liner, remove the "After write" sentence from the retro spec. The script continues to exist but is never invoked — safe to leave on disk.

## Implementation notes

(to fill on PR land)
