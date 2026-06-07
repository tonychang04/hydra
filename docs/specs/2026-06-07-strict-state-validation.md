---
status: implemented
date: 2026-06-07
author: hydra worker (issue #249 / T2)
---

# Strict state validation in CI + report which validator ran

## Problem

State validation is the **first** preflight item before any worker spawn
(`CLAUDE.md` → Operating loop step 2: "`scripts/validate-state-all.sh` exits 0").
A pass there is supposed to mean "every `state/*.json` conforms to its
`state/schemas/*.schema.json`".

It does not always mean that.

During #245 a worker found that `state/repos.json` was **strict-schema-invalid**
— it carried a bare-string `merge_policy: "auto_if_review_clean"` that was not in
the string-form enum and failed the schema's `oneOf` — yet
`scripts/validate-state-all.sh` **PASSED** it.

Root cause (confirmed by reading `scripts/validate-state.sh`): the validator has
two paths.

1. **Strict path** (lines 142-158): delegates to `ajv-cli` for full JSON Schema
   Draft-07 validation — types, enums, `oneOf`, `pattern`, `minimum`,
   `additionalProperties`. Runs only when `ajv` is on `PATH`.
2. **Fallback path** (lines 160-176): a bash+jq shim that checks JSON validity +
   **required top-level keys only**. It never looks at enums or `oneOf`.

`ajv-cli` is an optional dependency. On a fresh clone, in CI, and on the
operator's host today, `ajv` is **not** installed, so the fallback path runs. The
fallback happily accepts an out-of-enum `merge_policy` because the `repos` key is
present — which is all it checks.

Two integrity gaps compound:

- **G1 — CI never runs the authoritative validator.** `.github/workflows/ci.yml`
  does not invoke state validation at all under that name; the only state-file
  coverage is the `state-schemas` self-test golden case, which runs through the
  same fallback (no ajv in CI), so CI cannot catch an enum/`oneOf` violation
  either.
- **G2 — a fallback pass is indistinguishable from a strict pass.** The bulk
  summary line is `validate-state-all: OK (N passed, M skipped)` regardless of
  which path ran. An operator (or a future Commander reading the preflight
  output) cannot tell that only the weak check ran, so a fallback pass reads as
  full confidence.

Net effect: a malformed state file sails through preflight locally and only an
ajv-equipped environment would catch it — and no such environment exists in the
loop today.

## Goals / non-goals

**Goals:**

1. **CI runs the authoritative ajv-strict validation.** A new CI job installs
   `ajv-cli` + `ajv-formats` and runs `scripts/validate-state-all.sh --strict`.
   If ajv is unavailable, `--strict` already exits 2 — CI fails loudly rather
   than silently downgrading. An out-of-enum `repos.json` FAILS in CI.
2. **Both validators report which path ran.** `validate-state.sh` already prints
   `passes strict (ajv)` vs `passes minimal` per file; `validate-state-all.sh`
   now surfaces the path in its summary line and, when the weak fallback ran,
   prints an explicit `(fallback — install ajv-cli for full Draft-07 checks)`
   warning so a fallback pass is never mistaken for a strict pass.
3. **A regression fixture proves RED→GREEN under the strict path.** Add
   `self-test/fixtures/state-schemas/invalid-strict/repos.json` with an
   out-of-enum `merge_policy`. It passes bash+jq (RED: weak path lets it
   through) and FAILS ajv-strict (GREEN: strong path rejects it). New golden-case
   steps assert both, gated on ajv presence so they pass locally without ajv and
   actually exercise the strict path in CI where ajv is installed.

**Non-goals:**

- Do **not** strengthen the bash+jq fallback to parse enums/`oneOf`. Re-deriving
  a Draft-07 engine in bash is the wrong tool; ajv is the engine. The fallback
  stays a best-effort "is it even structurally there" check for ajv-less
  environments — but it now announces that it is the weak path.
- Do **not** change any `state/schemas/*.schema.json` or `state/*.json`. #245
  already widened the `merge_policy` enum so the live file is valid. This ticket
  is about validator **strength**, not that value.
- Do **not** touch `scripts/autopickup-tick.sh`, `self-test/run.sh`,
  `state/autopickup.json`, or `state/schemas/autopickup.schema.json` — owned by
  sibling tickets #240 / #250. Adding a case to the `golden-cases.example.json`
  **data file** is in scope (it is not `run.sh`).

## Proposed approach

Three additive pieces.

### 1. `validate-state-all.sh` reports the validator path

The bulk runner already calls `validate-state.sh` per file and that script's
stdout (`✓ … passes strict (ajv) validation` / `✓ … passes minimal validation`)
flows through. The bulk **summary** is the part that loses the signal. Resolve
the active path once, up front (same ajv-detection logic the per-file script
uses), and:

- include it in the OK summary: `validate-state-all: OK (N passed, M skipped) [validator: ajv strict]` or `[validator: bash+jq fallback]`.
- when the fallback path is active, emit a one-line WARN to stderr:
  `validate-state-all: WARN — ran bash+jq fallback (enums/oneOf NOT enforced). Install ajv-cli for full Draft-07 validation.`

Detection is read-only and matches `validate-state.sh` exactly: honor
`$HYDRA_AJV_CLI` if it resolves, else `ajv` on PATH, else fallback. When
`--strict` is passed, the path is unconditionally `ajv strict` (the script
already hard-fails earlier if ajv is missing).

**Alternative considered:** parse each per-file line to infer the path. Rejected
— brittle string-scraping of a sibling script's output; direct detection is one
`command -v` and cannot drift.

### 2. CI job: `state-validation-strict`

Add a job to `.github/workflows/ci.yml`:

- `actions/checkout@v5` (matches the other jobs).
- Install jq (apt) + `ajv-cli` + `ajv-formats` (npm global; runners have Node).
- Run `scripts/validate-state-all.sh --strict` against the committed
  `state/*.example.json` templates via `--state-dir`, AND prove the strict path
  rejects the out-of-enum fixture (so the job fails RED→GREEN-style if the
  validator ever regresses).

Why validate the `*.example.json` templates rather than live `state/*.json`?
Live runtime state files are gitignored and absent in a fresh CI checkout (the
existing `state-schemas` self-test already validates via fixture dirs for this
reason). The committed `*.example.json` files are the schema-conformant
reference copies; validating them strictly in CI is the authoritative check that
the schemas + their canonical instances agree under full Draft-07.

**Alternative considered:** make `--strict` the default everywhere (drop the
fallback). Rejected — breaks fresh clones / the operator host that lack ajv;
the fallback's value is graceful degradation, and #249's ask is that the
degradation be *visible* and that CI run the strong check, not that the weak
path disappear.

### 3. Regression fixture + golden-case steps

- New fixture `invalid-strict/repos.json`: a structurally valid `repos.json`
  whose single repo entry has `merge_policy: "totally-bogus"` (not in the
  string-form enum, fails `oneOf`). Mirrors the existing `invalid-strict/`
  pattern (`active.json` with `tier: "T4"`, `autopickup.json` with
  `interval_min: 1`).
- Golden-case steps in `state-schemas`:
  - bash+jq accepts it (RED — proves the gap exists): no-ajv path exits 0.
  - ajv-strict rejects it (GREEN — proves the fix): when ajv present, exit 1
    with `failed strict (ajv)`; when absent, the step self-skips so local runs
    without ajv stay green and CI (ajv installed) exercises the real assertion.
  - `validate-state-all.sh` OK summary names the validator path.

## Test plan

- **RED→GREEN (local, no ajv):** `scripts/validate-state.sh --schema-dir
  state/schemas self-test/fixtures/state-schemas/invalid-strict/repos.json`
  exits 0 (fallback lets the bad enum through — the documented gap).
- **RED→GREEN (with ajv, == CI):** same command with `ajv` installed exits 1 and
  prints `failed strict (ajv)`. Verified by installing ajv-cli in the worktree
  before pushing.
- **Validator reporting:** `scripts/validate-state-all.sh --state-dir
  self-test/fixtures/state-schemas/valid` prints `[validator: bash+jq fallback]`
  + the WARN line (no ajv) / `[validator: ajv strict]` (ajv present); current
  committed state still OK.
- **Self-test:** `./self-test/run.sh --kind=script` green (new steps included).
- **CI well-formedness:** `scripts/preflight-syntax.sh` green (bash -n + jq +
  frontmatter); `ci.yml` parses as valid YAML.

## Risks / rollback

- **Risk:** ajv-cli install flakiness in CI (npm registry hiccup) turns a
  validation job red on infra, not code. *Mitigation:* the job is independent
  (its own runner, no `needs:`), so a flake doesn't block other jobs; re-run
  clears it. Acceptable — the whole point is that the authoritative check runs.
- **Risk:** ajv-cli v5 defaults to draft-2020-12. *Mitigation:* the validators
  already pass `--spec=draft7 --strict=false`; no change needed.
- **Rollback:** all changes are additive (one CI job, one fixture, summary-line
  text, golden-case steps). Revert the PR; preflight returns to its prior
  fallback-only behavior. No schema or state-file changes to unwind.
