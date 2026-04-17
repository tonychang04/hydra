---
status: draft
date: 2026-04-16
author: hydra worker (issue #51)
---

# Dual-mode workflow (local + cloud) + self-tests for MCP and Fly.io

Implements: ticket #51 (T2). Ties together #48 (Fly.io POC, merged) and #50 (MCP agent interface, merged).

## Problem

Two large Phase 2 primitives just landed on main:

1. **#48 (Fly.io VPS deployment)** — `infra/Dockerfile`, `infra/fly.toml`, `infra/entrypoint.sh`, `scripts/deploy-vps.sh`. Lets Commander run headless on a cheap cloud VM instead of a laptop terminal.
2. **#50 (MCP agent interface)** — `mcp/hydra-tools.json`, `docs/mcp-tool-contract.md`, `state/connectors/mcp.json.example`. Lets agents (not humans) drive Commander over the Model Context Protocol.

Both landed correctly, but the docs and self-test harness are now out of date. Specifically:

- **USING.md** describes only the local-mode terminal-chat workflow (`claude`, `pick up 2`, etc.). No mention that the same framework ships a headless cloud variant.
- **README.md** Mermaid diagram was updated in-flight with "Main Agent" boxes, but there's still no visual cue that *Commander itself* can live in two places (laptop vs. VPS). Operators reading the README can't tell there's a cloud-mode option without digging into INSTALL.md § Phase 2.
- **INSTALL.md** already has three separate paragraphs for the three install paths — one-liner, manual, and agent-driven-via-MCP — but the three paths aren't labeled (A / B / C) and the visual structure mixes them. A reader scanning INSTALL.md sees "Option A" then a pile of text and only later spots Option C buried mid-file.
- **Self-test harness** has golden cases for most framework pieces (autopickup, hydra-cli, hydra-doctor, linear-poll, memory-validators, release, self-test-runner, hydra-operator skill, s3-backend). But the MCP primitives (tool schemas, connector config) and Fly.io primitives (Dockerfile, fly.toml, entrypoint, deploy script) have **zero** regression coverage. A future edit to `mcp/hydra-tools.json` that breaks the schema, or a `fly.toml` that stops parsing, or an `entrypoint.sh` that silently loses its auth-required guard — none of these would be caught by `self-test` or CI before a merge.

The ticket body calls out six deliverables: (1) workflow docs clearly separating local vs cloud, (2) five new self-test cases, (3) a cloud-mode smoke script, (4) a local-mode smoke script, (5) a memory-lifecycle update for supervisor-vs-operator citation provenance, (6) Mermaid diagram updates. Each deliverable is independently useful; together they make the dual-mode story readable and the dual-mode primitives defensible against regression.

## Goals

- **USING.md** has two clearly-separated top-level sections: "Local mode" (today's default — terminal chat on a laptop) and "Cloud mode" (Fly.io + agent-driven via MCP). Each section stands alone — an operator who only cares about one mode reads only that section.
- **README.md** Mermaid diagrams visually show Commander can run in either place (laptop *or* VPS) and the Main Agent reaches it either way (local in-process *or* MCP over network). Existing diagrams are preserved; edits are additive.
- **INSTALL.md** has three clearly-labeled install paths: **Option A** (one-liner local), **Option B** (manual local), **Option C** (cloud + MCP, agent-driven). Already close to this shape — this ticket finishes the labeling and adds a signpost at the top.
- **Five new self-test cases** in `self-test/golden-cases.example.json`, appended at the bottom to avoid merge conflicts with #45's worker (which also appends one case):
  - `mcp-tool-contract-valid` — validates `mcp/hydra-tools.json` has every tool fully declared.
  - `mcp-config-example-valid` — validates `state/connectors/mcp.json.example` has required fields.
  - `fly-toml-valid` — runs `fly config validate --config infra/fly.toml`, gracefully skips if flyctl isn't installed.
  - `dockerfile-lintable` — runs `hadolint infra/Dockerfile`, gracefully skips if hadolint isn't installed. Docker's own `--check` isn't a real linter on older Docker, so hadolint is the only reliable path; otherwise skip.
  - `entrypoint-idempotent` — runs `infra/entrypoint.sh` with both auth env vars unset, verifies it fails loudly (exit code != 0 + error message about CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY).
- **`scripts/test-cloud-config.sh`** — validates cloud deployment artifacts without deploying. Uses: `fly config validate`, `docker build --no-cache` (if docker available), `shellcheck` (if available), `jq .` on the two JSON config files, `bash -n` on every shell script under `scripts/` + `infra/`. Exit 0 iff every available check passed. Intended for CI and operator pre-push sanity.
- **`scripts/test-local-config.sh`** — validates local install artifacts. Uses: `./setup.sh` against a tmp HYDRA_ROOT (respects the `requires_claude_cli` skip convention used by `autopickup-default-on-smoke`), verifies generated `.hydra.env` has required vars, verifies `state/repos.json` is valid JSON after the copy, verifies `./hydra` launcher exists + executable + syntactically clean. Exit 0 iff all checks pass.
- **Memory lifecycle update** — when Commander resolves a worker's `QUESTION:` via the supervisor agent, the resulting citation entry records `"source": "supervisor"`. When the legacy direct-chat path answers the same question, the entry records `"source": "operator"`. Schema in `state/schemas/memory-citations.schema.json` gains an optional `source` field with `enum: ["operator", "supervisor"]`. CLAUDE.md's citation-schema reference gains one sentence pointing at the field. No breaking change — existing entries without `source` are treated as `"operator"` (legacy).

## Non-goals

- **Not rewriting what #48 or #50 already shipped.** `mcp/hydra-tools.json`, `docs/mcp-tool-contract.md`, `state/connectors/mcp.json.example`, `infra/Dockerfile`, `infra/fly.toml`, `infra/entrypoint.sh`, `scripts/deploy-vps.sh` — all unchanged by this PR. This ticket layers docs, tests, and a memory-lifecycle tweak on top of the already-merged primitives.
- **Not adding new Mermaid diagrams from scratch.** The existing two diagrams in README.md already cover "the loop" and "inside one iteration". This ticket extends them with a small side-by-side panel showing local vs cloud deployment topology — it does NOT replace either existing diagram.
- **Not implementing the MCP server binary.** That's still a follow-up from #50's own non-goals. The `mcp-tool-contract-valid` self-test validates the schema file only — nothing is wired to actually serve tools yet.
- **Not changing tier policy or merge policy.** No edits to `policy.md`, no new refusal rules. T3 is still T3.
- **Not adding new external dependencies.** `shellcheck` and `hadolint` are optional in the smoke scripts and self-test cases; both skip gracefully if absent. No new `apt install` / `brew install` step is added to `setup.sh` or the Dockerfile.
- **Not backfilling `"source": "supervisor"` into existing citations.** The schema change is forward-only. Old entries stay as-is; new citations produced after this PR lands carry the source tag.

## Proposed approach

Four kinds of artifact, each independently reviewable:

### 1. Docs restructure (USING.md / README.md / INSTALL.md)

- **USING.md** grows a two-heading top: `## Local mode (terminal chat, default)` wraps the existing content. `## Cloud mode (Fly.io + MCP, agent-driven)` is net-new. The cloud-mode section is short — a pointer to INSTALL.md Option C for setup, plus a 6-line walkthrough showing `./scripts/deploy-vps.sh` → `fly ssh console` → `gh issue` → webhook → PR. The existing "Launching a session" / "Dispatching a ticket" / "Daily operations" remain under Local mode. "Self-testing" / "Linear" / "Phase-2 end state" remain shared bottom sections.
- **README.md** Mermaid — the existing "The loop" diagram is extended. Currently the `Commander` node sits alone; the edit adds a `subgraph LocalMode` vs `subgraph CloudMode` framing with Commander rendered in both subgraphs, connected to the Main Agent via MCP in both cases. The "Inside one iteration" diagram is untouched (it's about ticket flow, not deployment topology).
- **INSTALL.md** — sections already titled "Option A", "Option B", "Option C" at lines 24 / 38 / 50. This ticket's edit is cosmetic: add a one-line section above them ("Three install paths: A = one-liner local, B = manual local, C = cloud + MCP. Most operators want A.") so a skimming reader immediately knows what the three options even are.

### 2. Self-test golden cases (appended, conflict-safe)

Each case is `kind: script` — runs a sequence of shell commands, asserts exit codes and optional stdout/stderr. Appended to the `cases[]` array bottom; the ticket body explicitly flags #45's worker is also appending one case and the conflict-resolver handles additive cases cleanly.

- **`mcp-tool-contract-valid`** — steps: (1) `jq empty mcp/hydra-tools.json` (valid JSON), (2) count tools, assert 13, (3) assert every tool has `name / description / scope / input_schema / output_schema`, (4) assert every `scope` is in `{read, spawn, merge, admin}`. Total ~4 steps.
- **`mcp-config-example-valid`** — steps: (1) `jq empty state/connectors/mcp.json.example`, (2) assert `.server.enabled` is a boolean, (3) assert `.authorized_agents` is an array, (4) assert `.upstream_supervisor` is present. Total ~4 steps.
- **`fly-toml-valid`** — `requires: [requires_flyctl]`. Step: `fly config validate --config infra/fly.toml`. Skips if flyctl not on PATH (consistent with the `requires_docker` / `requires_aws` / `requires_claude_cli` pattern already in `self-test/run.sh`). We add `requires_flyctl` to the runner's known-tokens list; unknown tokens are "satisfied" today, but declaring it makes the intent explicit and future-proofs the runner.
- **`dockerfile-lintable`** — `requires: [requires_hadolint]`. Step: `hadolint infra/Dockerfile`. Skips gracefully. `docker build --check` was mentioned in the ticket body as a fallback, but it only exists in newer Docker; we stick with hadolint to keep the case deterministic.
- **`entrypoint-idempotent`** — steps: (1) `bash -n infra/entrypoint.sh` (syntax), (2) `infra/entrypoint.sh --help` exits 0 and prints usage, (3) `env -i HOME=$HOME PATH=$PATH bash infra/entrypoint.sh` (cleared env) exits NON-zero with stderr containing "CLAUDE_CODE_OAUTH_TOKEN" — proves the fail-loud guard works. The step uses `env -i` to nuke the worker's env rather than risk passing through inherited tokens from the test host.

Each `requires_*` token the runner doesn't already know is "assumed satisfied" (forward-compat). We add explicit handling for `requires_flyctl` and `requires_hadolint` so skip messages are informative.

### 3. Cloud + local smoke scripts

Both scripts live under `scripts/` next to the existing `hydra-doctor.sh`, `release.sh`, etc. Each follows the house style:

- `set -euo pipefail`
- `usage()` function with `--help` support
- Color + `say / ok / warn / fail` helpers consistent with `deploy-vps.sh` and `setup.sh`
- Iterate checks; each check is "skip if prereq missing, else run". Collect failures and exit 1 at the end iff any check failed.

`scripts/test-cloud-config.sh` checks:
- `fly config validate --config infra/fly.toml` (skip if no flyctl)
- `docker build infra/ -t hydra-test --no-cache` (skip if no docker OR if `HYDRA_CI_SKIP_DOCKER=1` set — same env var used by `self-test/run.sh`)
- `shellcheck scripts/deploy-vps.sh infra/entrypoint.sh` (skip if no shellcheck)
- `jq empty state/connectors/mcp.json.example mcp/hydra-tools.json`
- `bash -n` on every `scripts/*.sh` and `infra/*.sh`

`scripts/test-local-config.sh` checks:
- `./setup.sh` against a tmp `HYDRA_ROOT` (created by copying the worktree, with a mocked external memory dir). Requires `claude` CLI because `setup.sh` hard-fails without it; skip with a clear message if not present.
- Generated `.hydra.env` has `HYDRA_ROOT`, `HYDRA_EXTERNAL_MEMORY_DIR`, `COMMANDER_ROOT` exported.
- `jq empty state/repos.json` (valid JSON after the template copy).
- `./hydra` launcher exists, is executable, `bash -n ./hydra` clean.

Both scripts are safe to run in CI (they're just runners for the same checks already scattered across existing self-test cases, bundled for one-shot operator use). CI does NOT invoke them — it invokes `./self-test/run.sh --kind=script`, which picks up the same cases.

### 4. Memory-lifecycle update (citation provenance)

Three small edits:

- `state/schemas/memory-citations.schema.json` — citation entry gains `"source": { "type": "string", "enum": ["operator", "supervisor"] }`. Optional; absence means legacy ("operator").
- `CLAUDE.md` — the "State files" or "Memory hygiene" section gets one new sentence: when the supervisor agent resolves a `QUESTION:`, Commander writes `"source": "supervisor"` on the resulting citation entry. (This is already implicitly true under #50's escalation flow; this PR just makes the provenance legible.)
- `state/memory-citations.example.json` — one example entry gets an explicit `"source": "supervisor"` so operators see the shape.

**Note:** editing CLAUDE.md triggers `spec-presence-check.sh`. This spec file is exactly what unblocks that check — the PR will include both the CLAUDE.md one-line addition AND this spec, so the check passes.

### Alternatives considered

- **Rewrite the USING.md end-to-end with a unified "modes" narrative.** Rejected: the ticket body explicitly says "preserve existing Mermaid diagrams; extend, don't replace". Same principle for prose. A top-of-doc mode selector + clear headings is enough; ripping apart the existing walkthrough would just cause merge conflicts with other in-flight docs tickets.
- **Inline the smoke checks into `hydra-doctor.sh` instead of two new scripts.** Rejected: `hydra-doctor` is for *install sanity* of an operator's live setup, not for validating deploy artifacts before shipping. The audiences differ — a CI runner wants `test-cloud-config.sh`; an operator with a broken setup wants `hydra-doctor`. Keeping them separate keeps each focused.
- **Add the new `requires_*` tokens to the self-test runner silently via the unknown-token fallback.** Rejected: the runner's `check_requires` function treats unknown tokens as satisfied, which is correct for forward-compat but silent-satisfied is exactly wrong for flyctl / hadolint — if the operator doesn't have them, the case should SKIP with a readable message, not pretend-pass. Explicit handling is five extra lines and avoids the landmine.
- **Make `scripts/test-cloud-config.sh` try to actually `fly deploy` to a staging app.** Rejected: side-effecting deploys in a smoke script is a foot-gun. The word "smoke" in the filename sets the expectation — artifacts parse, syntax is clean, docker build succeeds. Deploy is a separate operator action.
- **Add `"source": "operator"` to every existing citation entry for consistency.** Rejected: destructive migration for a cosmetic field. Absence-means-legacy is simpler and safer.

## Test plan

Every deliverable has at least one concrete check:

- **USING.md / README.md / INSTALL.md edits** — manual read-through after edit. CI's conflict-marker check catches the obvious mistake (leftover `<<<<<<<` from the conflict-resolver). Mermaid diagram renders via `gh` preview on the draft PR; if the block is malformed, GitHub shows a "Unable to render rich display" error.
- **5 new self-test cases** — run `./self-test/run.sh --kind=script` locally; all 5 new cases should appear as ✓ (passed) or ∅ (skipped due to missing optional tool). CI also runs this via `.github/workflows/ci.yml` → `./self-test/run.sh --kind=script`. Script-kind cases are deterministic and fast (<5s each).
- **`scripts/test-cloud-config.sh`** — run locally with and without `HYDRA_CI_SKIP_DOCKER=1`. Expected: exit 0 in both modes. Run with `bash -n` to confirm syntax clean.
- **`scripts/test-local-config.sh`** — run against a temp directory. Expected: exit 0, ends with "all checks passed". If `claude` isn't on PATH, the case skips gracefully (consistent with `autopickup-default-on-smoke` + `requires_claude_cli`).
- **Memory-lifecycle edits** — `jq empty state/schemas/memory-citations.schema.json` after the edit confirms valid JSON. Example file gets `jq empty` too. CLAUDE.md edit is prose; caught by review.

CI already runs: `bash -n` on all shell scripts (catches syntax breaks), `jq empty` on JSON files (catches malformed JSON), `./self-test/run.sh --kind=script` (catches the new cases). No new CI job needed — this ticket rides the existing harness.

## Risks / rollback

- **Risk: `fly-toml-valid` case fails in CI because flyctl isn't installed.** Mitigated by `requires_flyctl` → SKIP. The CI runner doesn't install flyctl, the case skips, green CI preserved. Operator running locally with flyctl installed gets real validation.
- **Risk: `entrypoint-idempotent` case leaks env from the test host into the `env -i`-cleared environment.** Mitigated by explicitly passing only `HOME` + `PATH` (no auth tokens). The test specifically asserts the script exits non-zero WITH stderr mentioning the missing var, so a spurious inherited token would be caught as a flipped test verdict.
- **Risk: `test-local-config.sh` interferes with the operator's live `.hydra.env` by running `./setup.sh` without scoping.** Mitigated: the script creates a tmp directory, copies the worktree into it, and runs `setup.sh` there. The live worktree is never touched. If the tmp scoping fails, `setup.sh` refuses to clobber existing files anyway (it's idempotent with "already exists — leaving as-is" branches on every write).
- **Risk: the Mermaid diagram edit in README.md breaks rendering.** Mitigated: the edit is additive (wraps existing nodes in `subgraph ... end` blocks) and tested by viewing the draft PR preview. If rendering breaks, revert the Mermaid block and re-do with simpler edits.
- **Rollback:** every change in this PR is additive (new files or new content in existing files). `git revert` the merge commit cleanly undoes everything. No data migration, no state file rewrites, no secret rotations.

## Implementation notes

(To be filled in after merge.)

### Coordinating with parallel workers

- Another worker is appending 1 self-test case for ticket #45. This ticket appends 5. Both workers append; conflict-resolver merges them additively.
- Another worker is adding a comparison table to README.md near the top. This ticket's Mermaid edit is the existing mermaid block at line ~54. The two edits are in different parts of the file; no conflict expected. If the other worker's table pushes the mermaid block down, line numbers change but the Edit tool's anchored match-old-string approach handles it.

### Follow-ups to file once this lands

- **`mcp-server-binary-smoke`** (follow-up of #50) — once the MCP server binary ships, add a live case that spawns the server, makes a `hydra.get_status` call via stdio, asserts the response shape. Today we can only validate the schema file.
- **`fly-deploy-dryrun`** — when flyctl grows a `--dry-run` mode for `fly deploy`, wire it into a new self-test case so `scripts/deploy-vps.sh` is exercised end-to-end without side effects.
- **Citation provenance retro** — once 10+ supervisor-resolved citations accumulate in real memory, add a retro-level check: what fraction of `source: supervisor` citations came from genuinely novel questions vs. near-misses that the memory fuzzy-matcher should have caught?
