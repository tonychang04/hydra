---
status: draft
date: 2026-04-17
author: hydra worker (issue #96)
---

# Codex as a Hydra worker backend (dual-backend implementation)

**Ticket:** [#96](https://github.com/tonychang04/hydra/issues/96)
**Tier:** T2
**Status:** Scaffold-only for this ticket. The infrastructure ships now; routing logic that picks between backends is out of scope (see "Out of scope" and follow-up ticket [#97]).

## Problem

Today every Hydra worker is Claude Code. `.claude/agents/worker-implementation.md` is the only implementation backend, and commander's spawn step (`CLAUDE.md` "Operating loop" step 5) only knows how to invoke it. That means:

- **Single-point rate-limit exposure.** When Claude hits a quota wall, the whole ticket queue stalls. The "18-minute stream-idle timeout" watchdog (see `scripts/rescue-worker.sh`) catches the individual-worker failure mode, but can't rescue us from the systemic one.
- **No cost/speed arbitrage.** Some tickets (e.g. mechanical refactors) are cheaper / faster on Codex; some (architecture-heavy work) play to Claude's strengths. Today we have no way to route.
- **No second-opinion primitive.** Spawning both backends on the same ticket and diffing the PRs is a natural follow-on, but only once dual-backend works at all.
- **Zero resilience to upstream changes.** If Anthropic's API has an outage or a breaking change to the Agent SDK, commander stops shipping. A second backend is defense in depth.

Codex is already on the review path (`/codex review` is invoked inside `worker-review`), so the operator's local environment has a working `codex` CLI — at least partially. It currently fails with `gpt-5.2-codex model is not supported when using Codex with a ChatGPT account`, which is an **environmental / account-tier issue, not a Hydra bug**. This spec ships the infrastructure so the moment the operator's `codex` CLI works (API-key setup OR account upgrade), backends are flippable per-repo with zero additional Hydra work.

## Goals

1. A new worker subagent type `worker-codex-implementation` that orchestrates ticket work the same way `worker-implementation` does (spec-first, PR output contract, ticket-source update) but shells out to `codex exec` for the actual code-gen step.
2. A thin shell wrapper `scripts/hydra-codex-exec.sh` that takes a ticket prompt + worktree path, invokes `codex exec`, captures the diff, applies it, and returns a well-defined exit code. Fail-loud on unavailability — no silent fallback.
3. Additive schema change on `state/repos.json`: optional `preferred_backend: "claude" | "codex" | "auto"` field, default `"claude"`. Zero back-compat break — existing `repos.json` files continue to work unchanged.
4. A script-kind self-test that exercises the wrapper against a stubbed `codex` binary so we can regress the wrapper's plumbing without burning real Codex quota.
5. Operator-facing docs: `docs/phase2-vps-runbook.md` gains a "Configuring the Codex backend" section; `CLAUDE.md`'s "Worker types" table gains one row.

## Non-goals

- **Automatic rate-limit fallback** (Claude → Codex on quota exhaustion). Ticket [#97] covers the routing logic; this ticket ships the primitive it'll route on.
- **Second-opinion / dual-spawn** (both backends on the same ticket, diff PRs, pick winner). Future capability, unblocked by this ticket.
- **Fixing the operator's local `codex` CLI.** Documented as a known operator blocker below; this is an OpenAI account / Codex-CLI tier issue, not Hydra's problem.
- **Runtime CLI flag** (`pick up #42 --backend codex`). Default-per-repo is enough for v1. A future ticket can add the override.
- **`worker-codex-review` subagent.** Codex is already used on the review path via `/codex review`; that path is unchanged.
- **Migrating existing `worker-implementation` callers** to the new router. Commander keeps defaulting to Claude until [#97] wires routing.

## Proposed approach

### Transport (how codex is invoked from inside a Claude subagent)

The Agent runtime stays Claude. The `worker-codex-implementation` subagent is a **Claude subagent that orchestrates** (read ticket, write spec, open PR, handle git + gh, call commander's memory) and **delegates the raw code-gen step to `codex exec`** via `scripts/hydra-codex-exec.sh`. This is the same shape as `worker-review` today, which runs a Claude subagent that calls `/codex review` for the adversarial second opinion.

Rationale: orchestration logic is complex and repo-specific (memory citations, PR body format, label REST-API dance, commander handshake). Rewriting that in a second SDK to spawn a pure-Codex worker doubles the surface area. Delegating just the code-gen step keeps one orchestrator and makes Codex swappable for any headless code-gen CLI later (e.g. `aider`, a future local model).

### `codex exec` invocation contract

The wrapper script invokes:

```
codex exec --cd "$worktree" "$task_prompt"
```

- `--cd` sets Codex's working directory so its file references match the worktree.
- `$task_prompt` is the ticket body summary + any constraints the orchestrator wants to pass (forbidden paths, tier, etc.). **Not the full repo contents** — Codex discovers what it needs via its own tool loop.
- stdin is piped (not echoed) so the prompt never appears in shell history or commander logs.

Codex writes directly to the worktree (its default behavior on `exec`). After the call returns, the wrapper runs `git status --porcelain` inside the worktree to detect any changes and returns early if Codex wrote nothing (exit 2 — Codex exec failed or refused).

### Auth flow

Two codepaths, chosen by env vars present when the wrapper runs:

1. **`OPENAI_API_KEY` set** — API-key auth. Wrapper unsets any `CODEX_SESSION_*` vars so the ChatGPT-session path is not used, then invokes `codex exec`. This is the preferred path for headless / VPS runs.
2. **ChatGPT session auth** (via `codex login`'s persisted tokens under `~/.codex/`) — used when `OPENAI_API_KEY` is absent. This is the operator's current local setup, but it triggers the `gpt-5.2-codex is not supported when using Codex with a ChatGPT account` error. Wrapper detects the 400-series rejection in stderr and returns exit 4 (`codex-unavailable`), not 2, so commander can label `commander-stuck` with a specific reason.

**Security:** the wrapper **never echoes `OPENAI_API_KEY` or any session token to stdout/stderr or logs**. The prompt is piped via stdin. On failure, stderr is captured to a tmpfile and grep'd for a small allow-list of known patterns (quota, model-not-supported, network) before surfacing a sanitized line to commander — the full tmpfile is unlinked on exit.

### Output parsing

`codex exec` writes changes directly to the filesystem — no "parse the diff out of stdout" step. The wrapper:

1. Snapshots `git rev-parse HEAD` before invoking Codex.
2. Invokes `codex exec`.
3. If Codex exits non-zero, wrapper returns the appropriate exit code (see below) — no diff applied.
4. If Codex exits 0 but `git status --porcelain` is empty, wrapper returns exit 2 — Codex refused or produced nothing.
5. Otherwise the worktree now has pending changes ready for the orchestrator subagent to commit + test.

This keeps the wrapper thin (≤100 LOC) and pushes commit / test / PR responsibility back to the orchestrator — same as `worker-implementation`.

### Error handling and exit codes

Deterministic, documented, used by the orchestrator subagent to decide "retry vs. stuck":

| Exit | Name | Meaning | Orchestrator action |
|------|------|---------|---------------------|
| 0 | success | Codex ran, produced changes | proceed with commit + test + PR |
| 1 | bad-args / no codex | Wrapper args malformed, or `codex` CLI not on PATH | escalate to commander; operator config issue |
| 2 | codex-exec-failed | Codex ran but errored or produced zero changes | escalate; worth a retry once |
| 3 | diff-apply-failed | Reserved for future (we let Codex apply; the wrapper verifies). Unused today. | escalate; treat as infra bug |
| 4 | codex-unavailable | Rate-limit, auth failure, or model-not-supported | label `commander-stuck` with codex-unavailable reason; **do NOT silently fall back to Claude** |

The explicit `4` exit code matters because the ticket acceptance specifically calls out: "fallback path (codex unavailable → commander-stuck with clear reason, NOT silent switch to Claude) is deterministic." The silent-fallback route would mask rate-limit signals that commander needs for the future routing logic in [#97].

### Per-repo routing (schema change only for this ticket)

`state/schemas/repos.schema.json` gains an optional `preferred_backend` field:

```json
"preferred_backend": {
  "type": "string",
  "enum": ["claude", "codex", "auto"],
  "default": "claude",
  "description": "Which worker backend to spawn for this repo. claude = worker-implementation (default). codex = worker-codex-implementation. auto = future routing logic (ticket #97) — currently treated as claude."
}
```

The field is **additive**: missing = default `"claude"`. Back-compat is preserved — no live `state/repos.json` will break. Commander's spawn logic continues to default to `worker-implementation` until [#97] lands and teaches it to read this field. The schema change alone is enough for this ticket.

### Self-test strategy

A script-kind self-test `codex-worker-fixture` runs `hydra-codex-exec.sh` against a **stubbed `codex` binary** — a shell script placed in a fixture `bin/` directory, prepended to `$PATH` for the duration of the test, that emits a fixed diff (writes a single file to the worktree). This validates:

- Wrapper argument parsing
- Worktree `--cd` threading
- Dirty-check (`git status --porcelain`) after stub runs
- Exit-0 path when stub succeeds
- Exit-2 path when stub produces no changes
- Exit-1 path when `codex` is not on PATH
- Exit-4 path when stub emits a model-not-supported error

The self-test is **SKIP'd unless `HYDRA_TEST_CODEX_E2E=1` is set**. That env flag is for the separate optional end-to-end test that hits the real `codex` CLI — it's expensive, non-deterministic, and needs a working codex env. The stubbed-binary variant still runs in CI because it only exercises the wrapper's plumbing against a deterministic fake. The `HYDRA_TEST_CODEX_E2E` gate exists so operators with a working codex env can opt into a real end-to-end smoke by setting the env var.

### Known operator blocker (documented, not fixed here)

The operator's local `codex` CLI fails today with:

```
gpt-5.2-codex model is not supported when using Codex with a ChatGPT account
```

This is **not a Hydra bug**. It's a Codex-CLI + OpenAI-account-tier issue. Resolution path (operator side):

1. **API-key setup** — `export OPENAI_API_KEY=sk-...`, unset any persisted `codex login` state. The wrapper prefers this when present.
2. **Account upgrade** — switch off ChatGPT-account auth to a tier that supports `gpt-5.2-codex`.

The ticket ships the infrastructure anyway so when the operator resolves their side, flipping a repo's `preferred_backend` from `claude` to `codex` is the only Hydra-side change needed.

## Alternatives considered

1. **Pure-Codex worker (no Claude orchestrator).** Would require re-implementing orchestration (memory handshake, spec-first commit, PR body shape, label REST dance, commander-question escalation) in a second SDK. Doubles the surface area and guarantees drift between the two implementations. Rejected.

2. **Silent fallback from Codex to Claude on failure.** Easier UX but masks rate-limit signals that commander's future routing ([#97]) needs to reason about provider health. Also violates the ticket's explicit "deterministic, not silent" requirement. Rejected.

3. **Runtime `--backend codex` CLI flag.** Would let the operator override per-spawn. Nice to have but not needed for v1 — `preferred_backend` per-repo is sufficient, and adding the flag later is a ~10-LOC change. YAGNI for now.

4. **Parse diff out of Codex stdout and `git apply` it.** Would let us run Codex in a more sandboxed way (read-only filesystem, apply diff ourselves). But `codex exec` is designed to write directly; fighting that is more code than it's worth for a v1 that's already scoped down. If future security constraints demand it, we revisit. Rejected for now.

## Test plan

1. `bash -n scripts/hydra-codex-exec.sh` — syntax clean.
2. `./self-test/run.sh --case codex-worker-fixture` — wrapper behaves correctly against stub binary (exit 0 / 1 / 2 / 4 paths).
3. `scripts/validate-state.sh state/repos.json` — existing `repos.json` files still pass schema validation with the additive `preferred_backend` field.
4. CI: `syntax-check.sh`, `spec-presence-check.sh`, `self-test/run.sh --kind=script` — all green.
5. Manual (optional, operator-env-dependent): `HYDRA_TEST_CODEX_E2E=1 ./self-test/run.sh --case codex-worker-fixture-e2e` against a real `codex` install — skipped on the CI bot because it has no `codex` installed.

## Risks and rollback

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Wrapper leaks `OPENAI_API_KEY` to logs | Low — by design, stdin-piped; but regression-prone | Self-test case asserts no env-var substring appears in captured stderr of the stub run; code review focus on the `set -x` absence. |
| `codex exec` CLI contract changes upstream | Medium — Codex is pre-GA | Wrapper is ≤100 LOC; when the CLI shape changes, update the one invocation line. No second subagent rewrite needed. |
| Schema change breaks an old `state/repos.json` | Low — additive field with default | `validate-state.sh` in preflight catches any issue; rollback is deleting the schema line. |
| `worker-codex-implementation` is spawned but Codex is unavailable in operator env | High — this is the current state of the world | Exit 4 + `commander-stuck` label with a clear reason; no silent fallback. Operator sees "codex-unavailable" and knows to either fix their env or flip `preferred_backend` back to `claude`. |
| Follow-up ticket [#97] never ships, leaving this infra idle | Medium | The schema field defaults to `claude`; commander ignores it until [#97]. Worst case: this ticket's PR sits dormant — no harm to existing flows. |

**Rollback:** revert the PR. The schema change is additive (no data migration), the subagent file is new (no callers yet), the wrapper is new (no callers yet), and the CLAUDE.md row is additive. Zero data loss.

## References

- Ticket [#96](https://github.com/tonychang04/hydra/issues/96) — this work
- Ticket [#97] — follow-up rate-limit fallback routing (opens after #96 lands)
- `.claude/agents/worker-implementation.md` — shape the new subagent mirrors
- `.claude/agents/worker-review.md` — precedent for "Claude subagent that shells out to `codex`"
- `scripts/hydra-doctor.sh` — shell-script style guide (set -euo pipefail, --help format, exit-code table)
- `docs/specs/2026-04-16-state-schemas.md` — schema-validation framework for the `state/repos.json` change
