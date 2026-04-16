---
name: Memory lifecycle
description: How commander keeps memory from bloating — auto-compact low-signal, promote consistent learnings to repo-local skills
type: feedback
---

# Memory Lifecycle

Commander memory is short-term pattern recognition. When a pattern is **consistent** (seen often enough it's canonical), it graduates out of memory into a **repo-local skill** — so every agent working that repo gets it natively, not just commander workers.

## The two levers

| Action | When | Effect |
|---|---|---|
| **Compact** | `learnings-<repo>.md` > 200 lines OR similar entries repeat | Merge duplicates, collapse verbose examples, keep the distilled rule |
| **Archive** | Entry is 30+ days old AND not cited in the last 10 tickets in that repo | Move to `memory/archive/<repo>-YYYY-MM.md`; don't delete (historical context) |
| **Promote to skill** | An entry has been cited or repeated by **3+ workers across 3+ distinct tickets** | Draft a `.claude/skills/<name>.md` in the target repo, open a PR, then remove from commander memory once merged |

## When to run hygiene

**Automatic triggers:**
- After every **10 completed tickets** — quick scan
- After every **ticket where the worker cited an existing memory entry** — increment a citation counter for that entry
- When `ls memory/ | wc -l` exceeds 20 files — compaction pass

**Manual triggers (the operator says):**
- `compact memory` — run a full compaction pass
- `promote learnings` — scan for promotion-threshold entries and propose PRs
- `archive stale` — move old entries

## Citation tracking

Every time a worker references memory (e.g. reads `learnings-CLI.md` in Step 0 and acts on something in it), the worker's report should include:

```
MEMORY_CITED: learnings-CLI.md#"npm install strips peer markers"
```

Commander parses these from reports and maintains `state/memory-citations.json`:

```json
{
  "learnings-CLI.md#npm install strips peer markers": {
    "count": 4,
    "last_cited": "2026-04-16",
    "tickets": ["#50", "#61", "#63", "#64"],
    "promotion_threshold_reached": true
  }
}
```

When `count >= 3` AND `tickets.length >= 3 distinct`, commander flags it as **promotion-ready** on next hygiene pass.

## Promotion flow (memory → repo skill)

1. Commander identifies a promotion-ready entry
2. Opens a PR on the target repo adding `.claude/skills/<kebab-name>.md`. Format follows whatever skill convention that repo uses (check existing skills; fall back to simple frontmatter + body)
3. PR title: `docs(agent): promote commander learning about <topic> to repo skill`
4. PR body explains: "This was a recurring gotcha for AI agents working in this repo (cited in tickets X, Y, Z). Moving into the repo's skill set so every agent discovers it natively, not just commander workers."
5. Commander labels the PR `commander-skill-promotion` and adds `commander-review` (the operator reviews like any other PR)
6. Once merged, commander removes the entry from `memory/learnings-<repo>.md` with a trailing note: `→ promoted to .claude/skills/<name>.md in PR #N on YYYY-MM-DD`

## Compaction pattern (when merging near-duplicates)

Before:
```
- 2026-04-16 #50 — npm install drifts package-lock.json. Revert before commit.
- 2026-04-20 #56 — fresh npm install causes lockfile churn (peer markers). Revert.
- 2026-05-02 #64 — package-lock bumped internal version. Revert.
```

After:
```
- `npm install` in a fresh worktree frequently drifts `package-lock.json` (peer markers, internal versions). **Revert before committing** unless the ticket is explicitly about dep updates.
  - Cited: #50, #56, #64 (3 times; promotion threshold reached 2026-05-02)
```

Once a compacted entry reaches 3+ citations in this distilled form, it becomes a promotion candidate.

## What NOT to compact

- Tier-3 escalation examples — keep verbose (safety-critical)
- Ambiguous edge cases — keep full context for future judgment calls
- Anything cited in the last 7 days — too fresh to compact safely

## What NOT to promote

- the operator-specific preferences (e.g. "the operator likes tests in `tests/` not `__tests__/`") — stays in commander memory
- Cross-cutting workflow rules (e.g. "never commit package-lock drift") — stays in commander's global memory, too broad for a single repo skill
- Phase-1-only workarounds (e.g. host-env postcss pollution) — fix the root cause instead of promoting the workaround
- Anything that contradicts an existing repo skill — raise with the operator first

## Archive format

`memory/archive/learnings-<repo>-YYYY-MM.md` — same structure as the live file, but all entries dated before the archive month. Never read by workers in Step 0, only by humans spelunking history.
