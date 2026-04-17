---
status: implemented
date: 2026-04-16
author: hydra worker (ticket #36)
---

# hydra doctor — single-command install diagnostic

## Problem

Operators today hunt through `setup.sh`, `state/`, `memory/`, and `.claude/settings.local.json` to figure out why Hydra isn't behaving. INSTALL.md has a symptom → fix table, but the operator has to know the symptom first. When something's subtly broken — stale learnings, missing state file, denylist that got edited — there's no single place to look.

Concrete signal: ticket #36. Standard ops-tool pattern (`kubectl cluster-info`, `terraform validate`, `docker system info`, `brew doctor`). If every other distributed-system tool has a doctor, Hydra should too.

## Goals / non-goals

**Goals:**
- `./hydra doctor` exists; runs in a clean repo in under 10s
- Emits per-check pass/fail with color on TTY, plain on pipes
- Exits 0 on all-pass or warnings-only; exits 1 on any failure
- Categories (environment, config, runtime, memory, scripts, integrations, self-test) each address one clear slice of the install surface
- Non-destructive by default; `--fix-safe` is the only write path and only for safe ops (chmod +x, mkdir -p)
- Integrates with `./hydra` launcher so operators run `./hydra doctor`, not `scripts/hydra-doctor.sh` directly
- Referenced from README §Verify install and INSTALL.md §Troubleshooting as the first thing to try

**Non-goals:**
- **Doctor is diagnostic, not auto-remediation.** `--fix-safe` does narrow, idempotent repairs only (chmod +x on a script that lost its bit, mkdir -p a missing `logs/`). It never edits `.claude/settings.local.json`, `policy.md`, `budget.json`, worker subagents, state JSON contents, or memory files. Those require the operator.
- Not a replacement for `setup.sh`. Doctor runs post-install; setup.sh does install-time config generation. They share check logic in spirit, not in code.
- Not a test runner. The `self-test` category delegates to `./self-test/run.sh --kind=script` — doctor surfaces pass/fail, it doesn't re-implement golden-case execution.
- Not a monitoring daemon. One-shot invocation only.
- No Python, Node, or non-bash dependencies. jq is the only hard dep beyond POSIX bash.

## Proposed approach

`scripts/hydra-doctor.sh` is a single bash script using `set -euo pipefail`. Categories run in a fixed order:

1. **environment** — `claude` / `gh` / `jq` / `git ≥ 2.25` on PATH, `gh auth` is live, `$HYDRA_ROOT` / `$HYDRA_EXTERNAL_MEMORY_DIR` env vars set (warn if unset — `setup.sh` writes them to `.hydra.env` which the launcher sources), external memory dir exists + writable.
2. **config** — `.claude/settings.local.json` parses, self-modification denylist is intact (spot-check for `Edit(...CLAUDE.md)` in the deny array), `state/repos.json` parses + has ≥1 enabled repo + each enabled repo's `local_path` exists and has `.git/`, `budget.json` parses with `max_concurrent_workers ∈ [1, 20]`.
3. **runtime** — `state/active.json` / `state/budget-used.json` / `state/memory-citations.json` parse, no unexpected `PAUSE` file (warn if present), `logs/` writable.
4. **memory** — `memory/MEMORY.md` exists, `scripts/validate-learning-entry.sh` passes on every `learnings-*.md` (both `memory/` and `$HYDRA_EXTERNAL_MEMORY_DIR`), `scripts/validate-citations.sh` passes on `state/memory-citations.json` (treat empty as pass — clean install).
5. **scripts** — `bash -n` on every `scripts/*.sh`, `setup.sh`, `install.sh`, `self-test/run.sh`; executable bits set; `scripts/validate-state.sh` against every `state/*.json` with a matching schema in `state/schemas/`. **This category is deterministic — doesn't depend on external state** — so it's the one the self-test case exercises.
6. **integrations** — Linear MCP only if `state/linear.json:enabled=true` (skipped cleanly when not configured); `mount-s3` + `aws sts get-caller-identity` only if `HYDRA_STATE_BACKEND=dynamodb`.
7. **self-test** — `./self-test/run.sh --kind=script`. Pass/fail surfaces up to the doctor's summary.

Each check writes one line via `check_pass` / `check_warn` / `check_fail` primitives that update shared counters. Summary line at the end: `N passed · M warnings · K failures  (overall: OK | WARN | FAIL)`. Warnings count toward the summary but don't cause a non-zero exit — that's the whole point of WARN vs FAIL.

**Launcher integration:** `setup.sh` generates `./hydra`. The launcher now special-cases `./hydra doctor` as a subcommand — it sources `.hydra.env` (if present, so doctor sees the env vars), then `exec scripts/hydra-doctor.sh "$@"`. No claude session is launched. This matches the `kubectl cluster-info` / `docker system info` shape where the diagnostic is a sibling subcommand, not a flag on the main launcher.

### Alternatives considered

- **Alternative A: Roll doctor into `setup.sh --verify` or `./setup.sh --check`.** Rejected because `setup.sh` is idempotent install, not diagnostic. Running `setup.sh` again after an install already does a partial re-check (it warns "X already exists — leaving as-is"), but that's install-time logic. Doctor needs to be runnable against a stable install without the confusing "already exists" noise, and needs to exit 1 on failure so CI / operators / upstream agents can gate on it. Keeping them separate keeps each tool's responsibility clear.
- **Alternative B: Python / Node doctor with pretty output and structured JSON.** Rejected — adds a dep. Hydra's hard rule is bash + jq only for the installable surface. Prefer color bash output over introducing language runtimes.
- **Alternative C: A doctor Claude subagent** (similar pattern to `worker-test-discovery`). Rejected for the post-install case because (a) doctor needs to run *before* `./hydra` is fully launch-able, (b) it's deterministic shell-checkable logic, not something that benefits from LLM reasoning. Commander can still invoke doctor as a tool call if the MCP interface exposes it — but the underlying implementation is still a shell script.
- **Alternative D: Add checks to each script individually (`scripts/*.sh --self-check`).** Rejected because doctor's value is ONE command. Scattering the checks makes the operator run 7 commands.

## Test plan

- `bash -n scripts/hydra-doctor.sh` — passes (covered by the Scripts category of doctor itself, and by the self-test case).
- `./scripts/hydra-doctor.sh --help` — prints usage; exits 0.
- `./scripts/hydra-doctor.sh --category=scripts` — deterministic; exits 0 in any valid worktree; stdout contains `passed` and `Summary:`.
- `./scripts/hydra-doctor.sh --category=environment --verbose` — runs all environment checks; exits 0 if env is good.
- `./scripts/hydra-doctor.sh` — full run; exits 0 in a setup'd repo; exits 1 if `state/repos.json` is missing.
- `./scripts/hydra-doctor.sh --category=bogus` — exits 2 with a usage error.
- Self-test golden case `hydra-doctor-runs-clean` (`self-test/golden-cases.example.json`, kind `script`) — runs the Scripts category and asserts exit 0 + `Summary:` + `passed` in stdout. This is what `commander` runs before committing changes to `scripts/hydra-doctor.sh`.

## Risks / rollback

- **Risk: A new Hydra script gets added without `chmod +x` and doctor's `scripts` category starts warning.** Mitigation: `--fix-safe` auto-applies `chmod +x`. Acceptable because chmod +x is idempotent and doesn't mutate file content.
- **Risk: A future state file gains a schema but isn't wired into `state/schemas/` — doctor silently skips it.** Acceptable for now; the Scripts category only checks files that have a schema. If drift becomes a problem we can add an explicit `schemas_required` list.
- **Risk: The git ≥ 2.25 floor is too strict — some operators run older macOS system git.** Noted: this check failed on a git 2.23 environment during development. The worktree subcommand landed in git 2.5, so 2.25 is aspirational (newer worktree UX). If this becomes a blocker in the field we can downgrade the check to 2.5.
- **Rollback:** delete `scripts/hydra-doctor.sh`, revert the `./hydra doctor` subcommand in `setup.sh`, revert the README / INSTALL.md / self-test additions. No state touched, no other script depends on doctor — it's a leaf.

## Implementation notes

- Doctor's success path emits exactly one line per check. Resist the urge to add progress spinners or multi-line per-check prose — operators are scanning for ✓/⚠/✗.
- `check_warn` does NOT increment the failure count. An install with only warnings still exits 0. This is deliberate: `HYDRA_ROOT` unset is a warning (launcher sources it) but doesn't stop the machine. Treating it as a failure would cause doctor to false-fail on fresh installs that haven't launched yet.
- The `Scripts` category is the test-harness target because it's the only category whose result doesn't depend on a fully-setup repo. The self-test case runs in CI / uncommitted worktrees / pre-`setup.sh` states and still passes. All other categories are intentionally environment-dependent.
- `--fix-safe` is scoped narrowly: chmod +x on a script that's already in-tree, mkdir -p on `logs/` / `$HYDRA_EXTERNAL_MEMORY_DIR`. It deliberately does NOT touch `state/*.json` contents, `.claude/settings.local.json`, `CLAUDE.md`, `policy.md`, `budget.json`, or any worker subagent. That's where the operator-reviewed boundary lives.
- "Where NOT to put doctor": don't embed doctor logic in `setup.sh` (install vs. diagnostic are separate); don't add checks that require writing non-test state (doctor reads, not writes); don't chain doctor into a commander subagent (it's a shell script, runs before commander is even up). The `./hydra doctor` launcher hook exists only to route the subcommand — the actual logic stays in `scripts/hydra-doctor.sh`.
