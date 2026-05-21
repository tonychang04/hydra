---
status: proposed
date: 2026-05-20
author: hydra worker
ticket: 157
tier: T2
---

# Seed skill: `commander-classify-tier`

**Ticket:** [#157](https://github.com/tonychang04/hydra/issues/157)
**Implements seed rank #2** from `docs/specs/2026-04-17-skill-seed-list.md` (row #2 of the Proposed seed list).

## Problem

Commander classifies every ticket T1/T2/T3 *before* spawning a worker, today by
reading `policy.md` inline on every spawn. That re-derivation is invisible,
untestable, and drifts: there's no single artifact a self-test golden case
(README "classify a few test tickets") can assert against, and no fixed
worked-example set to pin the rules to. The seed-list spec ranks codifying this
logic #2 of 7 because it "unlocks faster Commander spawn decisions — reviewing
this before other seeds lets Commander classify follow-up tickets themselves
more accurately."

`policy.md` is authoritative and stays so. The skill is a distilled,
example-driven *companion* to it — it does not introduce new rules, override
`policy.md`, or fork the source of truth.

## Goals

- Author `.claude/skills/commander-classify-tier/SKILL.md` teaching tier
  classification from `{title, body, labels}` → `{tier, one-sentence rationale,
  triggering policy.md clause}`.
- Follow the existing seed shape exactly (frontmatter + Overview / When to Use /
  Process-How-To / Examples / Verification), copied from the only existing
  hand-authored seed `worker-emit-memory-citations` and `.claude/skills/README.md`.
- OMIT the gstack telemetry preamble (README says Hydra deliberately omits it).
- Keep `SKILL.md` under ~150 lines.
- Worked examples: a clear T1, a T2, and a T3 ticket body → expected
  classification + triggering clause. Plus a "common failure" borderline case
  where the skill's rule forces the more-restrictive (correct) tier.
- Ground the worked examples in REAL repo artifacts (the three
  `examples/hello-hydra-demo/fixture-issues/*.md` fixtures), not invented tickets —
  per the repo learning "specs cite real file:line not RFCs alone".

## Non-goals

- NOT changing `policy.md`. The skill must mirror it, never extend it. If the
  two ever disagree, `policy.md` wins and the skill is the bug.
- NOT adding a CLAUDE.md pointer (acceptance criterion #5: discovery is via the
  `.claude/skills/*` Step-0 read, not a routing-table line).
- NOT touching the sibling seed `classify-pr-for-review` (#159, concurrent worker).
- NOT building a runnable classifier script — this seed is a reference procedure
  read as context, exactly like `worker-emit-memory-citations`.

## Proposed approach

A single `SKILL.md` under `.claude/skills/commander-classify-tier/`.

Structure mirrors the existing seed:

1. **Overview** — what the skill teaches; the "most-restrictive-wins" core rule;
   that `policy.md` is the source of truth and the skill is its distilled form.
2. **When to Use** — pre-spawn classification; the worker-side re-check after
   reading code (cross-links the `escalation-faq.md` "Tier escalation" entries
   so the skill reinforces, not contradicts, them).
3. **Process / How-To** — the exact ordered procedure from `policy.md`'s
   "Classification procedure" section: (1) read body+labels+linked paths,
   (2) check T3 tripwires FIRST (most-restrictive-wins), (3) else check T1 hard
   limits, (4) else default T2. Names the output triple format.
4. **Examples** — three good worked examples grounded in the demo fixtures
   (T1 typo, T2 farewell feature, T3 JWT key rotation), each with the exact
   triggering `policy.md` clause; plus a borderline "common failure" example
   (a config tweak that *looks* T1 but touches a T3 path) showing the rule
   forcing the restrictive tier.
5. **Verification** — how correctness was confirmed: each worked example's
   output matches the tier declared in the corresponding fixture's frontmatter
   AND the rationale cites a real clause that exists in `policy.md`. This is the
   objective check (analogous to the parser round-trip in
   `worker-emit-memory-citations`).
6. **Related** — `policy.md`, the seed-list spec, `escalation-faq.md` tier
   section, `tier-edge-cases.md`, the demo fixtures, self-test harness.

### Alternatives considered

- **Inline the full `policy.md` rules verbatim in the skill.** Rejected:
  duplicates the source of truth, guaranteeing drift the moment `policy.md`
  changes. The skill instead references clauses by name and teaches the
  *procedure* + worked examples, pointing at `policy.md` for the authoritative
  table.
- **A runnable bash classifier + tests.** Rejected: out of scope for a seed
  reference skill; the seed-list spec explicitly frames these as read-as-context
  procedures, and a heuristic classifier on free-text ticket bodies would be
  brittle and a maintenance burden. The skill teaches a human/agent procedure.

## Test plan

There is no automated tier-classifier golden case yet (`self-test/run.sh` exists
but covers other rungs); skills are markdown docs validated against a documented
shape. Verification is:

1. **Shape check** — `SKILL.md` has the frontmatter + the five canonical sections
   in the README/seed order; no telemetry preamble.
2. **Size check** — `wc -l SKILL.md` < ~150.
3. **Worked-example correctness** — for each of the three demo-fixture examples,
   the skill's predicted tier equals the `tier:` in that fixture's frontmatter,
   and the cited clause is a string that actually appears in `policy.md`
   (grep-verifiable).
4. **No-contradiction check** — grep `memory/learnings-hydra.md` and
   `memory/escalation-faq.md`; reconcile/link any overlapping content (the
   `escalation-faq.md` "Tier escalation" entries are the worker-side re-check —
   complementary, linked, not contradicted).

## Risks / rollback

- **Drift from `policy.md`.** Mitigation: skill defers to `policy.md` as
  authoritative in its Overview and references clauses by name rather than
  re-stating the full table; a `policy.md` change only needs the skill's examples
  re-checked, not the rules re-copied. Rollback: delete the skill directory; no
  other file depends on it (no CLAUDE.md pointer per acceptance #5).
- **Merge conflict with concurrent seeds (#159).** Mitigation: only create the
  `commander-classify-tier/` directory; if appending to `.claude/skills/README.md`
  seed list, append a single line (avoid rewrites).
- Low blast radius overall: a reference doc, no executable surface.
