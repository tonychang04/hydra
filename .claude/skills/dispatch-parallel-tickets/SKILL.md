---
name: dispatch-parallel-tickets
version: 1.0.0
description: |
  Consume Hydra's pre-spawn anti-drift partition — the output of
  `scripts/plan-parallel-batch.sh` (#257) — so parallel workers don't collide on
  the same files. Use when your spawn prompt's coordinate-with line references a
  serialize group or a shared file, when you're about to fan out 2+ independent
  sub-tasks yourself, or whenever you're reading a `plan-parallel-batch.sh --json`
  partition. Teaches how to decode the JSON (`parallel` / `serialize_groups` with
  `group`/`shared`/`order` / `unknown` / `footprints` / `recommendation`), what a
  serialize-group placement obligates (stay inside your footprint; a `shared`
  path is owned by the lower number in `order` until that PR lands), and how to
  turn a partition into a coordinate-with hint. Report-only helper — it
  RECOMMENDS, Commander actuates; you HONOR the partition you were spawned under.
  Adapts superpowers `dispatching-parallel-agents` to Hydra's deterministic helper
  + coordinate-with seam. (Hydra)
---

# Dispatch / consume parallel-ticket partitions

## Overview

Hydra parallelizes ticket workers by **count**, and coordination between
concurrent workers is the **coordinate-with** line in the slim spawn prompt
(`docs/specs/2026-04-17-slim-worker-prompts.md`). To make that line deterministic,
`scripts/plan-parallel-batch.sh` (#257) estimates each candidate ticket's file
footprint from its title+body and partitions a batch into a **parallel-safe** set
(disjoint footprints), **serialize groups** (overlapping footprints), and an
**unknown** list (footprint un-estimable — surfaced, never silently
parallelized). The helper is **report-only**: it RECOMMENDS, Commander actuates
(same discipline as `scripts/autopickup-tick.sh`). Your job as a worker is to
**honor** the partition you were spawned under, and — when you fan out your own
independent sub-tasks — to **produce** one. The spec
`docs/specs/2026-06-07-anti-drift-parallelism.md` and the script itself are
authoritative for the contract; on any conflict with this skill, prefer what the
script actually prints.

## When to Use

- Your spawn prompt's coordinate-with line names a serialize group, a shared
  file, or "do not touch X (owned by #N)".
- You are about to dispatch 2+ independent sub-tasks/agents that could touch the
  same paths (the superpowers `dispatching-parallel-agents` situation).
- You're handed a `plan-parallel-batch.sh --json` blob and must read it.

Skip when:
- Your ticket is a lone spawn with no coordinate-with constraint and no fan-out —
  there's no partition to honor.
- You are CURING an existing collision between two open PRs → that's
  `worker-conflict-resolver`, the curative counterpart, not this preventive read.

## Process / How-To

1. **Find the partition signal.** Either it's in your coordinate-with line, or
   you generate it: build the batch JSON `{"tickets":[{"number","title","body"}]}`
   (a subset of `gh api .../issues` — pipe `gh` output through a small `jq`) and
   run `scripts/plan-parallel-batch.sh --json` (or `--file <path>`).
2. **Decode the JSON.** Top-level keys: `parallel` (ticket numbers safe to run
   concurrently), `serialize_groups` (each `{group, shared, order}`), `unknown`
   (un-estimable footprints), `footprints` (`{"<n>":{paths,source}}` — `source` is
   `override`/`explicit-path`/`keyword`/`explicit-path+keyword`/`none`), and a
   one-line `recommendation`.
3. **If your ticket is in a `serialize_groups[].group`:** stay strictly inside
   YOUR footprint. Every path in that group's `shared` list is owned by the
   **lower ticket number in `order`** (ascending — matches the conflict-resolver's
   "lower number first" rule) until that PR lands; do not edit a `shared` path
   until your turn. If you must, STOP and emit a `QUESTION:`.
4. **If your ticket / a sub-task is in `unknown`:** the helper could NOT estimate
   the footprint (`source:"none"`). Do not assume it's safe to parallelize —
   request a coordinate-with hint, or write one by hand from what you know you'll
   touch. Surfacing the gap is the contract; guessing is not.
5. **When you fan out your own sub-tasks:** run the helper on them, then set each
   sub-agent's coordinate-with from the `recommendation` — "spawn [disjoint] in
   parallel; serialize [A -> B] (share <path>)". Disjoint → parallel; overlapping
   → serialize in `order`; `unknown` → hand-written hint. Never share state.

## Examples

### Good — read the partition, honor the serialize group

Spec's worked batch (`plan-parallel-batch.sh --json`):
`{"parallel":[301], "serialize_groups":[{"group":[302,303],
"shared":["scripts/autopickup-tick.sh"],"order":[302,303]}], "unknown":[]}`.
You are #303. Correct behavior: #301 touches a disjoint file → it runs in
parallel, no coordination needed. You (#303) are grouped with #302 sharing
`scripts/autopickup-tick.sh`; `order` is `[302,303]`, so **#302 owns the tick
script until its PR lands** — you do your non-shared work now and treat that file
as off-limits, or wait. You write your coordinate-with note: "serialize after
#302 on `scripts/autopickup-tick.sh`."

### Bad — ignore the group, reintroduce the collision

Same partition. #303's worker ignores `serialize_groups`, sees "autopickup tick"
in its ticket, and edits `scripts/autopickup-tick.sh` in parallel with #302.
Both PRs now diff the same hunk → exactly the conflict the helper PREVENTED, now
needing `worker-conflict-resolver` (or a human) to untangle, after wasted work —
the "duplicate work, and drift" failure the anti-drift gate exists to stop. One
read of `serialize_groups` + `order` avoids it.

## Verification

Confirmed offline against the current corpus:
- **Shape:** `grep -nE '^## '` → the six canonical sections in order; `name:`
  matches the directory; `version: 1.0.0`; `description` ends `(Hydra)`;
  `wc -l` ≤ ~150 — matches sibling seeds (`respond-to-review`, `author-repo-skill`).
- **Cited artifacts exist:** `test -f scripts/plan-parallel-batch.sh` and
  `test -f docs/specs/2026-06-07-anti-drift-parallelism.md` → exit 0.
- **Worked example is real:** feeding the spec's 3-ticket fixture (#301→
  `scripts/status.sh`, #302+#303→`scripts/autopickup-tick.sh`) to
  `scripts/plan-parallel-batch.sh --json` yields `parallel:[301]` + a serialize
  group `[302,303]` sharing the tick script — the JSON this skill teaches.
- **Non-duplication:** `grep -ni 'plan-parallel-batch'
  .claude/skills/*/SKILL.md` → only this skill consumes the helper;
  `worker-conflict-resolver` is the *curative* (post-conflict) side, this is the
  *preventive* (pre-spawn) read — complementary, not redundant.

## Related

- `scripts/plan-parallel-batch.sh` — the report-only helper this skill consumes
  (authoritative for the JSON contract; on conflict, trust its output).
- `docs/specs/2026-06-07-anti-drift-parallelism.md` — the contract + worked JSON;
  `docs/specs/2026-06-08-skill-dispatch-parallel-tickets.md` — this skill's spec.
- `docs/specs/2026-04-17-slim-worker-prompts.md` — the coordinate-with prompt seam
  you read/write from the partition.
- `worker-conflict-resolver.md` (agent) — the curative counterpart: it merges a
  collision *after* two PRs conflict; this skill *prevents* it pre-spawn.
- `.claude/skills/README.md` — authoritative skill shape; `using-hydra-skills` —
  the dispatcher that surfaces this skill in Step 0.
- gstack `superpowers:dispatching-parallel-agents` — the north-star source (one
  agent per independent domain, never share state); this is its Hydra-adapted,
  helper-aware Step-0 form.
