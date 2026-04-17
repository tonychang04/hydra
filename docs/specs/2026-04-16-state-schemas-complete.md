---
status: implemented
date: 2026-04-16
author: hydra worker (ticket #30 follow-up)
---

# State schemas — complete validator layer

## Problem

Ticket #30 observed that `state/active.json` (and friends) carry no schema contract. Workers append worker entries at runtime by following CLAUDE.md prose; a single bad commander-prompt change could silently drift the shape and break later workers that try to parse what they find there.

PR #44 landed the first half of the fix: five JSON Schema files under `state/schemas/` plus a minimal `scripts/validate-state.sh` that checks JSON validity and required top-level keys. The rest — fixtures, a walk-every-state-file runner, a self-test case, and the `hydra doctor` integration — was on a follow-up.

This spec closes that follow-up.

## Goals / non-goals

**Goals:**
- `scripts/validate-state-all.sh` walks every runtime `state/*.json`, pairs each with its schema in `state/schemas/`, and reports per-file pass/fail plus a summary. Exits 0 only if every file passes.
- `--fail-fast` option bails on the first failure; default is to check everything and report everything.
- `scripts/validate-state.sh` gains a `--schema <path>` flag so operators (and the self-test harness) can validate fixtures whose filenames don't match the auto-detected schema pairing. Default behavior (auto-detect from basename) is unchanged.
- Ten fixture files under `self-test/fixtures/state-schemas/` — valid + broken per schema — with each broken fixture violating exactly one documented rule (recorded in its `_comment` field).
- `state-schema-validators` golden case in `self-test/golden-cases.example.json` (kind: `script`) exercises every fixture and `validate-state-all.sh` end-to-end.
- `scripts/hydra-doctor.sh` Runtime-state category calls `validate-state-all.sh` and surfaces per-file mismatches verbatim on failure.
- CLAUDE.md § State files gains one sentence pointing operators at the schemas + the walker.

**Non-goals:**
- **Full JSON Schema validation.** The validator today is intentionally a required-top-level-keys check in bash + jq — it catches the common drift mode (somebody removes or renames a key) without pulling in `ajv-cli` as a runtime dep. Nested-shape checks (enum values, array-item required fields, regex patterns on ISO timestamps) are declared in the schema files but not enforced at runtime by this PR.
- Not changing the existing auto-detection behavior. `validate-state.sh <path>` with no `--schema` flag behaves exactly as it did after #44.
- Not a pre-commit hook. Doctor + self-test are enough enforcement for Phase 1; wiring to git hooks is an operator preference, not a framework requirement.
- Not moving schemas. They stay at `state/schemas/*.schema.json`. Callers that hard-code that path (the auto-detect logic, the doctor, the self-test fixtures) work as before.

## Proposed approach

### Extend `validate-state.sh`

Add an optional `--schema <path>` flag. When supplied, skip the basename-to-schema auto-detection and validate directly against the given file. When absent, behavior is identical to #44.

The driver loop uses the same jq-based required-key check. All it needed was a first argument-parsing pass to pick up `--schema` before falling through to the state-file positional.

### Add `validate-state-all.sh`

New script under `scripts/`. Walks `state/*.json` (skipping `*.example.json` templates), looks up the matching schema by basename, and invokes `validate-state.sh` per file. Two supported options:

- `--state-dir <path>` — override the state directory (mainly for fixtures + the self-test case's staged tmp dir).
- `--fail-fast` — break on the first failure instead of collecting all results.

Output is one line per file with a `✓` / `✗` prefix; failed files have the validator's error message indented below. Summary line at the end: `N passed · M failed · K skipped`. `skipped` means "state file present but no matching schema" — forward-compat for state files added before their schema.

### Fixtures

Ten files under `self-test/fixtures/state-schemas/`, two per schema:

```
active-valid.json            active-broken.json            (missing 'workers')
budget-used-valid.json       budget-used-broken.json       (missing 'rate_limit_hits_today')
memory-citations-valid.json  memory-citations-broken.json  (missing 'citations')
repos-valid.json             repos-broken.json             (missing 'repos')
autopickup-valid.json        autopickup-broken.json        (missing 'consecutive_rate_limit_hits')
```

Each broken fixture violates exactly one required top-level key (since that's what the minimal validator enforces today), and each one records the violation in a `_comment` field so a reader knows what to expect without running the tool.

### Self-test golden case

`state-schema-validators` (kind: `script`) in `self-test/golden-cases.example.json`:

- One step per valid fixture: validator exits 0, stdout contains `"passes minimal validation"`.
- One step per broken fixture: validator exits 1, stderr contains the expected violation keyword.
- Three steps for `validate-state-all.sh`: all-valid staged dir exits 0; mixed-broken dir exits 1; `--fail-fast` stops at the first failure (1 passed · 1 failed in the summary).

The staged-dir steps use `mktemp -d` + `cp state/schemas/*.json` so the self-test doesn't mutate the real `state/` dir.

### Doctor integration

`scripts/hydra-doctor.sh:check_runtime()` gains a call to `validate-state-all.sh --state-dir "$ROOT_DIR/state"`. On pass, it surfaces the summary line. On fail, it emits `✗ validate-state-all.sh` and echoes each per-file mismatch line from the tool's stdout indented under the check.

### Alternatives considered

- **Use `ajv-cli` for full JSON Schema validation.** Would give proper nested-shape enforcement (enum checks, pattern matching, array-item required fields). Rejected to preserve Hydra's zero-install commitment: the current spec surface is bash + jq + git + gh + claude. Adding a Node-based dep for a validation feature that the doctor runs on every session is a material tax for the common case (schema is correct). The minimal validator covers the common drift mode (missing / renamed keys) and the schemas themselves still document the full contract for humans and future tooling.
- **Inline the schema check inside `validate-state-all.sh` instead of shelling out per-file.** Rejected: shelling out to `validate-state.sh` keeps one code path for "what does valid mean" — operators debugging a failure can re-run the same validator by hand against a single file and get the same answer. The per-invocation cost is negligible (one `jq empty` + one `jq -r .required` per file).
- **Make the broken-fixture violations richer (multiple violations per file).** Rejected: one-violation-per-fixture is how "deliberately broken, obviously" reads. A fixture with three violations invites debate about which one the validator was actually supposed to catch.

## Test plan

- `bash -n scripts/validate-state-all.sh` — syntax clean.
- `jq empty` on all ten fixture files — valid JSON.
- Each valid fixture → validator exit 0.
- Each broken fixture → validator exit 1 with the expected keyword in stderr.
- `validate-state-all.sh` on a tmp dir staged with all five valid fixtures → exit 0.
- `validate-state-all.sh` on a tmp dir with one valid + one broken → exit 1, summary reports both.
- `validate-state-all.sh --fail-fast` on two-broken dir → exit 1, summary shows 0 passed · 1 failed (stopped at first).
- `self-test/run.sh --case state-schema-validators` → all 15 steps pass.
- `self-test/run.sh --kind=script` → all existing script cases still green (no regressions).
- `hydra-doctor.sh --category=runtime` on clean state → passes, shows validate-state-all summary line.
- `hydra-doctor.sh --category=runtime` on a manually-broken `state/active.json` → fails, prints the specific mismatch.

## Risks / rollback

- **Risk: somebody adds a new state/*.json file before writing a schema.** `validate-state-all.sh` treats "no matching schema" as `skipped` (warning-colored, not a failure) — the doctor stays green, and the summary makes it visible. Upgrade path is "add the schema", not "fix the tool".
- **Risk: the minimal validator misses a nested-shape regression** (e.g. a worker entry with `tier: "T5"` that isn't in the enum). Doctor + self-test won't catch it today. Mitigation: schema files are still authoritative documentation; when the worker pool rewrites state, the worker-review gate re-reads the field against CLAUDE.md expectations. Long-term upgrade: switch the validator to `ajv-cli` behind an opt-in flag once the zero-install guarantee is relaxed.
- **Rollback:** this is additive. Reverting the PR restores the post-#44 state (schemas + minimal validator only), which is strictly less strict than what this PR ships. No state migration, no workflow change for operators who never enable autopickup or run the doctor.

## Implementation notes

- `validate-state-all.sh` shells out to `validate-state.sh` rather than reimplementing the required-keys check, so the two stay in sync automatically.
- The self-test uses `mktemp -d` for the all-valid + mixed-broken staged-dir steps rather than touching the real `state/` dir — this is important for the doctor, since `hydra-doctor-runs-clean` runs in the same worktree and must not observe mutated state files.
- The doctor integration prints the validator's own stdout for failures (indented) rather than re-generating the message, so operators see the same text whether they invoke `scripts/validate-state-all.sh` by hand or see it surface through `hydra doctor`.
