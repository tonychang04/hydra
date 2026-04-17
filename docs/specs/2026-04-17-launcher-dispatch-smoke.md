---
status: draft
date: 2026-04-17
author: hydra worker (ticket #117)
---

# Launcher dispatch smoke test + bundled smoke-test fallout

## Problem

A manual smoke-test pass on 2026-04-17 found that ~4 session PRs could have landed with broken CLI dispatch. The ticket body (#117) describes five concrete failures; the state of `main` at the time the ticket was written and the state at implementation time turned out to be different, so a read against the current tree is required before writing any fix.

**Confirmed on current `main` (07138b6):**

1. `./hydra --help` falls through to `claude --help`. A user asking "what commands does Hydra have?" reads Claude Code's help instead of Hydra's. Silent, no error, actively misleading.
2. `scripts/validate-learning-entry.sh` fails on `memory/learnings-hydra.md` with `line NN exceeds 500 characters`. The file is written by real workers whose notes are dense single-line entries; 500 chars is too tight for the content the schema wants to hold. Result: `hydra doctor` reports a permanent FAIL on any install with worker-contributed learnings, eroding trust in the diagnostic.
3. No self-test asserts that `./hydra <subcommand>` dispatches to its helper script. Every prior worker "verified" by running `scripts/hydra-<x>.sh --help` directly (which works) without going through `./hydra <x>` (which may or may not dispatch). That gap is why #117 was filed — the illusion-of-working bug was detectable post-hoc but nothing in CI catches it going forward.

**Already fixed on current `main` (ticket body was stale):**

4. Launcher dispatch for `ps`, `activity`, `mcp serve`, `mcp register-agent` — already present in the `setup.sh` heredoc at HEAD. Verified by regenerating the launcher in a tmpdir and running each subcommand.
5. `doctor` `ext_learnings[@]` unbound-variable crash — already defended via `shopt -s nullglob` + explicit `${#arr[@]} -gt 0` check before expansion. The existing code handles empty memory dirs cleanly; the ticket description was stale.
6. `doctor --fix` vs `--fix-safe` flag drift — both flags exist on current `main`; the #104 spec documents both explicitly and the code matches.

**Trivial belt-and-suspenders** (not bugs but hardening):

7. Add `:-}` default-guard on the `ext_learnings` array expansion even though `nullglob` + length-check already covers it. Matches the intent of the existing comment (`# still default-guard the expansion so a bare set -u + empty dir doesn't abort doctor`). Zero behavior change; defense-in-depth against a future refactor that drops `nullglob`.

## Goals / non-goals

**Goals:**

- Add a `--help` top-level case to the launcher that prints Hydra's command list (not Claude's). Exits 0.
- Relax `validate-learning-entry.sh` line-length cap from 500 → 1500. Enough headroom for worker-style dense notes; still catches obvious runaway lines.
- Add a `launcher-dispatch-smoke` self-test case that regenerates the launcher in a tmpdir via `./setup.sh --non-interactive` and invokes every documented subcommand via `./hydra <cmd> --help`, asserting each produces its helper script's usage text (not Claude's help). This is the regression fence the earlier PRs didn't have.
- Belt-and-suspenders `:-}` on `ext_learnings[@]` in `hydra-doctor.sh`. Intent-matching no-op.

**Non-goals:**

- Do NOT re-fix already-correct dispatch for `ps` / `activity` / `mcp` — the code works. The new self-test asserts it keeps working.
- Do NOT investigate why the ticket body was stale; it's not load-bearing. The smoke test is the cure.
- Do NOT touch ticket #118 (self-test has zero executing cases) — out of scope.
- Do NOT change `--fix-safe` / `--fix` semantics — both flags already exist and match the spec.
- Do NOT modify `memory/learnings-hydra.md` itself — the schema is wrong, not the data.

## Proposed approach

### Launcher `--help` top-level case

Add a `--help` / `-h` case to the subcommand dispatch block in `setup.sh`'s launcher heredoc. Place it BEFORE the `case "${1:-}"` subcommand dispatch so `-h` / `--help` short-circuit before any env-file sourcing (same shape as `--version`). Print a static usage blob listing Hydra's commands + a one-line pointer to `./hydra <cmd> --help` for subcommand help + a closing "other args pass through to claude" note so `--help` as a passthrough flag to `claude` still has a documented escape (`./hydra -- --help` won't matter here since `--help` is our case).

Output shape follows the existing `mcp --help` block: a plain `cat <<'USAGE'` heredoc, no color, no dependencies, exits 0.

### Validate-learning-entry line-length cap

Change `MAX_LINE_LEN=500` → `MAX_LINE_LEN=1500` in `scripts/validate-learning-entry.sh`. Reason: the schema is meant to check frontmatter shape + expected section headings + sanity. It's not a style linter. The 500-char cap was an arbitrary initial choice; real worker notes run 700-1200 chars per line and there's no reader experience benefit to hard-wrapping them (these files are read by agents, not humans). 1500 is still tight enough to catch a multi-KB accidental JSON-blob paste or a truncated-newline concatenation bug.

Verify by running the validator against `memory/learnings-hydra.md` in the external memory dir (which has the long lines that fail today) and confirming exit 0.

### Self-test: launcher-dispatch-smoke

New golden case, kind `script`, added to `self-test/golden-cases.example.json`. Uses a fixture script at `self-test/fixtures/launcher-dispatch/run.sh` that:

1. Makes a tmpdir.
2. Copies the full worktree into it (or rsyncs with exclusions).
3. `rm`s any existing `./hydra` and `.hydra.env` in the tmpdir (forces regeneration).
4. Runs `HYDRA_NON_INTERACTIVE=1 HYDRA_EXTERNAL_MEMORY_DIR="$tmp/memdir" ./setup.sh --non-interactive` to materialize the launcher.
5. For each documented subcommand (`doctor`, `add-repo`, `remove-repo`, `list-repos`, `status`, `ps`, `pause`, `resume`, `issue`, `activity`, `mcp`), runs `./hydra <cmd> --help` and greps for a Hydra-specific marker:
   - Every Hydra helper script's usage starts with `Usage: ./hydra <cmd>` (convention enforced by existing `hydra-cli-subcommands-valid` case).
   - `claude --help` prints `Usage: claude ...` — completely different prefix.
   - If the grep fails, the script prints which subcommand broke and exits 1.
6. Runs `./hydra --help` and asserts the output contains a Hydra-specific marker (e.g. `Hydra` + list of subcommands). If the output contains `Claude Code - starts an interactive session`, that's the Claude Code help and the test fails loudly.
7. Runs `./hydra mcp register-agent --help` and `./hydra mcp serve --help` to exercise the two-level dispatch.
8. Cleanup: `rm -rf $tmp`.
9. On pass, prints `SMOKE_OK` and exits 0.

The self-test case has steps:

- `bash -n self-test/fixtures/launcher-dispatch/run.sh` — syntax check.
- Run the fixture; expect exit 0 + stdout contains `SMOKE_OK`.

Because `expected_stdout_contains` is doc-only in `run.sh`, the fixture itself does the grep-and-exit-nonzero at each assertion, mirroring the `activity-command-smoke` pattern in the existing cases.

Cost: the fixture copies the worktree into a tmpdir and runs setup.sh (~5-10s wall-clock including `gh auth status` probe). The existing `setup-interactive-ci-mode` case already does this shape (21s on CI). Acceptable.

### ext_learnings default-guard

Change line 552 of `scripts/hydra-doctor.sh` from:

```bash
local ext_learnings=("$ext_mem/"learnings-*.md)
if [[ ${#ext_learnings[@]} -gt 0 ]]; then
  learning_files+=("${ext_learnings[@]}")
fi
```

to:

```bash
local ext_learnings=("$ext_mem/"learnings-*.md)
if [[ ${#ext_learnings[@]:-0} -gt 0 ]]; then
  learning_files+=("${ext_learnings[@]:-}")
fi
```

Zero behavior change under `nullglob`; explicit protection if `nullglob` is ever accidentally dropped. Matches the existing comment's intent verbatim.

### Alternatives considered

- **Alternative A: Fix the stale bugs in the ticket body anyway (re-add dispatch routes).** Rejected. The current code is correct; "fixing" code that works introduces risk and confuses future readers looking at the diff. The regression fence (self-test) gives us the safety we need going forward.

- **Alternative B: Write a separate self-test case per subcommand.** Rejected. 10+ cases would bloat `golden-cases.example.json`. One fixture script with per-assertion sub-checks (all reporting to stdout) keeps the signal tight.

- **Alternative C: Change the launcher to re-generate on every `./hydra` invocation instead of once-at-setup-time.** Rejected. The launcher is intentionally static per `memory/learnings-hydra.md` 2026-04-17 #84 — "`./hydra` is NOT committed, generated at setup.sh runtime". Re-generating on every invocation changes the contract and risks breaking existing installs.

- **Alternative D: Make `validate-learning-entry.sh` skip the line-length check entirely.** Rejected. A runaway line (e.g. accidentally-pasted multi-MB JSON) is still a real failure mode; 1500 chars preserves that guard while allowing real worker content.

## Test plan

1. **Launcher `--help`:** Run `./hydra --help` in a freshly-regenerated tmpdir (tests via the new fixture). Assert output contains `Hydra` + subcommand list + does NOT contain `Claude Code - starts an interactive session`.
2. **validate-learning-entry line cap:** Run `scripts/validate-learning-entry.sh memory/learnings-hydra.md` against the external memory dir's copy. Assert exit 0.
3. **Self-test smoke:** Run `self-test/run.sh --case launcher-dispatch-smoke` locally. Assert PASS.
4. **Regression:** Run full `self-test/run.sh --kind=script` to confirm no existing case broke.
5. **Doctor hardening:** Run `./hydra doctor` with an empty `HYDRA_EXTERNAL_MEMORY_DIR` and with the populated one. Both should still exit with the same pass/warn/fail counts as before (behavior change must be zero).

## Risks / rollback

- **Risk: launcher `--help` collides with a future `claude --help` passthrough use case.** Low. The existing `--version` case already owns a top-level flag; `--help` follows the same pattern. If a user *wants* Claude's help they can run `claude --help` directly.
- **Risk: the 1500-char cap is still too low.** Possible but unlikely. If we see it again, bump higher or replace with a "warn-not-fail" rule. Easy to re-tune.
- **Risk: the self-test fixture has flaky timing on slow CI (copying the worktree).** Mitigated by excluding the tmpdir / .git / node_modules during the copy. The existing `setup-interactive-ci-mode` fixture is stable so the pattern is known-working.
- **Rollback:** revert the PR. No migrations, no persistent state, no schema changes. Trivial.
