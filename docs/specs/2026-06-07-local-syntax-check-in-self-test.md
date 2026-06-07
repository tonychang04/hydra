---
status: accepted
date: 2026-06-07
author: hydra worker
---

# Local syntax-check parity: run CI's frontmatter gate before pushing

## Problem

PRs #243 and #244 both passed local `self-test/run.sh` + `scripts/validate-state-all.sh`
but FAILED CI on the `Syntax (bash -n + jq + frontmatter)` job
(`.github/workflows/scripts/syntax-check.sh`) because their new `docs/specs/*.md`
files lacked the required `status:` / `date:` frontmatter. The worker runs the
local harness, sees green, opens the PR, and only discovers the failure after CI
— a wasted round-trip every time a worker adds a spec or a script.

The root gap: the CI syntax-check is **not invoked by anything a worker runs
locally**. `self-test/run.sh` runs golden cases; none of them invoke
`.github/workflows/scripts/syntax-check.sh`. So the single most common reason a
green-looking Hydra PR fails CI (missing spec frontmatter) is invisible until CI.

## Goals / non-goals

**Goals:**

- A worker can run **one local command** that reproduces the CI syntax-check
  verdict (same script, same exit code) before pushing.
- That command is wired into the self-test harness as a golden case, so it runs
  in CI too (`./self-test/run.sh --kind=script`) and stays from drifting.
- Prove the parity: a deliberately frontmatter-less spec fixture makes the local
  check fail **identically to CI**, and a well-formed spec passes.
- New specs start valid: confirm `docs/specs/TEMPLATE.md` exists with the
  required frontmatter skeleton (syntax-check already skips `TEMPLATE.md` /
  `README.md`).

**Non-goals:**

- Editing `.claude/agents/worker-*.md` to mandate the new command in the worker
  prompt. PR #243 owns those files; wiring the prompt guidance is a deliberate
  follow-up after #243 merges. This spec documents the command so that follow-up
  is a one-liner.
- Editing `CLAUDE.md` (currently near the WARN band).
- Re-implementing or changing the syntax-check logic. The CI script remains the
  single source of truth; we invoke it, never duplicate it.

## Proposed approach

Add a thin wrapper `scripts/preflight-syntax.sh` that runs the **existing** CI
script `.github/workflows/scripts/syntax-check.sh` against the current worktree
and propagates its exit code. The wrapper is the "one command" a worker (or the
worker prompt, post-#243) runs before pushing:

```bash
scripts/preflight-syntax.sh
```

Single source of truth: the wrapper `exec`s the CI script — no logic is copied,
so the local verdict can never diverge from CI's.

Wire it into the self-test harness via a fixture + golden case, matching the
existing `worker-git-worktree` / `early-pr-skeleton` pattern:

- `self-test/fixtures/local-syntax-check/run.sh` — a self-contained RED→GREEN
  fixture. It (1) asserts the wrapper passes on the real repo (GREEN), (2)
  builds a throwaway temp repo containing a frontmatter-less spec and asserts
  the CI script fails on it with exit 1 and the canonical
  `missing: status` / `date` message (RED reproduced), and (3) asserts a
  well-formed spec in that temp repo passes (GREEN). The temp repo is created in
  `mktemp -d` and removed via `trap` — no network, no docker, no Claude auth.
- A golden case `local-syntax-check-parity` (kind `script`) in
  `self-test/golden-cases.example.json` whose steps `bash -n` the wrapper, run
  the fixture, and confirm the wrapper passes on the current branch.

### Alternatives considered

- **Alternative A — add a `docs/specs` frontmatter check directly to a golden
  case (no wrapper).** Rejected: it would duplicate the syntax-check's
  frontmatter logic in the golden case, creating a second source of truth that
  drifts from the CI script. The whole point is parity with CI.
- **Alternative B — make `self-test/run.sh` always call `syntax-check.sh` as a
  built-in step.** Rejected: `run.sh` is a generic golden-case dispatcher; baking
  a specific CI script into it breaks its single-responsibility design and the
  `--kind` / `--case` filtering model. A golden case is the idiomatic seam.
- **Alternative C — a git pre-push hook.** Rejected: hooks aren't committed/shared
  reliably across worktrees and the worker harness doesn't install them; a script
  the prompt names is the established Hydra pattern.

## Test plan

- `bash -n scripts/preflight-syntax.sh` — clean.
- `scripts/preflight-syntax.sh` — exit 0 on this branch (green) once this spec's
  own frontmatter is valid; **this is the parity proof for this very PR.**
- `self-test/fixtures/local-syntax-check/run.sh` — exit 0, prints `ALL TESTS
  PASS`; internally proves the RED case (frontmatter-less spec → exit 1 with the
  `missing: status`/`date` message) and the GREEN case.
- `./self-test/run.sh --case=local-syntax-check-parity` — passes.
- `./self-test/run.sh --kind=script` — full script suite still green.
- `scripts/validate-state-all.sh` — exits 0 (golden-cases JSON still valid).

## Risks / rollback

- **Risk:** the fixture's throwaway-repo reproduction relies on the CI script
  resolving its repo root from `BASH_SOURCE`, so copying it into a temp tree must
  preserve the `.github/workflows/scripts/` path depth. Mitigation: the fixture
  copies the script to the identical relative path inside the temp repo and runs
  it from there. If the CI script's root-resolution ever changes, this fixture's
  golden case fails loudly — which is the intended early-warning.
- **Rollback:** revert this PR. It adds files only (`scripts/preflight-syntax.sh`,
  one fixture dir, one golden case, this spec); it modifies no existing scripts or
  agent definitions, so reverting is clean.

## Implementation notes

- `expected_stdout_contains` is silently ignored by `self-test/run.sh` (only
  `expected_stdout_jq` and `expected_stderr_contains` are honored). The golden
  case therefore relies on **exit codes** for its assertions and lets the fixture
  do the substring matching internally — same as the `worker-git-worktree`
  and `early-pr-skeleton` cases.
