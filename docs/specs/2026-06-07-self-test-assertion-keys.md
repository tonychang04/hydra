---
status: accepted
date: 2026-06-07
---

# self-test runner: honor `expected_stdout_contains` + reject unknown golden-case keys

## Problem

`self-test/run.sh:run_script_case()` parses a fixed allowlist of per-step
assertion keys — `expected_exit`, `expected_stdout_jq`, `expected_stderr_contains`
(run.sh lines ~322–327). A golden case that specifies **`expected_stdout_contains`**
has that field **silently ignored**: the runner never reads it, so no assertion
runs. The step passes as long as the exit code matches, regardless of what is on
stdout.

This is not a hypothetical typo — `golden-cases.example.json` uses
`expected_stdout_contains` on **322** steps (e.g. `autopickup-default-on-smoke`,
`hydra-cli-subcommands-valid`, `hydra-doctor-runs-clean`, `state-schemas`,
`launcher-dispatch-smoke`). Every one of those is dead metadata today: the case
LOOKS like it verifies stdout but only checks the exit code. The README even
documents the field as supported ("checks `expected_exit`, `expected_stdout_jq`,
`expected_stderr_contains`") — `expected_stdout_contains` is neither in the doc
nor in the code, yet is the most-used assertion key in the cases file.

The regression harness is the thing that guards all framework changes
(`CLAUDE.md`, worker subagents, `policy.md`, `scripts/*.sh`). Silent
no-op assertions give false confidence in that guard.

### Root cause

`run_script_case()` reads keys by name from each step JSON. There is no
read of `expected_stdout_contains` and no validation that every key present in a
step is one the runner understands. Both the missing-feature and the
silent-typo failure modes share one cause: the runner trusts an implicit, never-
enforced key contract.

## Goals

- Implement `expected_stdout_contains` as a substring assertion on captured
  stdout, mirroring exactly how `expected_stderr_contains` already works
  (`grep -Fq -- "$needle"` against the captured stream).
- Make the runner **fail fast** on any unknown/unsupported key in a step object,
  with a clear message naming the offending key and step — so a typo or an
  unsupported field is loud, not silent.
- Prove both behaviors with meta-fixtures (RED → GREEN), wired into the existing
  `runner-meta` self-meta case.

## Non-goals

- No change to `expected_stdout_jq` / `expected_stderr_contains` / `expected_exit`
  semantics.
- No new assertion key beyond `expected_stdout_contains`.
- No change to case-level keys (`id`, `kind`, `worker_type`, `tier`, `steps`,
  `requires`, `last_run`, `last_result`, `_*` comment rows). The unknown-key
  guard applies to **step** objects only, where the assertion contract lives.
- No change to `scripts/autopickup-tick.sh`, `scripts/validate-state*.sh`, or
  `.github/workflows/ci.yml` (owned by sibling tickets #240 / #249).

## Proposed approach

In `run_script_case()`, after the existing `expected_stderr_contains` check, add
a third assertion block:

```bash
expected_stdout_contains="$(jq -r '.expected_stdout_contains // empty' <<<"$step_json")"
...
if [[ -n "$expected_stdout_contains" ]]; then
  if ! grep -Fq -- "$expected_stdout_contains" "$stdout_tmp"; then
    failed_reason="step $i ($step_name): stdout did not contain '$expected_stdout_contains'"
    ...break
  fi
fi
```

For the unknown-key guard, at the top of the per-step loop compute the set of
keys present in the step JSON and subtract the known set. If any remain, fail the
case with a message naming the first unknown key:

```bash
known='["name","cmd","expected_exit","expected_stdout_jq",
        "expected_stderr_contains","expected_stdout_contains","timeout_sec"]'
unknown="$(jq -r --argjson known "$known" \
  '(keys - $known) | map(select(startswith("_") | not)) | .[0] // empty' \
  <<<"$step_json")"
```

`timeout_sec` is included in the known set because `ensure-repo-cloned-idempotent`
already uses it as an advisory field (it is read by no current code path but is a
documented, intentional key, so it must not trip the guard). Keys beginning with
`_` are treated as comments and allowed (consistent with the case-level `_comment`
/ `_description` convention used throughout the cases file).

### Alternatives considered

- **Warn-but-continue on unknown keys.** Rejected: the ticket asks for fail-fast,
  and a warning in a 144s run is easy to miss — the same false-confidence trap.
- **Validate keys via a JSON schema file.** Rejected as over-engineering for v1:
  the runner has no schema dependency today and the known-set is tiny. A jq
  set-difference is self-contained and matches the runner's existing bash+jq
  style. (Follow existing patterns — don't introduce a new mechanism.)
- **Only add `expected_stdout_contains`, skip the guard.** Rejected: that fixes
  the one known field but leaves the next typo silent. Both halves close the
  root cause.

## Test plan

Meta-fixtures under `self-test/fixtures/self-test-runner/`, exercised by the
existing `runner-meta` case (the runner testing itself):

1. **`expected_stdout_contains` actually asserts (RED proof).** A new fixture
   case `assert-stdout-contains-red` whose step emits `hello` but expects
   `goodbye` — the runner MUST exit 1 (before this change it exited 0, proving
   the field was ignored). A companion `assert-stdout-contains-green` emits and
   expects `hello` — MUST exit 0.
2. **Unknown key fails loudly.** A new fixture case `unknown-key` with a step
   carrying `expected_stduot_contains` (deliberate typo) — the runner MUST exit 1
   with a message naming the unknown key.
3. **No regression.** Full `self-test/run.sh --kind script` stays green (48
   passing cases), proving the 322 existing `expected_stdout_contains` steps that
   now ACTUALLY run still pass.
4. `scripts/preflight-syntax.sh` green (bash -n + jq + frontmatter), reproducing
   the CI syntax gate locally.

## Risks / rollback

- **Risk:** the 322 `expected_stdout_contains` steps were silently passing; once
  honored, a genuinely-wrong assertion would newly FAIL. Mitigation: the full
  `--kind script` run is part of the test plan and must stay green before merge —
  surfacing any such case is the point of the fix, not a regression of it.
- **Risk:** a legitimate not-yet-known step key trips the guard. Mitigation: the
  known-set is documented here and `_`-prefixed comment keys are always allowed;
  adding a new key is a one-line edit to the known-set in the same PR that
  introduces it.
- **Rollback:** revert the single commit touching `self-test/run.sh` and the
  fixture/case additions. No state, schema, or CI changes to unwind.
