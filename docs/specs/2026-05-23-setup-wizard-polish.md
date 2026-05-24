---
status: draft
date: 2026-05-23
author: hydra worker (ticket #172)
---

# Setup wizard polish — `--strict`, conditional fingerprint, env-source fallback

## Problem

Ticket #172 is the follow-up to #168 / PR #171 (setup wizard MVP merged as
`scripts/hydra-setup.sh`). A review of that MVP surfaced three non-blocking
concerns that should close *before* the planned session-greeting hook
(#169-family) starts reading the `state/setup-complete.json` fingerprint:

1. **No strict mode for automation.** Today
   `./hydra setup --non-interactive --repos=A,B,bad_slug` warns on `bad_slug`,
   skips it, and exits `0`. For CI / scripted installs (Ansible, cloud
   bootstrap) a partially-applied config that exits green is a silent failure:
   the operator believes every repo registered when one did not. There is no
   way to say "fail loudly if any repo slug is bad."

2. **Unconditional fingerprint write hides the empty case.**
   `state/setup-complete.json` is written even when zero repos were registered
   (e.g. `--non-interactive` with no `--repos`, or every slug failed). A future
   session-greeting check that reads the fingerprint to decide "has setup run?"
   cannot distinguish "setup completed and registered repos" from "setup
   completed but registered nothing" — the latter still needs the operator to
   add repos before Commander can do useful work.

3. **`source .hydra.env` has an ugly failure path.** The wizard runs under
   `set -euo pipefail` and sources `.hydra.env` at the top (line 31). A
   malformed env file (syntax error, partial write) makes `source` fail, which
   under `set -e` aborts the script with a raw bash error
   (`hydra-setup.sh: line 31: ...`) instead of the wizard's clean, uniform
   error reporting. The operator gets a stack-trace-shaped message with no
   guidance.

## Goals / non-goals

**Goals:**

- Add a `--strict` flag. In strict mode, if **any** repo slug fails validation
  or fails to register, the wizard exits non-zero (exit `2`, the existing
  "bad slug / usage" code) instead of warning-and-continuing.
- Default behavior is unchanged (permissive: warn on a bad slug, continue,
  exit `0`) for backwards compatibility with existing callers.
- Record how many repos actually landed by adding a `repos_registered: <int>`
  field to `state/setup-complete.json`, so a fingerprint consumer can tell
  "completed, empty" (`repos_registered == 0`) from "completed with repos"
  without re-parsing `state/repos.json`. Update the schema to permit the new
  field.
- Wrap the `.hydra.env` source in a defensive function so a malformed file is
  caught and reported through the wizard's normal `err()` path with a clear
  message and a clean non-zero exit — never a raw `set -e` abort.

**Non-goals:**

- Idempotent re-run flow / rotation UI — still punted to the session-greeting
  ticket family (#169), as the original MVP spec states.
- Connector sub-wizards — still just pointers (`./hydra connect …`).
- Switching the default to strict. Default stays permissive; `--strict` is
  opt-in. Changing the default is a separate, breaking decision.
- Validating the *contents* of `.hydra.env` (which vars it exports). The
  fallback only guarantees a malformed file is reported cleanly, not that the
  env is semantically complete — that is `./hydra doctor`'s job (step 1).

## Proposed approach

All changes are inside `scripts/hydra-setup.sh` plus a one-line schema update.
No other script, no launcher row, no CLAUDE.md routing change.

### 1. `--strict` flag

- Add a `strict=0` variable and a `--strict` case to the arg loop.
- `--strict` is only meaningful when repos are being registered, but it is
  harmless in interactive mode too (a bad slug typed at the prompt would abort
  the loop). To keep the change minimal and the contract obvious, `--strict`
  is accepted in both modes and applies wherever `add_one_repo` is called.
- `add_one_repo` already returns `0` on success, `1` on inner-script failure,
  `2` on a slug that fails the regex. The call sites currently do
  `add_one_repo "$slug" || true` (swallow). Change them to, on a non-zero
  return **and** `strict == 1`, print a strict-mode error and `exit 2`.
- Permissive mode (`strict == 0`) keeps the existing `|| true` swallow.

### 2. `repos_registered` field

- Maintain a `repos_registered` counter, incremented each time `add_one_repo`
  returns `0`.
- In step 5, include `repos_registered: <int>` in the `jq -n` fingerprint
  object.
- Update `state/schemas/setup-complete.schema.json`: add `repos_registered`
  (`integer`, `minimum: 0`) to `properties`. Leave it out of `required` so
  fingerprints written by the pre-#172 wizard (which lack the field) still
  validate — backwards-compatible schema evolution. Bump nothing else;
  `version` stays `1` because the field is additive and optional.

  > Why optional, not required: an old `setup-complete.json` already on disk
  > from before this change would fail validation if the field were required,
  > tripping `validate-state-all.sh` (a Commander preflight gate) for no reason.

### 3. Defensive `.hydra.env` source

- Replace the bare `[[ -f … ]] && source …` line with a small function,
  `source_hydra_env`, that:
  - returns `0` immediately if the file is absent (nothing to source — not an
    error; a fresh install legitimately has no `.hydra.env` yet),
  - sources the file inside an `if ! source …; then` guard so the failure is
    caught instead of tripping `set -e`,
  - on failure calls `err()` with a uniform message pointing at the file and
    suggesting `./hydra doctor`, then returns `1`.
- The caller does `source_hydra_env || exit 1` so a malformed file ends the
  wizard cleanly with the documented exit `1` (I/O / env failure) rather than a
  raw bash trace.
- The color helpers and `err()` are defined *after* the current source line, so
  the function definition + invocation move below the color-helper block (the
  source has no dependency on env vars being set before the helpers — it only
  exports `HYDRA_ROOT` etc. for *downstream* helpers like `hydra-doctor.sh`).

### Alternatives considered

- **AC2 — conditional fingerprint write instead of the counter.** The ticket
  offers "only write if ≥1 repo landed, OR add `repos_registered`." Writing
  conditionally was rejected: the MVP spec's Alternative C explicitly wants a
  dedicated "setup has run" signal *even when `repos.json` is populated by
  hand or empty*. Skipping the fingerprint on the empty case destroys that
  signal — a future hook could not tell "setup ran, no repos yet" from "setup
  never ran." The `repos_registered` field preserves both signals. This is the
  ticket's own preferred-sounding option ("OR add a `repos_registered` field
  so consumers can distinguish").

- **AC1 — make `--strict` the default and add `--permissive` to opt out.**
  Rejected: breaks every existing caller that relies on warn-and-continue
  (including the `--non-interactive` smoke test in the MVP spec). Opt-in
  `--strict` is the backwards-compatible choice the ticket asks for ("Keep
  default permissive for backwards compat").

- **AC3 — `set +e` around the source instead of an `if` guard.** Toggling
  `set +e`/`set -e` works but is easy to leave in the wrong state and reads
  worse than an explicit `if ! source …; then` guard, which both catches the
  failure and keeps `set -e` semantics for the rest of the script.

## Test plan

Self-test golden case (`self-test/golden-cases.example.json`, script kind, runs
in CI via `./self-test/run.sh --kind=script`). New case
`setup-wizard-polish-172`. Because `hydra-setup.sh` shells out to
`hydra-doctor.sh` (step 1, env check) and `hydra-add-repo.sh` (step 2) which
need a real clone + gh, the case stages a tmp `ROOT_DIR` and drives the wizard
through controlled paths that exit *before* those network/clone dependencies
where possible; the strict-failure paths fail at slug validation (step 2)
which is pure-local, so they run without `requires_*` gates. Steps:

1. `bash -n scripts/hydra-setup.sh` passes (syntax).
2. `--help` prints usage including `--strict`, exits 0.
3. `--strict` is rejected as unknown? No — assert it is **accepted** (does not
   exit 2 as an unknown flag). Drive `--non-interactive --strict
   --repos=bad_slug_no_slash` → exits `2` (strict: bad slug aborts).
4. Same repos but **without** `--strict` → the bad slug warns and the wizard
   proceeds past step 2 (permissive). (Asserted by checking step-2 does not
   abort; the wizard may still exit non-zero later at the env/doctor step in a
   bare tmp dir, so this step asserts the *step-2 behavior* via a stub doctor /
   add-repo — see the case for the stubbing approach.)
5. `repos_registered` appears in the written `state/setup-complete.json` and is
   `0` when no repos registered.
6. Defensive env source: a malformed `.hydra.env` in a tmp `ROOT_DIR` produces
   the clean `err()` message (stderr contains the uniform marker) and exits
   `1` — not a raw `line NN:` bash trace.
7. `validate-state-all.sh` still passes against a fingerprint that includes
   `repos_registered` (schema accepts the new field) AND against one that omits
   it (backwards compat).

`validate-state-all.sh` exit 0 is also asserted directly on the schema change.

## Risks / rollback

- **Risk:** the new `repos_registered` field trips `additionalProperties:false`
  in the schema. **Mitigation:** the schema update is part of this PR; CI's
  syntax-check (`jq empty`) + the self-test step 7 cover it.
- **Risk:** moving the `.hydra.env` source below the color-helper block changes
  ordering. **Mitigation:** the source only *exports* vars for downstream
  helper scripts; nothing between the old and new position reads those vars.
  Verified by reading lines 24–51 of the current script.
- **Risk:** `--strict` interacts badly with interactive mode. **Mitigation:**
  in interactive mode a bad slug already loops; strict just turns the
  continue into an exit. Documented in `--help`. Low blast radius — strict is
  opt-in.
- **Rollback:** revert the single commit. The wizard returns to permissive,
  the fingerprint loses `repos_registered` (optional field — no consumer
  breaks), the schema reverts. Additive change throughout.
