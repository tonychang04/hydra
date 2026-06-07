---
status: proposed
date: 2026-06-07
author: hydra worker
ticket: 245
tier: T2
---

# merge-policy-lookup: recognize bare-string `auto_if_review_clean`

**Ticket:** [#245 — merge-policy-lookup.sh rejects repo's own 'auto_if_review_clean' policy](https://github.com/tonychang04/hydra/issues/245)

**Builds on:** `docs/specs/2026-04-17-per-repo-merge-policy.md` (ticket #20, original policy enum + lookup), `docs/specs/2026-04-17-merge-queue.md` (ticket #154, `--queue` mode).

## Problem

`scripts/merge-policy-lookup.sh` is the single source of truth Commander consults before every `merge #N` (a hard safety rule in CLAUDE.md: "run merge-policy-lookup and obey"). When it cannot resolve a repo's own configured policy, Commander is **blocked from auto-merging** even legitimately review-clean self-fix PRs.

The live `state/repos.json` sets the hydra self-entry (and `tonychang04/pg_agent_audit`) to the **bare string** `merge_policy: "auto_if_review_clean"` (operator, 2026-05-24). The lookup rejects it:

```
$ scripts/merge-policy-lookup.sh tonychang04/hydra T2
merge-policy-lookup: unknown legacy merge_policy 'auto_if_review_clean' for tonychang04/hydra
```

### Root cause (three-way enum drift)

`auto_if_review_clean` is a recognized **directive** — the script's docstring lists it as a valid stdout value, `emit()` queue-prefixes it, and the schema's **object form** allows it as a per-tier value. But two places never learned the bare-string spelling:

1. **The script's legacy-string `case` block** only matches `auto-t1 | human-all | refuse-all`. A bare `auto_if_review_clean` falls to the `*)` arm → "unknown legacy merge_policy" error (exit 1).
2. **The schema's string-form `enum`** (`repos.schema.json`) only lists `["auto-t1", "human-all", "refuse-all"]`. The live file's bare `"auto_if_review_clean"` is therefore *also* schema-invalid under strict (ajv) validation — silent drift the bash/jq minimal validator never caught.

So the operator wrote a value that is a valid *directive* but not a valid *string-form policy*. The fix reconciles the bare-string surface with the directive set the rest of the system already speaks.

## Goals

- The lookup recognizes the bare-string **directive** forms `auto`, `auto_if_review_clean`, and `human` as a uniform "applies to all non-T3 tiers" shorthand, returning that directive verbatim (T3 stays hardcoded `never`).
- `scripts/merge-policy-lookup.sh tonychang04/hydra T2` returns a recognized directive against the live repos.json, exit 0.
- The schema's string-form enum accepts the new bare-string directives alongside the legacy `auto-t1 | human-all | refuse-all` triplet, so strict validation passes the live file.
- A test asserts **every** `merge_policy` value present in `state/repos.json` resolves without an "unknown" error, plus T3 → `never` is preserved (drift guard).
- The `auto_if_review_clean` directive's *meaning* is documented so Commander can obey it programmatically.

## Non-goals

- **T3 override.** Unchanged — T3 is hardcoded `never` regardless of any policy value. Hard safety rail preserved.
- **Per-tier bare strings.** The bare-string form is deliberately a single directive applied to T1 and T2 alike (back-compat with how the operator uses it). Per-tier granularity already has the object form.
- **Weakening any gate.** This only teaches the lookup to *recognize* a value it already documents; it does not auto-merge anything. Whether Commander acts on `auto_if_review_clean` is governed by the semantics below, which strictly ADD preconditions on top of "review clean".
- **Changing `emit()` / `--queue` behavior.** The queue prefix already handles `auto_if_review_clean`; no change there.

## `auto_if_review_clean` semantics (the contract Commander obeys)

When the lookup returns `auto_if_review_clean`, Commander MAY auto-merge **only if ALL** of:

1. `worker-review` returned **zero blockers** (the review gate passed clean), AND
2. **CI is green** on the PR head, AND
3. The diff does **NOT** touch safety rails — specifically any of:
   - merge-policy resolution (`scripts/merge-policy-lookup.sh`, `state/repos.json` merge_policy, `state/schemas/repos.schema.json`),
   - secrets / `.env*` / `secrets/`,
   - hard rails in `CLAUDE.md` ("Safety rules (hard)"),
   - the review-gate security coverage itself.

If **any** condition fails, Commander surfaces the PR for human merge instead. This is strictly more conservative than `auto`: `auto` needs only CI green; `auto_if_review_clean` additionally needs a clean review AND a safety-rail-free diff.

This semantic is encoded so it's machine-checkable: the lookup's stdout directive is the *gate name*, and this spec is the authoritative definition of that gate's preconditions. (The diff-touches-safety-rails check is Commander-side, mirroring the existing autopickup-tick `surface-for-human` classification — see `docs/specs/2026-05-24-self-driving-autopickup-tick.md`. This ticket does not implement that classifier; it defines the directive the classifier consumes.)

## Proposed approach

### Script (`scripts/merge-policy-lookup.sh`)

Extend the legacy-string `case` (the `string` arm of `mp_type`) to also accept the directive spellings as bare strings that apply to all non-T3 tiers:

```sh
auto|auto_if_review_clean|human)
  # Bare directive string: applies uniformly to T1/T2 (T3 handled above).
  # Operator shorthand for "this whole repo merges this way". Ticket #245.
  emit "$legacy" "$mq_enabled"; exit 0
  ;;
```

placed before the legacy triplet. `never` is intentionally NOT accepted as a bare directive — the bare-string "refuse everything" spelling is the existing `refuse-all`; adding a second alias for the same behavior would be needless surface. (The object form's `T3: "never"` is separate and untouched.)

### Schema (`state/schemas/repos.schema.json`)

Add the three directive spellings to the string-form `enum`:

```json
{ "type": "string", "enum": ["auto", "auto_if_review_clean", "human", "auto-t1", "human-all", "refuse-all"] }
```

and update the field `description` to note the bare-directive shorthand. Object form is untouched.

### Test (`self-test/fixtures/merge-policy/run.sh`)

Extend the existing fixture driver (already runnable, already covers legacy + object + queue). Add:

- A new fixture `repos-bare-directive.json` whose repos carry each bare directive (`auto`, `auto_if_review_clean`, `human`) plus a T3-on-bare-directive case.
- Cases asserting each bare directive resolves to itself for T1 and T2, and to `never` for T3.
- A **drift-guard** case: iterate every `merge_policy` value present in the live `state/repos.json` (if present) and assert each resolves with exit 0 (no "unknown" error). When the live file is absent (CI / fresh worktree), fall back to `state/repos.example.json`. This is the regression net the ticket asks for.

### Considered alternatives

- **Only fix the schema, not the script** — rejected: the script is what Commander runs; the error is in the script. Schema-only leaves the bug live.
- **Map bare `auto_if_review_clean` to the object form `{T1, T2}`** — rejected as over-engineering: the bare string already means "uniform across tiers"; passing it through verbatim is simpler and matches the `human-all` precedent.
- **Add `never` as a bare directive too** — rejected (YAGNI): `refuse-all` already covers it; no live file uses bare `never` at top level.

## Test plan

1. `bash self-test/fixtures/merge-policy/run.sh` — new + existing cases green (run RED first: confirm new cases fail before the script fix).
2. `bash -n scripts/merge-policy-lookup.sh` — syntax.
3. `scripts/merge-policy-lookup.sh tonychang04/hydra T2 --repos-file <live repos.json>` → `auto_if_review_clean`, exit 0.
4. `scripts/merge-policy-lookup.sh tonychang04/hydra T3 ...` → `never` (rail preserved).
5. `scripts/validate-state-all.sh` — schema + size gate clean.
6. `.github/workflows/scripts/syntax-check.sh` — full CI lint (incl. this spec's frontmatter).

## Risks / rollback

- **Risk:** widening the string enum could let a typo (`auto_if_reivew_clean`) pass the bare-string path. Mitigation: the typo does NOT match any enum value, so it still hits the `*)` "unknown" arm and errors loudly — the gate fails safe (no merge).
- **Risk:** a future reader assumes bare `auto_if_review_clean` is per-tier. Mitigation: docstring + this spec state it's uniform-across-non-T3.
- **Rollback:** revert the PR. Additive only — the legacy triplet and object form are untouched, so any existing repos.json keeps resolving exactly as before.
