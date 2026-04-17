---
status: implemented
date: 2026-04-17
author: hydra worker (#138)
---

# CLAUDE.md size guard + procedure externalization

## Problem

Hydra's root `CLAUDE.md` is loaded into every Commander session's system prompt. In April 2026 it grew to **40,758 characters** — double the working-set budget we want for a routing document, and most of the bloat was duplicated procedures that already had their own specs in `docs/specs/`:

| Section | Chars | Spec already existed |
|---|---:|---|
| Worker timeout watchdog | 8214 | `docs/specs/2026-04-16-worker-timeout-watchdog.md`, `docs/specs/2026-04-17-review-worker-rescue.md` |
| Scheduled autopickup | 5131 | `docs/specs/2026-04-16-scheduled-autopickup.md` |
| Weekly retro | 3100 | `docs/specs/2026-04-16-retro-workflow.md` |
| Three-tier decision protocol | 2901 | `docs/specs/2026-04-16-mcp-agent-interface.md`, `docs/specs/2026-04-17-supervisor-escalate-client.md` |
| Auto-dispatch: worker-test-discovery | 2200 | (none — authored alongside this spec) |
| Memory hygiene | 1600 | `memory/memory-lifecycle.md` |

Every token of inline procedure is paid on every session start, forever. Operator feedback (`memory/feedback_claudemd_bloat.md`): **"CLAUDE.md holds only routing tables, hard rails, and one-line spec pointers."** gstack's reference CLAUDE.md sits at ~23k by keeping procedures in per-skill directories.

We need:

1. A **size ceiling** enforced mechanically (not by memory), so the next procedure somebody writes can't silently re-bloat the file.
2. A **one-time trim** of the existing inline procedures into pointers to the specs that already exist.
3. A **contributor rule** in `CONTRIBUTING.md` that points future PRs at `docs/specs/`, not at CLAUDE.md.

## Goals

- `CLAUDE.md` ≤ 18,000 characters (target ~14k with headroom for routing additions).
- Inline procedures replaced with 3-6 line pointers ending in `Spec: docs/specs/<file>.md`.
- `scripts/check-claude-md-size.sh` exits 1 if `CLAUDE.md > 18000`, prints top 5 H2 sections as trim candidates on failure.
- Threshold tunable via `HYDRA_CLAUDEMD_MAX` for self-test fixtures and hypothetical future adjustments.
- Hard-wired into `scripts/validate-state-all.sh` so Commander's spawn preflight refuses to dispatch when CLAUDE.md is over budget.
- Regression test covers both over- and under-threshold cases.
- `CONTRIBUTING.md` documents the rule so humans and Hydra workers see it before they add content.

## Non-goals

- Changing observable Commander behavior. The procedures still live in `docs/specs/`; Commander still reads them the same way (cited from CLAUDE.md via the pointer). Golden cases in `self-test/golden-cases.example.json` do not need changes.
- A warning/dry-run mode. The gate is binary — 18000 or less, or the preflight fails. If an operator needs a bigger ceiling they can set `HYDRA_CLAUDEMD_MAX` for one run, but that's an explicit override, not a soft warning.
- Applying the size rule to downstream-repo `CLAUDE.md` files. Those have their own budgets; this rule scopes to Hydra's root.

## Proposed approach

### 1. `scripts/check-claude-md-size.sh`

Pure bash + `wc -c` + `awk`. No external deps beyond standard Unix. Pattern copied from `scripts/validate-state.sh` (argparse, colored output when TTY, clear exit codes).

- Default path: `<repo-root>/CLAUDE.md`. Override with `--path <file>`.
- Default threshold: `18000`. Override with `--max <N>` or env var `HYDRA_CLAUDEMD_MAX`. (Flag wins over env.)
- Exit 0: under threshold; prints `ok: CLAUDE.md = <bytes> / <max>`.
- Exit 1: over threshold; prints the size header, then the top 5 H2 sections by character count as trim candidates. Uses `awk` to split on `^## ` anchors and count chars per section.
- Exit 2: usage error / file not readable.

### 2. Wire into `validate-state-all.sh`

The script is the existing preflight hub for every spawn. Adding one more check there means Commander gets the size gate for free without new wiring.

After the existing schema-validation loop, call `scripts/check-claude-md-size.sh`. If it exits non-zero, count it as a failure in the summary (same exit-1 behavior as a failed state file). Keep the per-file output format consistent — same `∅/✓/✗` prefixes.

Skip the check gracefully if CLAUDE.md isn't present (e.g., downstream repos using `validate-state-all.sh` against their own state dir) — mirrors the existing "state file absent = skip, not fail" rule.

### 3. Trim `CLAUDE.md`

Target shape: each inline procedure collapses to a pointer section like:

```
## Worker timeout watchdog

Workers can hit stream-idle timeouts around the 18-min mark with partial work in
the worktree. The watchdog runs on every tick that touches `state/active.json`,
uses `scripts/rescue-worker.sh --probe` to check for recoverable partial work,
and either rescues + resumes or labels `commander-stuck`. Review-worker rescue
uses `--probe-review` against GitHub instead of the worktree.

Spec: `docs/specs/2026-04-16-worker-timeout-watchdog.md` +
`docs/specs/2026-04-17-review-worker-rescue.md`.
```

3-6 lines of orienting context + a spec pointer. The full procedure, exit-code contracts, and edge-case enumeration live in the spec. Sections kept inline in full (hard rails only):

- Your identity (non-negotiable)
- Worker types table
- Operating loop (bullets, no prose)
- Commands table (full — that's the routing surface)
- Safety rules (hard)
- Applying labels note (short gotcha)
- State files list
- Session greeting rule (short)

### 4. `CONTRIBUTING.md` update

Append a "Commander procedure docs" section that states the rule: new behavior goes to `docs/specs/YYYY-MM-DD-<slug>.md`; CLAUDE.md gets at most a pointer. Reference this spec.

### Alternatives considered

- **Alternative A — document the rule but don't enforce it.** Rejected: humans forget, Hydra-on-Hydra workers don't read feedback memory during ticket work. The file re-bloats.
- **Alternative B — soft warning at 18k, hard fail at 25k.** Rejected: two thresholds means arguments about which applies. Binary gate is simpler and matches the feedback-memory rule ("if preflight trips on size, that's the signal to move a section out").
- **Alternative C — compress via shared-prefix deduplication across sections.** Rejected: fragile, hurts human readability. Spec pointers are both smaller and clearer.

## Test plan

New regression script: `scripts/test-check-claude-md-size.sh`. Runs in under a second, no fixtures outside a `mktemp` workdir.

1. **Under threshold**: write a 5000-char fake CLAUDE.md, run `check-claude-md-size.sh --path <tmp> --max 18000`, assert exit 0 + "ok:" prefix on stdout.
2. **Over threshold**: write a 20000-char fake CLAUDE.md with three labelled H2 sections, run the check, assert exit 1 + "top 5 H2 sections" + each section name appears in stdout.
3. **Env override**: run against a 5000-char file with `HYDRA_CLAUDEMD_MAX=1000`, assert exit 1 (env lowers the ceiling).
4. **Flag beats env**: run with `HYDRA_CLAUDEMD_MAX=1000 --max 18000`, assert exit 0 (flag wins).
5. **Missing file**: run against a nonexistent path, assert exit 2.

For the preflight integration: run `scripts/validate-state-all.sh` against the current repo; assert exit 0 and that the output includes the check-claude-md-size line. Run it with `HYDRA_CLAUDEMD_MAX=100`; assert exit 1.

`self-test/golden-cases.example.json` already has a `state-schemas` case that exercises `validate-state-all.sh`. It does NOT need editing — the size check runs on the worktree's real CLAUDE.md, which is <18k after this PR. A future follow-up ticket can add a dedicated `claudemd-size-guard` golden case with fixture CLAUDE.md files once the `worker-subagent` executor from ticket #15 follow-up lands (the current executor SKIPs unknown kinds). This PR intentionally does NOT edit `golden-cases.example.json` per the ticket's note about a pending operator edit.

## Risks / rollback

- **Risk: trimmed CLAUDE.md loses behavior that was only documented there.** Mitigation: every pointer section names the spec it links to; the specs already existed for every procedure except auto-dispatch test-discovery (which gets a new spec in this PR). Verified each section had a canonical destination before trimming.
- **Risk: a future PR adds content that legitimately belongs in CLAUDE.md (new worker type, new command) and trips the gate.** Mitigation: the ceiling has ~4k headroom above the post-trim size. A legitimate new routing row is ~100 chars. If a single PR adds more than 4k to the routing surface, that's a signal to reorganize, not to raise the ceiling.
- **Risk: the size-check script breaks on systems where `wc -c` counts bytes differently (macOS vs. GNU).** Mitigation: both count bytes the same for ASCII, and CLAUDE.md is ASCII. If a future contributor adds multi-byte content, the bigger signal is that CLAUDE.md is doing too much.

**Rollback:** revert the PR. The trim, the script, and the `validate-state-all.sh` wire-in are all in one PR, and reverting puts CLAUDE.md back to its prior 40k state without other side effects. Commander's observable behavior is unchanged either way.

## Implementation notes

- Pre-trim size: 40,758 chars. Post-trim size: 15,336 chars (2,664 chars of headroom under the 18,000 ceiling).
- Auto-dispatch test-discovery got its own new spec at `docs/specs/2026-04-17-auto-dispatch-test-discovery.md` because the behavior wasn't previously specced anywhere else.
- `scripts/check-claude-md-size.sh` + `scripts/test-check-claude-md-size.sh` landed in the same PR as the trim. The test covers over/under threshold, env override, flag-beats-env, missing file, non-integer `--max`, and the `validate-state-all.sh` integration path (both pass and fail).
- Top cited specs from the new pointers: `worker-timeout-watchdog`, `review-worker-rescue`, `scheduled-autopickup`, `autopickup-default-on`, `scheduled-retro`, `retro-workflow`, `mcp-agent-interface`, `supervisor-escalate-client`, `per-repo-merge-policy`, `state-schemas`, `auto-dispatch-test-discovery`.
- Intentionally NOT edited: `self-test/golden-cases.example.json` (pending operator edit per ticket #138 note). Follow-up ticket proposal: add a dedicated `claudemd-size-guard` golden case once the `worker-subagent` executor from ticket #15 follow-up lands.
