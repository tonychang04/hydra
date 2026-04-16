# Commander self-test

Regression harness that runs the commander against known-good closed PRs to catch when a change to `CLAUDE.md` / a worker subagent / `policy.md` makes worker output meaningfully worse.

**This IS "using the commander to test the commander"** — the same auto-testing + worktree-spawning primitives that clear real tickets also validate our own changes.

## Files

- `golden-cases.json` — validated closed PRs with ground truth and assertions. Add a case by completing a manual Stage-0 run successfully and capturing the details.

## When to run

- Before committing changes to `commander/CLAUDE.md`, `commander/.claude/agents/*.md`, or `commander/policy.md`
- Before promoting a skill from memory to a repo
- After any upstream Claude Code / Agent SDK update that could affect worker behavior

## Commands (in commander chat)

- `self-test` — run all golden cases sequentially
- `self-test <case-id>` — run one case (e.g. `self-test cli-50`)
- `self-test --parallel` — run all cases in parallel (faster; uses up to `max_concurrent_workers` from budget)

## How it works

For each case:
1. Create a worktree at `parent_commit` with branch `commander/self-test-<id>-<timestamp>`
2. Spawn the specified `worker_type` subagent in that worktree with the ticket body summary as the prompt
3. Worker runs DRY RUN: no `gh pr create`, no push — just commits locally
4. Commander diffs the worker's commit against the assertions in `golden-cases.json`
5. Result: pass / fail / degraded (passes hard assertions but regressed quality signals)
6. Clean up the worktree
7. Update `last_run` and `last_result` in `golden-cases.json`

## Assertion types

- `must_touch_paths` — every listed path must appear in the commit's file list
- `must_not_touch_paths` — no listed path may appear (supports globs)
- `must_include_patterns` — each pattern must appear in the commit diff as a string
- `tests_expected` — if true, commit must add at least one `*.test.*` or `*_test.*` file
- `build_must_pass` / `typecheck_must_pass` / `lint_must_pass` — respective command must exit 0
- `typecheck_baseline_compare` — error count ≤ pre-edit baseline (for repos with known pre-existing errors)
- `max_files_changed` — diff touches no more than N files
- `vite_build_must_pass` — npx vite build specifically (for repos where `npm run build` is known-broken on baseline)

## On failure

Commander reports:
```
❌  Self-test failed: <case-id>
Assertion failed: <which one>
Worker's commit: <sha>
Diff excerpt: <...>

Likely cause: recent change to <file>. Inspect via:
  git diff HEAD~5 commander/CLAUDE.md commander/.claude/agents/
```

Gary decides whether to revert the commander change or update the golden case (rare — usually means the assertion was too strict).
