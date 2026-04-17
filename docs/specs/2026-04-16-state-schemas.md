---
status: implemented
date: 2026-04-16
author: hydra worker (issue #30 follow-up)
---

# Runtime state schemas + validator (finish #30)

## Problem

PR #44 shipped the foundational layer for issue #30:

- JSON Schemas for the five runtime state files (`state/schemas/active.schema.json`, `budget-used.schema.json`, `autopickup.schema.json`, `memory-citations.schema.json`, `repos.schema.json`).
- A minimal bash+jq validator (`scripts/validate-state.sh`) that checks JSON validity + required top-level keys.

But the ticket is not yet closed because:

1. **No bulk validator.** Commander's preflight step — "validate all state files before spawning" — has no one-line command. Today it would have to loop and call `validate-state.sh` five times.
2. **No fixtures.** The self-test harness (`self-test/run.sh`) has no regression case that exercises the schemas. A bad edit to `state/schemas/active.schema.json` (e.g. renaming `workers` to `agents`) would silently break Commander at runtime, not at self-test time.
3. **No strict validation path.** The bash+jq shim only checks top-level required keys. Per-entry field types, enums (`tier` ∈ `{T1, T2, T3}`, `subagent_type`), and `pattern` regexes on timestamps are ignored. If `ajv-cli` is installed, we can opt into full Draft-07 validation; right now we don't even try.
4. **No doc cross-ref.** `CLAUDE.md`'s "State files" section lists the state files but doesn't point future Commander sessions at the validators. The Preflight step description doesn't mention them either. Without a doc pointer, the validators are dead weight.
5. **No spec.** Worker-implementation protocol requires one for any non-trivial ticket.

The original ticket explicitly said "Commander reads `active.json` at session start AND before every spawn; validates; refuses to spawn if schema broken" — item 3 of the ticket's Fix list. Without (1)–(4) above, that instruction is impossible to honor programmatically.

## Goals / non-goals

**Goals:**

1. One-shot validator `scripts/validate-state-all.sh` that runs every known state file through its schema and exits non-zero on any failure. Prints a terse summary and, on failure, the specific file(s) + rule(s) that broke.
2. Strict-validation opt-in: when `ajv-cli` is on `PATH` (or `$HYDRA_AJV_CLI` is set), `validate-state.sh` delegates to ajv for full Draft-07 validation (type checks, enums, `pattern`s, `minimum`, `additionalProperties: false` where set). Falls back to the existing bash+jq shim when ajv isn't installed — so CI and fresh clones still work without extra deps.
3. Self-test fixture pack under `self-test/fixtures/state-schemas/` — for each of the five state files, one known-good fixture + one deliberately-broken fixture (different failure mode per schema so the script-kind tests surface the strict-mode errors when ajv is present).
4. New script-kind golden case `state-schemas` in `self-test/golden-cases.example.json`. Exercises both `validate-state.sh` and `validate-state-all.sh` against the fixtures; asserts pass-on-good, fail-on-bad, and that the failure message names the offending key/rule.
5. CLAUDE.md updates: (a) "State files" section adds a line pointing at the validators with the same tone as the memory-layer tooling paragraph; (b) Preflight step 2 gets a bullet that says "run `scripts/validate-state-all.sh` — refuse to spawn on any failure".
6. `scripts/README.md` extended to cover `validate-state.sh` and `validate-state-all.sh` alongside the three memory-layer scripts already documented.

**Non-goals:**

- Do not change the schemas themselves. PR #44 shipped them; any field tweaks belong in a separate ticket.
- Do not wire auto-invocation inside Commander code. CLAUDE.md documents the rule; the Commander instance enforces it. No automated hook is needed in Phase 1.
- Do not add ajv-cli to the repo's required dependency list. It's an opt-in upgrade, not a prerequisite. Installation guidance goes in `scripts/README.md`, not `INSTALL.md`.
- Do not touch `state/*.json` (real state files) or `state/*.example.json` (operator templates). The only file types added or edited are schemas (no edits, just referenced), scripts, fixtures, docs, and the `golden-cases.example.json` case entry.
- Do not change `.github/workflows/*` — CI already calls `./self-test/run.sh --kind=script`, so the new `state-schemas` case picks up CI coverage automatically.

## Proposed approach

Five incremental pieces, each additive:

**1. Bulk validator (`scripts/validate-state-all.sh`)**

A thin iterator over the known state files. Uses the same conventions as existing `scripts/*.sh`: `#!/usr/bin/env bash`, `set -euo pipefail`, `usage()`, exit codes 0 / 1 / 2 matching the per-file script. Default target set is everything in `state/*.json` for which a matching `state/schemas/<base>.schema.json` exists. Each file is run through `scripts/validate-state.sh`; any failure marks the bulk run as failed but the script still reports every file so an operator sees all broken files at once, not just the first.

Flags: `--state-dir <dir>` override (for fixtures — the self-test uses this to point at `self-test/fixtures/state-schemas/valid/`), `--strict` to require ajv-cli (fail if ajv isn't installed — useful for CI), `-h|--help`.

**2. Strict validation via ajv-cli (opt-in)**

Extend `scripts/validate-state.sh` with one new conditional: if `ajv-cli` is on `PATH` (or `HYDRA_AJV_CLI` is set to a specific binary), prefer it over the bash+jq shim. When ajv is used, the script invokes `ajv validate -s <schema> -d <state> --strict=false` (permissive about extra keywords) and exits with ajv's status. When ajv is absent, keep today's bash+jq path verbatim. `--strict` can be passed to force the ajv path and fail if ajv is missing.

This keeps the current behavior for every existing caller and adds a strict upgrade path for anyone who installs ajv. CI's syntax job already runs `jq empty` on state/schemas/*.json so the schemas themselves remain well-formed JSON.

**3. Fixture pack (`self-test/fixtures/state-schemas/`)**

Directory layout mirrors `self-test/fixtures/memory-validator/`:

```
self-test/fixtures/state-schemas/
├── valid/                 one file per schema, all should pass
│   ├── active.json
│   ├── budget-used.json
│   ├── autopickup.json
│   ├── memory-citations.json
│   └── repos.json
└── invalid/               one file per schema, each breaks the schema in a different way
    ├── active-missing-workers.json               (missing required top-level key)
    ├── budget-used-bad-date.json                 (date doesn't match pattern)
    ├── autopickup-out-of-range-interval.json     (interval_min < 5)
    ├── memory-citations-missing-citations.json   (missing required top-level key)
    └── repos-missing-repos.json                  (missing required top-level key)
```

Each `invalid/` fixture's failure mode is chosen so the bash+jq path catches it (for the top-level `required` failures) or the ajv path catches it (for the enum/pattern/minimum violations). The self-test asserts behavior on both paths — the bash+jq-only steps assert the top-level failures; a separate optional step runs the ajv path when `ajv` is installed and asserts the richer error output.

**4. Self-test golden case (`state-schemas` in `golden-cases.example.json`)**

Script-kind case with steps:

- `bash -n` on both validator scripts.
- `scripts/validate-state.sh` passes on every `valid/` fixture.
- `scripts/validate-state.sh` fails on each `invalid/` fixture with the expected stderr substring (`missing required keys`, etc.).
- `scripts/validate-state-all.sh --state-dir self-test/fixtures/state-schemas/valid` exits 0.
- `scripts/validate-state-all.sh --state-dir self-test/fixtures/state-schemas/invalid` exits 1.
- Every schema JSON file parses with `jq`.

The case is `kind: script`, `tier: T1`, runs in the same CI pipeline as other script cases — no docker, no Claude auth, no network.

**5. CLAUDE.md edits**

Two surgical changes (both under 5 lines):

- **Preflight step 2**: append one bullet: "`scripts/validate-state-all.sh` exits 0 — refuse to spawn on any failure (schema drift means stale Commander assumptions)".
- **State files section**: append one paragraph mirroring the memory-layer "Canonical tooling" paragraph: "Before reading any state file, run `scripts/validate-state-all.sh` (or `scripts/validate-state.sh <file>` for a single file). Schemas live at `state/schemas/*.schema.json`. Both validators fall back to bash+jq when ajv-cli isn't installed; install `ajv-cli` globally (`npm i -g ajv-cli`) for full Draft-07 validation in CI and local dev."

`scripts/README.md` gets a matching table row for each new script.

### Alternatives considered

- **A: Embed full Draft-07 validation in bash.** Doable but >400 LOC of fragile string manipulation. Rejected — ajv-cli already exists, is maintained, and is a one-line install. Hard-gating on ajv would break existing contributors who don't have Node tooling handy; opt-in is strictly better.
- **B: Switch to a Python/jsonschema validator.** Adds a Python dependency to Hydra. Rejected — same reasoning as the self-test runner spec (bash + jq only, with clearly-scoped opt-in extras).
- **C (picked):** bash+jq shim as floor, ajv-cli as strict upgrade, one bulk runner, full fixture pack, golden case.
- **D: Auto-wire Commander to run the validator before every spawn via a git hook or systemd timer.** Out of scope for Phase 1 (no Commander runtime yet). CLAUDE.md is the source of truth for "when Commander reads X, it does Y" — documenting the rule there IS the wiring.

## Test plan

1. `bash -n scripts/validate-state-all.sh` — syntax.
2. `bash -n scripts/validate-state.sh` — syntax (already covered, but re-run to catch the ajv branch).
3. `jq empty self-test/fixtures/state-schemas/valid/*.json self-test/fixtures/state-schemas/invalid/*.json` — all fixtures are valid JSON (even the invalid-by-schema ones must be structurally valid JSON; it's the schema that rejects them).
4. `scripts/validate-state.sh self-test/fixtures/state-schemas/valid/active.json` → exit 0, one success line on stdout.
5. `scripts/validate-state.sh self-test/fixtures/state-schemas/invalid/active-missing-workers.json` → exit 1, stderr contains `missing required keys: workers`.
6. `scripts/validate-state-all.sh --state-dir self-test/fixtures/state-schemas/valid` → exit 0.
7. `scripts/validate-state-all.sh --state-dir self-test/fixtures/state-schemas/invalid` → exit 1, stderr names all 5 files.
8. `./self-test/run.sh --case state-schemas` exits 0 on this branch (all assertions pass).
9. If `ajv-cli` is installed: `scripts/validate-state.sh --strict self-test/fixtures/state-schemas/invalid/autopickup-out-of-range-interval.json` → exit 1 with ajv's structured error output mentioning `minimum: 5`. If ajv isn't installed: `--strict` exits 2 with a clear "ajv-cli not found" message.
10. CI passes — `syntax-check.sh` picks up the new `.sh` files for `bash -n`, the new `.json` fixtures for `jq empty`, and `./self-test/run.sh --kind=script` exercises the `state-schemas` case.

## Risks / rollback

- **Risk:** Fixture path divergence — if `state/schemas/*.schema.json` evolves in a future ticket, the fixtures here might go stale. Mitigation: the self-test case tests each schema against its paired fixture every CI run. A schema change that breaks a fixture fails CI immediately with a named file and rule.
- **Risk:** ajv-cli's error output format changes between versions. Mitigation: the golden case's strict-path step uses `expected_stderr_contains` with a stable substring (the schema field name like `interval_min`), not a literal-match full message. Any reasonable ajv-cli version still surfaces the field name.
- **Risk:** A Commander session doesn't actually run the validator despite CLAUDE.md saying to. Mitigation: the doc points at the command; when a ticket fails due to schema drift, the follow-up learning cites the validator ("run `validate-state-all.sh` in preflight, it would have caught this"). This is the standard memory-layer feedback loop.
- **Rollback:** delete `scripts/validate-state-all.sh`, `self-test/fixtures/state-schemas/`, and this spec; revert the `state-schemas` case + CLAUDE.md edits + scripts/README.md row + the ajv branch in `validate-state.sh`. No other files change. Zero dependency impact.

## Implementation notes

(Filled in after the PR lands.)

- The ajv branch in `validate-state.sh` intentionally sets `--strict=false` so ajv tolerates the schemas' `$id` and `$schema` keywords without additional config. `--spec=draft7` is explicit because ajv-cli v5 defaults to draft-2020-12.
- `validate-state-all.sh` inspects `state/schemas/*.schema.json` rather than hard-coding a file list — add a new schema, the bulk runner picks it up automatically. The golden case regenerates its fixture list the same way.
- `.github/workflows/scripts/syntax-check.sh` already scans `state/*.json`, `state/schemas/*.json`, `self-test/fixtures/**/*.sh`. The new JSON fixtures land under `self-test/fixtures/state-schemas/{valid,invalid}/*.json`, which the existing `jq empty` sweep picks up via the existing glob patterns — but the glob only covers `state/*.json`, `state/schemas/*.json`, `self-test/golden-cases.example.json`, `mcp/*.json`, `docs/specs/*.json`, `budget.json`. The fixtures under `self-test/fixtures/state-schemas/` fall outside that list, so the golden case's own `jq empty` step is the primary JSON-validity check for them. This is consistent with how memory-validator fixtures are treated.
