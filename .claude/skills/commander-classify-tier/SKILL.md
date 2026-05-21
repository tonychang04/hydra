---
name: commander-classify-tier
description: |
  Classify a ticket as T1/T2/T3 per policy.md BEFORE spawning a worker. Use when
  Commander picks up a ticket and must decide tier (auto-merge / review-gated /
  refuse), or when a worker re-checks tier after reading the code. Inputs: ticket
  title + body + labels + any linked file paths. Output: tier + one-sentence
  rationale + the exact policy.md clause that triggered. policy.md is the
  authoritative source of truth; this skill is its distilled, worked-example
  form, used to make the pre-spawn decision testable and consistent. (Hydra)
---

# Classify a ticket's risk tier

## Overview

Commander assigns every ticket a risk tier before spawning a worker: **T1**
(auto-merge eligible), **T2** (commander auto-merges after `worker-review`
clears the PR), or **T3** (refuse — needs a human). The rules live in
`policy.md`, which is **authoritative**. This skill does not add or change rules;
it pins the *procedure* and a fixed set of worked examples so the classification
is testable (the README golden self-test "classify a few test tickets") and
doesn't drift between spawns. When this skill and `policy.md` ever disagree,
`policy.md` wins and this skill is the bug.

The one rule that overrides everything else: **most-restrictive-wins**. Check T3
first; only fall through to T1/T2 when no T3 tripwire matches. It is always safe
to bump T1→T2 or T2→T3; never downgrade (`policy.md` §"Classification
procedure": "default to the more restrictive tier ... Never downgrade").

The output is a triple: `tier` + a one-sentence rationale + the literal
`policy.md` clause that triggered the decision. Naming the clause keeps the call
auditable and lets a reviewer confirm it against `policy.md` directly.

## When to Use

- **Pre-spawn, every ticket.** Commander runs this in the operating loop step 4
  ("Classify tier per `policy.md`") before spawning any worker.
- **Worker-side re-check after reading code.** A worker that began on a ticket
  labeled T1/T2 but finds the actual code touches auth/migration/infra must
  re-classify. See `escalation-faq.md` → "Tier escalation": STOP, return
  `QUESTION: should I reclassify as T3?`, label `commander-stuck`. This skill
  feeds that decision; it does not replace the STOP-and-ask protocol.
- **Borderline calls.** When a ticket looks T1 but brushes a T3 path or keyword,
  use the procedure below — the answer is almost always the restrictive tier.

Skip when the operator has already pinned a tier explicitly, or when a per-repo
`merge_policy` override in `state/repos.json` only changes *who merges* (it does
not change the *tier* — classify first, then apply merge policy).

## Process / How-To

Apply `policy.md` §"Classification procedure" in this exact order:

1. **Read the inputs.** Ticket title + body + labels + any file paths the body
   names or links. Path *shape* counts even if the file doesn't exist yet.
2. **Check T3 tripwires FIRST (most-restrictive-wins).** Any single match → T3.
   - Paths: `.github/workflows/**`, `.env*`, `**/secrets/**`, `**/credentials*`,
     `infra/** terraform/** kubernetes/** k8s/** helm/**`, anything matching
     `*auth* *security* *crypto* *session* *token* *password*`, migrations
     (`migrations/**`, `*.sql` schema changes), `Dockerfile`,
     `docker-compose*.yml`, non-`.github` CI config.
   - Labels: `security infra breaking-change migration urgent-prod`.
   - Body keywords: "SQL injection", "RCE", "CVE", "vulnerability",
     "production data", "customer data".
   - Behaviors: deploy/rollback/restart services; changes to roles, permissions,
     or access control; PII / GDPR / SOC2 / compliance paths.
3. **Not T3 → check T1 hard limits.** T1 qualifies only if ALL hold: it's a
   typo/doc-only/comment change, a dependency *patch* bump (`x.y.Z` only),
   a pure test addition, or dead-code removal <50 lines in one file — AND files
   changed < 10, lines changed < 100, no excluded (T3) paths.
4. **Not T1 → default T2.** Feature work, bug fixes with source changes,
   refactors, minor/major dep bumps, anything else that isn't T3.
5. **Emit the output triple.** Example shape:
   `T2 — adds a new source file + tests, no T3 paths touched (policy.md §"Tier 2" → "Feature work (new endpoints, UI changes, business logic)").`

## Examples

The three good examples are grounded in the real fixtures under
`examples/hello-hydra-demo/fixture-issues/` — each fixture's frontmatter declares
the expected tier, so these double as the verification corpus.

### Good — T1 (`01-t1-typo.md`)

Ticket: "Fix typo in README (hollo -> hello)". Body: replace a heading in
`README.md`, remove a stale note; "no code changes".
→ **`T1` — documentation-only change, no T3 paths, well under the 10-file /
100-line limits (policy.md §"Tier 1" → "Typo, grammar, doc-only changes").**

### Good — T2 (`02-t2-farewell.md`)

Ticket: "Add farewell() function matching greet() style + tests". Body: new
`src/farewell.js`, new `src/farewell.test.js`, small test-runner config tweak.
→ **`T2` — new source file plus tests (feature work), no auth/infra/migration
paths (policy.md §"Tier 2" → "Feature work (new endpoints, UI changes, business
logic)").**

### Good — T3 (`03-t3-rotate-key.md`)

Ticket: "Rotate JWT signing key in src/auth/keys.js". Path contains `auth`;
title is "Rotate ... signing key".
→ **`T3` — the file path `src/auth/keys.js` matches the `*auth*` filename
pattern; a single path match is sufficient (policy.md §"Tier 3" → "Any file
matching `*auth*`, `*security*`, `*crypto*`, ..."). Refuse: label
`commander-stuck`, comment why, spawn nothing.**

Note (per the fixture): `src/auth/keys.js` need not exist — the path *shape* in
the body trips the refusal before any filesystem work.

### Common failure — borderline T1-looking ticket that is really T3

Ticket: "Bump the timeout in CI from 5m to 10m" — body edits
`.github/workflows/ci.yml`. It *looks* like a one-line T1 patch (< 10 files,
< 100 lines, trivial diff).
→ **WRONG: T1. CORRECT: `T3` — the path `.github/workflows/**` is an excluded
path; T3 tripwires are checked first and override the T1 hard-limit math
(policy.md §"Tier 3" → `.github/workflows/**`; §"Classification procedure" →
"Check Tier 3 triggers first (most restrictive wins)").** The size of the diff
never rescues a ticket out of a T3 path. Default to the more restrictive tier.

## Verification

This repo has no test runner; the skill is verified against its own grounded
examples and against `policy.md`:

1. **Worked-example correctness.** Each of the three good examples predicts the
   same tier that the corresponding fixture's frontmatter declares:
   `grep -h '^tier:' examples/hello-hydra-demo/fixture-issues/*.md` →
   `tier: T1`, `tier: T2`, `tier: T3` — matching the three examples above.
2. **Clause existence.** Every cited clause is a real string in `policy.md`,
   e.g. `grep -F '.github/workflows/**' policy.md` and
   `grep -F 'most restrictive wins' policy.md` (the procedure paraphrases the
   header "Check Tier 3 triggers first (most restrictive wins)").
3. **No-contradiction.** The worker-side re-check defers to
   `escalation-faq.md` → "Tier escalation" (STOP + `QUESTION: should I reclassify
   as T3?`); this skill links to it rather than restating a different protocol.

## Related

- `policy.md` — authoritative tier rules. Source of truth; this skill mirrors it.
- `docs/specs/2026-04-17-skill-seed-list.md` — seed rank #2 justification.
- `docs/specs/2026-05-20-skill-commander-classify-tier.md` — this skill's spec.
- `memory/escalation-faq.md` → "Tier escalation" — worker-side re-check protocol.
- `memory/tier-edge-cases.md` — accumulated borderline cases; scan before a hard call.
- `examples/hello-hydra-demo/fixture-issues/*.md` — the T1/T2/T3 worked examples.
- `self-test/` (README "Self-test") — golden cases assert classification output.
