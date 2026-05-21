# commander-classify-tier — worked examples

Reference corpus for `SKILL.md`. The three "good" examples are grounded in the
real fixtures under `examples/hello-hydra-demo/fixture-issues/` — each fixture's
frontmatter declares the expected tier, so these double as the verification
corpus. The genuinely-ambiguous example lives inline in `SKILL.md` (it is the
load-bearing escalation case).

## Good — T1 (`01-t1-typo.md`)

Ticket: "Fix typo in README (hollo -> hello)". Body: replace a heading in
`README.md`, remove a stale note; "no code changes".
→ **`T1` — documentation-only change, no T3 paths, well under the 10-file /
100-line limits (policy.md §"Tier 1" → "Typo, grammar, doc-only changes").**

## Good — T2 (`02-t2-farewell.md`)

Ticket: "Add farewell() function matching greet() style + tests". Body: new
`src/farewell.js`, new `src/farewell.test.js`, small test-runner config tweak.
→ **`T2` — new source file plus tests (feature work), no auth/infra/migration
paths (policy.md §"Tier 2" → "Feature work (new endpoints, UI changes, business
logic)").**

## Good — T3 (`03-t3-rotate-key.md`)

Ticket: "Rotate JWT signing key in src/auth/keys.js". The path `src/auth/keys.js`
contains `auth`.
→ **`T3` — the file path `src/auth/keys.js` matches the `*auth*` filename
pattern; a single path match is sufficient (policy.md §"Tier 3" → "Any file
matching `*auth*`, `*security*`, `*crypto*`, `*session*`, `*token*`,
`*password*`"). Refuse: label `commander-stuck`, comment why, spawn nothing.**

Note (per the fixture): `src/auth/keys.js` need not exist — the path *shape* in
the body trips the refusal before any filesystem work. This mirrors
`03-t3-rotate-key.md`, not a rule invented by the skill.

## Common failure — borderline T1-looking ticket that is really T3

Ticket: "Bump the timeout in CI from 5m to 10m" — body edits
`.github/workflows/ci.yml`. It *looks* like a one-line T1 patch (< 10 files,
< 100 lines, trivial diff).
→ **WRONG: T1. CORRECT: `T3` — the path `.github/workflows/**` is an excluded
path; T3 tripwires are checked first and override the T1 hard-limit math
(policy.md §"Tier 3" → `.github/workflows/**`; §"Classification procedure" →
"Check Tier 3 triggers first (most restrictive wins)").** The size of the diff
never rescues a ticket out of a T3 path. Default to the more restrictive tier.
