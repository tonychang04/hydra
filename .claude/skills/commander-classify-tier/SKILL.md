---
name: commander-classify-tier
version: 1.0.0
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
`policy.md`, which is **authoritative**. This skill adds no rules; it pins the
*procedure* + worked examples so classification is testable (makes README
"Rung 1 — smoke test" repeatable) and doesn't drift. When this skill and
`policy.md` disagree, `policy.md` wins and this skill is the bug.

`policy.md` carries **two distinct rules** for hard calls — keep them separate:

1. **Most-restrictive-wins** (resolves *adjacent-tier uncertainty within a
   confident call*). Check T3 first; fall through to T1/T2 only when no T3
   tripwire matches. When uncertain between adjacent tiers, pick the higher one
   — always safe to bump T1→T2 or T2→T3, never downgrade (`policy.md`
   §"Classification procedure" → "default to the more restrictive tier" / "It is
   always safe to bump T1→T2 or T2→T3. Never downgrade.").
2. **Ambiguous → ask the operator** (resolves *true ambiguity you cannot resolve
   yourself*). If you genuinely can't tell which rule applies even after rule 1
   — and bumping restrictively would itself be a guess — stop and escalate, don't
   silently default (`policy.md` opening directive: "If classification is
   ambiguous, ask the operator."). Agent-only mode → return a `QUESTION:` block;
   with a live operator, ask directly. Defaulting restrictively is **never** a
   substitute for asking when you can't classify.

The output is a triple: `tier` + a one-sentence rationale + the literal
`policy.md` clause that triggered. Naming the clause keeps the call auditable.

## When to Use

- **Pre-spawn, every ticket.** Commander runs this in the operating loop step 4
  ("Classify tier per `policy.md`") before spawning any worker.
- **Worker-side re-check after reading code.** Per `policy.md` §"Worker-side
  enforcement" (authoritative): if the description suggested T1 but the code
  touches auth/migration/infra, the "worker stops immediately, labels
  `commander-stuck`, and comments \"escalated to Tier 3 after reading code\"."
  `escalation-faq.md` → "Tier escalation" adds the agent-mode detail (return
  `QUESTION: should I reclassify as T3?`); it does not override the policy step.
- **Borderline calls.** A ticket that looks T1 but brushes a T3 path/keyword:
  use the procedure below — the answer is almost always the restrictive tier.
- **Genuinely ambiguous tickets.** When you *cannot* tell which rule applies
  (too little detail to know whether a T3 path is touched; candidates straddle
  the refuse line), step 5's ambiguity gate routes to **ask the operator** —
  distinct from the restrictive-default (see Overview rule 2).

Note: a per-repo `merge_policy` override in `state/repos.json` changes *who
merges*, not the *tier* — classify per `policy.md` first, then apply merge
policy. No "skip classification" case (`policy.md`: "Classify every ticket
BEFORE spawning a worker").

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
   - Body keywords: "SQL injection", "RCE", "CVE", "vulnerability", "production
     data", "customer data".
   - Behaviors: deploy/rollback/restart services; changes to roles/permissions/
     access control; PII / GDPR / SOC2 / compliance paths.
3. **Not T3 → check T1 hard limits.** T1 qualifies only if ALL hold: it's a
   typo/doc-only/comment change, a dependency *patch* bump (`x.y.Z` only),
   a pure test addition, or dead-code removal <50 lines in one file — AND files
   changed < 10, lines changed < 100, no excluded (T3) paths.
4. **Not T1 → default T2.** Feature work, bug fixes with source changes,
   refactors, minor/major dep bumps, anything else that isn't T3.
5. **Ambiguity gate (before emitting).** If after steps 2–4 you still can't land
   a confident tier — the ticket is genuinely ambiguous (body too thin to tell
   whether a T3 path is touched, or bumping restrictively would itself be a
   guess) — **do not emit a guessed tier. Ask the operator** (`policy.md` opening
   directive: "If classification is ambiguous, ask the operator."). Agent-only
   mode → return `QUESTION: ambiguous tier — T<x> or T<y>?` plus the two candidate
   clauses and the missing fact. This is the Overview rule 2 path, distinct from
   the step-4 restrictive-default. Proceed to step 6 only once you have a
   confident tier (or the operator's answer).
6. **Emit the output triple.** Example shape:
   `T2 — adds a new source file + tests, no T3 paths touched (policy.md §"Tier 2" → "Feature work (new endpoints, UI changes, business logic)").`

## Examples

Four worked examples grounded in real repo fixtures live in `examples.md`
(sibling file, per the README ~150-line split convention): a clean **T1** typo
(`01-t1-typo.md`), a **T2** feature (`02-t2-farewell.md`), a **T3** auth-path
refusal (`03-t3-rotate-key.md`), and a **common failure** (a CI tweak that looks
T1 but is T3). Each cites the exact triggering `policy.md` clause and matches its
fixture's declared tier.

The fifth — the genuinely-ambiguous escalation case — stays inline because it is
the load-bearing safety branch (Overview rule 2 / Process step 5):

### Ambiguous → ask the operator (don't guess)

Ticket: "Fix the login flow — it's broken." No body, labels, file paths, or
linked code. "Login" *might* touch an `*auth*`/`*session*` file (→ T3 refuse,
don't spawn) or be a cosmetic dashboard tweak (→ T2, spawn) — you can't tell
which. The candidates **straddle the refuse line**, so this is not adjacent-tier
uncertainty that restrictive-default resolves: guessing wrong is unsafe either
way (refusing real work, or spawning into auth code).
→ **`ASK` — genuinely ambiguous; inputs can't distinguish T2 from a T3
auth/session path, and defaulting to T3 would wrongly refuse a possibly-trivial
fix. Escalate, don't guess (policy.md opening directive: "If classification is
ambiguous, ask the operator").** Emit:
`QUESTION: ambiguous tier — T3 if "login" touches an *auth*/*session* file (policy.md §"Tier 3"), T2 if dashboard-only (policy.md §"Tier 2"). Which files does this touch?`
Resolve the tier only after the operator answers; do not spawn on a guess.

## Verification

There is no automated tier-classifier golden case in `self-test/` yet (the
`self-test/run.sh` harness exists but covers other rungs), so the skill is
verified against its own grounded examples and against `policy.md`:

1. **Worked-example correctness.** Each good example in `examples.md` predicts
   the tier its fixture declares:
   `grep -h '^tier:' examples/hello-hydra-demo/fixture-issues/*.md` →
   `tier: T1`, `tier: T2`, `tier: T3`.
2. **Clause existence (verbatim).** Every quoted clause is an exact substring of
   `policy.md` — no ellipsis or paraphrase inside the quote marks. Spot-check:
   `grep -F 'default to the more restrictive tier' policy.md` and
   `grep -F 'Any file matching `*auth*`' policy.md` both return a line.
3. **No-contradiction with policy.md.** Both `policy.md` rules are carried
   separately: the most-restrictive-default (§"Classification procedure") AND the
   ask-on-ambiguity directive ("If classification is ambiguous, ask the
   operator"). The worker-side re-check cites §"Worker-side enforcement" as
   authoritative, with `escalation-faq.md` → "Tier escalation" layered on top,
   not competing. The skill's only inference beyond literal `policy.md` text —
   "a T3 path's *shape* trips the refusal even if the file is absent" — is not
   invented but mirrors the repo's own T3 fixture (`03-t3-rotate-key.md`:
   `src/auth/keys.js` "doesn't actually exist … it's the **path shape** that
   trips the refusal"). Every other line maps to a literal clause.

## Related

- `policy.md` — authoritative tier rules. Source of truth; this skill mirrors it.
- `docs/specs/2026-04-17-skill-seed-list.md` — seed rank #2 justification.
- `docs/specs/2026-05-20-skill-commander-classify-tier.md` — this skill's spec.
- `memory/escalation-faq.md` → "Tier escalation" — worker-side re-check protocol.
- `memory/tier-edge-cases.md` — accumulated borderline cases; scan before a hard call.
- `examples.md` (sibling) — the four T1/T2/T3/common-failure worked examples.
- `examples/hello-hydra-demo/fixture-issues/*.md` — fixtures the examples are grounded in.
- README "Rung 1 — smoke test" ("classify a few test tickets") — the manual
  check this skill makes repeatable (no automated golden case in `self-test/` yet).
