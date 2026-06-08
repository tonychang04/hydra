---
status: draft
date: 2026-06-08
author: hydra worker (ticket #283)
---

# Seed skill: `dispatch-parallel-tickets` — consume `plan-parallel-batch.sh` partition output

## Problem

Hydra now has the anti-drift machinery to *prevent* parallel workers from
colliding on the same files before they spawn: `scripts/plan-parallel-batch.sh`
(ticket #257) deterministically estimates each candidate ticket's file footprint
and partitions a batch into a **parallel-safe** set (disjoint footprints), one or
more **serialize groups** (overlapping footprints, run one-at-a-time in
ticket-number order), and an **unknown** list (footprint couldn't be estimated —
surfaced, never silently parallelized). The contract and JSON shape are pinned in
`docs/specs/2026-06-07-anti-drift-parallelism.md`, and CLAUDE.md § "Operating
loop" step 5 already points Commander at the helper before a multi-ticket spawn.

But nothing teaches a **worker** how to *read and apply* that partition. The
machinery is report-only by design — it RECOMMENDS, Commander actuates — and the
actuation surface for a worker is the slim spawn prompt's **coordinate-with**
line (`docs/specs/2026-04-17-slim-worker-prompts.md`). A worker that doesn't
understand the partition vocabulary (parallel-safe vs serialize-group vs unknown,
the `shared` paths, the `order`) can't:

1. recognize when its ticket was placed in a serialize group and what that
   obligates (stay strictly inside its own footprint; the shared file is owned by
   the lower-numbered ticket in `order` until that PR lands), or
2. translate a partition into a concrete coordinate-with hint when it is itself
   doing a multi-task dispatch (e.g. a worker fanning out independent sub-tasks).

The superpowers north-star skill `dispatching-parallel-agents` teaches the
general principle ("one agent per independent domain, never share state") but is
a Main-Agent runtime skill with no knowledge of Hydra's deterministic helper,
its JSON contract, or the coordinate-with prompt seam. There is no Step-0 Hydra
skill bridging the helper's output to worker behavior.

## Goals

- Add `.claude/skills/dispatch-parallel-tickets/SKILL.md`: a Step-0 worker skill
  that teaches (a) when to request / read a pre-spawn conflict check, (b) how to
  read the `plan-parallel-batch.sh` JSON partition (`parallel` / `serialize_groups`
  with `group`/`shared`/`order` / `unknown` / `footprints` / `recommendation`),
  and (c) how to set a coordinate-with hint from it.
- Mirror the existing Hydra skill format exactly (`name`/`version`/`description`
  frontmatter, six H2 sections, ≤150 lines, `description` ends `(Hydra)`), per
  `author-repo-skill/SKILL.md` and `.claude/skills/README.md` (authoritative).
- Cite the REAL script (`scripts/plan-parallel-batch.sh`) and spec
  (`docs/specs/2026-06-07-anti-drift-parallelism.md`); ground every claim in their
  actual contract (verified by reading both).
- Make it discoverable so a worker matches and reads it in Step 0 — add ONE
  convenience-roster line to the dispatcher (`using-hydra-skills/SKILL.md`),
  exactly as the prior seed `respond-to-review` did.

## Non-goals

- Editing `CLAUDE.md`, `worker-implementation.md`, `README.md`, or
  `worker-review.md` — owned by other workers per the ticket's COORDINATE-WITH.
  CLAUDE.md already carries the Commander-side pointer to the helper (step 5); no
  worker-side wiring is needed beyond the dispatcher roster line, because the
  dispatcher's enumerate-and-match mechanism makes the skill discoverable the
  moment its directory exists.
- Re-authoring or duplicating superpowers `dispatching-parallel-agents`. We adapt
  its core principle (isolate independent domains; never share state) to Hydra's
  *deterministic helper output* + *coordinate-with prompt seam*, and name it in
  Related as the north-star source.
- Changing `plan-parallel-batch.sh`, its JSON contract, or the spawn-prompt
  format. This skill is a pure consumer/reader of an existing, frozen contract.
- Teaching Commander-side actuation (spawning, sequencing). That lives in CLAUDE.md
  § "Operating loop" and the helper's own docstring; this skill is the *worker*
  side — how a head behaves given the partition it was spawned under.

## Proposed approach

Author one hand-authored seed skill, following `author-repo-skill/SKILL.md` and
`.claude/skills/README.md`. Structure (six canonical H2 sections):

- **Overview** — the helper is report-only and partitions a batch; the worker's
  job is to *honor* the partition it was spawned under and, when fanning out its
  own sub-tasks, *produce* one. Names the authoritative sources (the spec + the
  script) and says they win on conflict.
- **When to Use** — a worker spawned with a coordinate-with hint that references a
  serialize group / shared file; a worker about to dispatch 2+ independent
  sub-tasks; reading a `plan-parallel-batch.sh --json` blob. Skip-when list.
- **Process / How-To** — numbered: (1) locate the partition signal (coordinate-with
  line, or run the helper); (2) decode the JSON fields; (3) if in a serialize
  group, stay inside your footprint and treat `shared` paths as owned by the
  lower number in `order`; (4) if unknown, request/write a coordinate-with hint
  by hand; (5) when dispatching your own sub-tasks, build the batch JSON, run the
  helper, set coordinate-with from `recommendation`.
- **Examples** — Good: read the spec's worked 3-ticket JSON (`parallel:[301]`,
  `serialize_groups:[{group:[302,303],shared:["scripts/autopickup-tick.sh"],order:[302,303]}]`)
  and state the correct behavior. Bad: a worker ignores its serialize-group
  obligation, edits the shared file in parallel, and reintroduces the exact
  collision the helper prevented.
- **Verification** — offline: shape (`grep -nE '^## '` → six sections), ceiling
  (`wc -l` ≤ ~150), the cited script + spec exist
  (`test -f scripts/plan-parallel-batch.sh docs/specs/2026-06-07-anti-drift-parallelism.md`),
  the worked JSON round-trips through the real helper (feed the spec's 3-ticket
  fixture to `plan-parallel-batch.sh --json` and assert the partition the skill
  claims), and non-duplication grep.
- **Related** — the script, the anti-drift spec, the slim-spawn-prompt spec
  (coordinate-with seam), `worker-conflict-resolver` (the curative counterpart),
  the dispatcher, and superpowers `dispatching-parallel-agents` (north star).

**Discoverability.** Hydra skills have no manifest — the directory IS the source
of truth and the dispatcher tells workers to enumerate `.claude/skills/*` and
match each `description`. The new skill is discoverable the moment its directory
exists. The dispatcher carries a *convenience* roster (explicitly marked stale);
the prior seed `respond-to-review` added one roster line there, so we mirror that
and add a single line for `dispatch-parallel-tickets`. We touch none of the four
files other workers own.

### Alternatives considered

- **Document worker-side consumption inside the anti-drift spec instead of a
  skill.** Rejected: the spec is the *contract* (frozen); behavior guidance that
  every worker reads in Step 0 belongs in a skill the dispatcher surfaces, not
  buried in a spec a worker only reads if it already knows to.
- **Edit `worker-implementation.md`'s Step-0 list to point at the skill.**
  Rejected: owned by another worker (COORDINATE-WITH). The dispatcher's
  enumerate-and-match already makes the skill discoverable; no per-agent wiring
  needed.

## Test plan

Offline, no network (matches sibling seeds' Verification sections):

- **Shape:** `grep -nE '^## ' SKILL.md` → six sections in canonical order;
  frontmatter `name:` matches the directory; `version: 1.0.0`; `description`
  ends `(Hydra)`.
- **Ceiling:** `wc -l SKILL.md` ≤ ~150.
- **Cited artifacts exist:** `test -f scripts/plan-parallel-batch.sh` and
  `test -f docs/specs/2026-06-07-anti-drift-parallelism.md` → exit 0.
- **Worked example round-trips:** pipe the spec's 3-ticket fixture (A→`scripts/status.sh`,
  B+C→`scripts/autopickup-tick.sh`) through `scripts/plan-parallel-batch.sh --json`
  and assert `parallel==[<A>]` and a serialize group of the two overlapping
  tickets sharing the tick script — proving the JSON the skill teaches is real.
- **Discoverability:** `grep -rl dispatch-parallel-tickets .claude/skills/`
  returns the new file AND the dispatcher roster line.
- **No duplication/contradiction:** `grep -ni 'plan-parallel-batch\|parallel-batch\|coordinate-with'
  .claude/skills/*/SKILL.md memory/escalation-faq.md` — link or reconcile hits.
  (Per-repo `learnings-hydra.md` lives at the Commander root, checked by
  Commander's memory hygiene, not this offline test.)

## Risks / rollback

Low risk: additive — a single new skill directory plus one convenience-roster
line in the dispatcher. No code paths change; `plan-parallel-batch.sh` and its
contract are untouched. Rollback = delete the directory and revert the one-line
roster edit. The only judgment call is editing the dispatcher's roster list; it
is explicitly a stale convenience pointer (not a load-bearing manifest), and the
ticket's Acceptance ("add to the Step-0 enumeration") calls for it — mirroring the
prior `respond-to-review` seed.
