---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 141
tier: T2
---

# Memory preloading: inject top learnings + citations into every worker prompt

**Ticket:** [#141 — Memory preloading](https://github.com/tonychang04/hydra/issues/141)

## Problem

A worker today starts with an empty head. Step 0 of `.claude/agents/worker-implementation.md` tells it to read `memory/learnings-<repo>.md` and `memory/escalation-faq.md`, but the worker has to:

1. Discover which entries apply to its ticket (the learnings file grows to ~200 lines per repo).
2. Choose from ~100 Q+A pairs in `escalation-faq.md` the ones relevant to its current scope.
3. Cite back the right ones with `MEMORY_CITED:` markers.

Every worker burns ~3-5k tokens on this re-discovery on every ticket. Worse: the citation-count signal that commander already tracks in `state/memory-citations.json` never feeds back into the worker. A learning cited 10 times across 10 different tickets gets surfaced with the same weight as one written yesterday and never cited — the worker has no way to know which entries are load-bearing.

The learning loop is **open** right now. Workers emit citations → commander increments counters → counters rot in a JSON file. The counters are supposed to feed into skill promotion, but even that's downstream of the main problem: workers rediscover the same memory on every spawn.

## Goals

- New helper: `scripts/build-memory-brief.sh <repo-owner/name>` outputs a ≤ 2000 char markdown brief suitable for direct prepending into a worker prompt.
- Brief contents (in order):
  1. **Repo-scoped top learnings** — top 5 entries from `memory/learnings-<repo>.md` ranked by citation count in `state/memory-citations.json`.
  2. **Cross-repo patterns** — top 3 entries across ALL repos in the last 30 days (global signal — these are patterns that recur regardless of repo).
  3. **Scoped escalation-faq entries** — entries from `memory/escalation-faq.md` tagged with this repo OR the `global` tag.
  4. **Citation leaderboard excerpt** — most recent `memory/retros/YYYY-WW.md`, "## Citation leaderboard" section only.
- Commander's spawn path prepends the brief under a `# Memory Brief` H1 before the ticket body.
- Worker subagent definitions (`worker-implementation`, `worker-codex-implementation`, `worker-test-discovery`) updated to expect the brief at the top of the prompt and to cite from it via `MEMORY_CITED:` markers.
- Hard 2000-char cap. Overflow truncates with `[truncated — see full at memory/learnings-<repo>.md]`.
- Repo-scoped: a learning for `InsForge/sdk-js` does NOT preload on a `tonychang04/hydra` spawn. Only the top-3 cross-repo patterns are global.
- Non-breaking: empty brief on fresh repos (new repo with no learnings, no citations) is valid output — worker handles gracefully.

## Non-goals

- **Auto-generating new learnings.** Workers already do this; the brief is read-only for that pipeline.
- **Skill-promotion loop.** Separate downstream concern. The brief reads citation counts; it does not write them. When `count >= 3` across 3+ tickets, the promotion pass runs on its own schedule.
- **Modifying the citation schema.** `state/memory-citations.json` and `state/schemas/memory-citations.schema.json` stay as-is.
- **Modifying `worker-conflict-resolver` or `worker-review`.** They don't read repo memory today (different job), so preloading isn't useful. Additive for implementation/codex-impl/test-discovery only.

## Proposed approach

### Repo name → filename mapping

`<owner>/<name>` input. Filename convention for learnings: `memory/learnings-<slug>.md`, where slug is one of:

1. The basename after the slash (`tonychang04/hydra` → `hydra` → `learnings-hydra.md`).
2. If that file doesn't exist, try `<name>` with the owner prefix (`InsForge/sdk-js` → `learnings-InsForge-sdk-js.md`).
3. If neither exists, the brief is simply empty on the repo-scoped section — not an error. Fresh repos get empty briefs.

The builder probes both forms and uses the first match. Matches today's MEMORY.md index (`learnings-hydra.md`, `learnings-InsForge-sdk-js.md`, `learnings-insforge-cloud.md` all coexist).

### Citation-ranked top-5 learnings

Read `state/memory-citations.json`. Filter keys where the file-part equals `learnings-<slug>.md`. Sort descending by `count`. Take top 5. For each, extract:

- The quoted substring (`<file>#"<quote>"` format).
- The count + last-cited date (context for the worker).

Emit as a bullet list under `## Top repo learnings (by citation count)`. Each bullet quotes the exact substring from `memory/learnings-<slug>.md` — so the worker can cite it back with a `MEMORY_CITED:` marker without digging through the full file.

If no citations exist yet for this repo, skip the section entirely (no empty heading).

### Cross-repo top-3

Same `state/memory-citations.json`, but filter by `last_cited >= today - 30 days` across ALL file prefixes. Sort by `count`. Take top 3. Emit under `## Cross-repo patterns (top 3, last 30 days)`.

These are entries that recur regardless of repo — the load-bearing patterns commander sees over and over. A worker on repo X benefits from knowing a pattern landed repeatedly on repos Y and Z.

### Scoped escalation-faq entries

Parse `memory/escalation-faq.md`. The file today is a flat list of `### Q\n- **Answer:** A\n- **Source:** ticket` blocks under `## Topic` H2 sections. To support scoping, we add an optional metadata line in each entry:

```
### <question>
- **Context:** <when it comes up>
- **Answer:** <what to do>
- **Source:** <ticket>
- **Scope:** hydra  (or: global, or: InsForge sdk-js, or absent = global default)
```

`Scope:` is additive (absent = global default — back-compat with every existing entry). The builder includes entries where `Scope` matches the current repo's slug OR equals `global` OR is absent.

Emit under `## Escalation FAQ (scoped)` — up to whatever fits in the char budget. One entry per bullet: `**Q:** <q> → **A:** <one-line answer>` (truncated to ~120 chars per line so this section stays tight).

### Citation leaderboard excerpt

Find the most recent `memory/retros/YYYY-WW.md` (sort files lexicographically descending — ISO year-week). Extract the `## Citation leaderboard` section verbatim (heading + bullets until the next H2). Emit under `## Latest retro — citation leaderboard`. If no retro exists yet, skip.

### 2000-char budget

Build each section in priority order (top-5 → cross-repo → escalation-faq → retro). Running char count. If appending the next section would exceed 2000 chars, truncate the current output at 2000 - len(truncation-marker) and append `[truncated — see full at memory/learnings-<slug>.md]`. Never split a line mid-character.

Priority order matters: repo-scoped learnings are most specific to the ticket, so they go first and survive truncation even when the brief is overfull.

### Commander spawn hook

Commander's `Agent(subagent_type="worker-implementation", ...)` spawn gains a pre-step:

```bash
brief=$("$COMMANDER_ROOT/scripts/build-memory-brief.sh" "<owner>/<name>")
prompt="# Memory Brief\n${brief}\n\n---\n\n${ticket_body}"
```

Applies to `worker-implementation`, `worker-codex-implementation`, `worker-test-discovery`. Does NOT apply to `worker-review` or `worker-conflict-resolver` (they don't Step-0-read repo memory today; not their job).

### Worker subagent updates

`.claude/agents/worker-implementation.md`, `.claude/agents/worker-codex-implementation.md`, `.claude/agents/worker-test-discovery.md`: add a paragraph after the Step 0 read list, pointing out the `# Memory Brief` section:

> **Memory Brief (prepended by Commander):** if your prompt begins with a `# Memory Brief` H1, Commander has preloaded the top learnings for this repo + cross-repo patterns. Read it FIRST — cite anything you used via `MEMORY_CITED:` markers the same way you would if you'd discovered it yourself. The brief may be empty on a fresh repo; that's not an error.

Non-breaking: if the prompt lacks the header (e.g. during transition, or for subagent types that don't get preloading), the worker falls back to the existing Step 0 discovery.

### Failure modes

1. **No `state/memory-citations.json`** — builder treats it as empty. Top-5 and cross-repo sections are empty. Emits whatever escalation-faq + retro content it can find.
2. **`memory/learnings-<slug>.md` missing** — top-5 section lists citations if any exist in `memory-citations.json`, but each bullet includes a `[learning file not found]` marker. Builder does not fail.
3. **Malformed retro file** — skip the section, continue.
4. **Jq / shell errors** — builder exits non-zero; commander logs but spawns without a brief (degrades gracefully — worker still has Step 0 discovery).

### HYDRA_EXTERNAL_MEMORY_DIR support

Identical pattern to `scripts/parse-citations.sh`, `validate-learning-entry.sh`, `validate-citations.sh`: honor `--memory-dir <path>` flag; default to `$HYDRA_EXTERNAL_MEMORY_DIR` → `./memory/`. Keeps the builder forward-compatible with `docs/specs/2026-04-16-external-memory-split.md`.

## Test plan

Fixture directory: `self-test/fixtures/memory-brief/`. Contents:

- `memory/learnings-samplerepo.md` — 3 entries with known quoted substrings.
- `memory/learnings-otherrepo.md` — 2 entries (for cross-repo test).
- `memory/escalation-faq.md` — 5 entries, mix of `Scope: samplerepo`, `Scope: global`, `Scope: otherrepo`, no scope (= global).
- `memory/retros/2026-16.md` — small retro with "## Citation leaderboard" section.
- `state/memory-citations.json` — citation counts that make a deterministic top-5 and top-3 cross-repo.
- `run.sh` — drives `scripts/build-memory-brief.sh samplerepo/samplerepo`, verifies:
  - Output has `# Memory Brief` absent from stdout (that's the commander's concern — builder emits the body only).
  - Output contains `## Top repo learnings` with the top-3 learnings in the expected order (citation-count-descending).
  - Output contains `## Cross-repo patterns` with 3 entries, none of which are from samplerepo.
  - Output contains `## Escalation FAQ (scoped)` with only the `Scope: samplerepo`/`Scope: global`/no-scope entries.
  - Output contains `## Latest retro — citation leaderboard` with the fixture retro's content.
  - Total output ≤ 2000 chars (byte-length).

The test is shell + jq + `diff` against a golden brief file (`expected-brief.md`). Wired into `self-test/run.sh` as a new test case (same pattern as `memory-validator`).

## Risks / rollback

1. **Subagent prompt contract change.** Worker subagent definitions now expect `# Memory Brief` at top. Fall-through behavior (brief absent) is explicit in the worker prompt — tested by running a worker with no brief preloaded and verifying Step 0 fallback works.
2. **Token budget overrun.** 2000 chars is ~500 tokens. Add that to every worker prompt → ~500 extra tokens per spawn × N spawns/day. Real impact: trivial for subscription-capped environments. For strict token-budget deployments, HYDRA_DISABLE_MEMORY_BRIEF env var would disable preloading (not in scope for this ticket — file a follow-up if it becomes a problem).
3. **Rollback.** `git revert` the spawn-hook commit — commander falls back to pre-preloading behavior. Worker subagent updates keep the graceful fallback ("brief may be absent"), so they're forward-compatible on rollback too.
4. **Coordinates with ticket #138 (CLAUDE.md trim).** The CLAUDE.md change for this ticket is ONE LINE in the "Memory hygiene" section. Rebase order: merge #138 first, then rebase this over it to avoid conflict on the same section.

## Out of scope (explicit)

- Changing `state/memory-citations.json` schema.
- Auto-generating learnings from worker reports (already done by `scripts/parse-citations.sh`).
- Adding brief preloading to `worker-review` or `worker-conflict-resolver` (different read patterns; not their job).
- Compressing / summarizing learnings with an LLM pre-pass (if 2000 chars proves too tight, follow-up ticket).
- Self-test golden-case modification (deliberately out of scope per ticket; test lives in `self-test/fixtures/memory-brief/` as a shell fixture, not a golden-cases entry).
