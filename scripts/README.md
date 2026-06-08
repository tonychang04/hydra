# Commander helper scripts

These are **helper scripts invoked by Commander during memory lifecycle operations + state preflight** (see `memory/memory-lifecycle.md`). They are not standalone tools — Commander calls them from its operating loop and merges / interprets their output.

## Overview

| Script | Who calls it | Purpose |
|---|---|---|
| `parse-citations.sh` | Commander, after every worker report comes back | Extract `MEMORY_CITED:` markers from a worker report and emit a JSON delta that Commander merges into `state/memory-citations.json` |
| `build-memory-brief.sh` | Commander, as the spawn pre-step for `worker-implementation` / `worker-codex-implementation` / `worker-test-discovery` | Compile a ≤ 2000-byte repo-scoped memory brief: top-5 repo learnings by citation count + top-3 cross-repo patterns (last 30 days) + scoped escalation-faq entries + the latest retro's citation-leaderboard excerpt. Commander prepends output under a `# Memory Brief` H1 before the ticket body. Closes the open citation feedback loop so workers start with preloaded memory rather than re-discovering every time. Spec: `docs/specs/2026-04-17-memory-preloading.md`. |
| `validate-learning-entry.sh` | Commander, before appending/committing a learnings file; pre-commit hook material | Sanity-check a `learnings-<repo>.md` file against the schema (frontmatter keys, section headings, line length, date format) |
| `test-validate-learning-entry.sh` | Operator pre-push, or CI | Regression test for `validate-learning-entry.sh` (28 assertions). Pins the schema contract: valid entry → exit 0; missing/unclosed frontmatter, each missing required key (`name`/`description`/`type`), no expected section heading, an over-1500-char line, invalid month, invalid day → exit 1; the all-errors-reported-in-one-shot behavior; `--memory-dir` relative-path resolution; missing-file / unknown-flag / no-argument → exit 2; `--help` → exit 0. No fixtures outside `mktemp`. Spec: `docs/specs/2026-06-08-test-validate-learning-entry.md`. |
| `validate-citations.sh` | Commander, during `compact memory` / `promote learnings` hygiene passes | Walk `state/memory-citations.json`, check every citation quote still exists in its referenced file. Flags stale references that need cleanup. |
| `promote-citations.sh` | Commander, once per day via the autopickup tick (and on operator `promote learnings`) | Scan `state/memory-citations.json` for entries where `count >= 3` AND `len(unique(tickets)) >= 3`. For each eligible entry, draft `.claude/skills/<slug>/SKILL.md` in the target repo (from `repos.json:repos[]` whose name matches the `learnings-<slug>.md` basename) and open a draft PR labeled `commander-skill-promotion`. Idempotent on re-run: existing skills get their citations block updated in place, never clobbered outside the `<!-- hydra:citations-* -->` markers. `--dry-run` prints the plan without git/gh side effects. Spec: `docs/specs/2026-04-17-skill-promotion-automation.md` (ticket #145). |
| `test-promote-citations.sh` | Operator pre-push, or CI | Regression test for `promote-citations.sh`. Eight dry-run cases: threshold gate (3 cites × 3 tickets), distinct-tickets dedup, `--only` filter, idempotent re-author, missing-citations-file no-op, usage errors, cross-cutting-file skip, slug disambiguation. No fixtures outside `mktemp`. |
| `validate-state.sh` | Commander, before reading any `state/*.json` file (and the Preflight step of every spawn — see CLAUDE.md). Pre-commit hook material for contributors editing state files. | Validate one `state/*.json` against its schema under `state/schemas/*.schema.json`. Minimal bash+jq path by default (required-keys check); delegates to `ajv-cli` when available for full Draft-07 validation (types, enums, patterns, ranges). `--strict` forces the ajv path. Flags `--schema <file>` / `--schema-dir <dir>` override auto-detection so fixtures don't need duplicated schemas. |
| `validate-state-all.sh` | Commander, as the first preflight item before any spawn | Bulk-validate every known `state/*.json` against its schema in one pass. Iterates `state/schemas/*.schema.json`, skips state files that don't exist yet, reports every failure in one summary (does NOT short-circuit). Same `--strict` semantics as the per-file script. The summary line reports **which validator ran** — `[validator: ajv strict]` (full Draft-07: enums, oneOf, patterns) or `[validator: bash+jq fallback]` (required-top-level-keys only) — and emits a `WARN` when the weak fallback ran, so a fallback PASS is never mistaken for a strict PASS (ticket #249). The authoritative ajv-strict check runs in CI (`state-validation-strict` job); local may fall back but always says so. Also runs `check-claude-md-size.sh` as a first-class preflight item — see that row. |
| `check-claude-md-size.sh` | Commander, invoked from `validate-state-all.sh` as part of preflight | Enforce the CLAUDE.md character budget (default 18000; override via `--max` or `HYDRA_CLAUDEMD_MAX`). Exit 1 if over, with the top 5 H2 sections printed as trim candidates. Keeps CLAUDE.md to routing + hard rails + spec pointers; full procedures belong in `docs/specs/`. Spec: `docs/specs/2026-04-17-claudemd-size-guard.md`. |
| `test-check-claude-md-size.sh` | Operator pre-push, or CI | Regression test for `check-claude-md-size.sh`. Covers over/under threshold, env override, flag-beats-env, missing file, non-integer `--max`, and the `validate-state-all.sh` integration path. No fixtures outside `mktemp`. |
| `validate-evidence-table.sh` | `worker-review`, before posting a review comment | Enforce the evidence-based review gate (#196): the comment's EVIDENCE TABLE must mark a criterion `PASS` only when it carries concrete evidence (command+output / test+pass line / diff `file:line`). Exit 0 = every `PASS` has evidence; 1 = a `PASS` lacks evidence / illegal verdict / zero criteria; 2 = no table found. Reads stdin / `--file` / `--body`. Spec: `docs/specs/2026-05-21-evidence-based-review-gate.md`. |
| `test-validate-evidence-table.sh` | Operator pre-push, or CI | Regression test for `validate-evidence-table.sh`. Headline: a `PASS`-without-evidence review is rejected. Covers valid/invalid tables, placeholder evidence, `UNVERIFIED`/`FAIL` allowed-empty, illegal verdict, zero rows, missing header, stdin + `--file`, `trace:<id>` forward-compat (#197), escaped pipes. No fixtures outside `mktemp`. |
| `validate-security-findings.sh` | `worker-review`, before escalating a security finding on a security-adjacent PR | Enforce the adversarial/consensus review gate (#199): the comment's FINDINGS TABLE may mark a security finding `REPORTED` only when it `SURVIVED` the cross-family critic's kill mandate AND carries an empirical Oracle (PoC / failing test / repro). *Unanimity is not confidence.* Exit 0 = every `REPORTED` finding survived + has an oracle; 1 = a `REPORTED` finding lacks an oracle / was `REFUTED` / illegal verdict-or-disposition / zero findings; 2 = no table found. Reads stdin / `--file` / `--body`. Spec: `docs/specs/2026-05-21-adversarial-consensus-review.md`. |
| `test-validate-security-findings.sh` | Operator pre-push, or CI | Regression test for `validate-security-findings.sh` (28 assertions). Headline: a non-reproducible finding is DROPPED while a PoC-backed one is KEPT, and flipping the non-reproducible one to `REPORTED` is rejected. Covers placeholder oracle, `REPORTED`+`REFUTED`, the safe `DROPPED` paths, illegal verdict/disposition, zero rows, missing header, stdin + `--file`, escaped pipes, and coexistence with the #196 evidence table. No fixtures outside `mktemp`. |
| `retro-file-proposed-edits.sh` | Commander's retro procedure, as the last step after writing `memory/retros/<week>.md` | Parse the retro's `## Proposed edits` section and file one GitHub issue per bullet. Classifies tier (T1/T2 auto-file; T3 surfaces instead); picks target repo by first inline `owner/repo` slug (default `tonychang04/hydra`). Labels: `commander-ready`, `commander-auto-filed`, `commander-retro`, + tier. Idempotent by title match. `--dry-run` previews. Override `gh` via `HYDRA_GH` for tests. Spec: `docs/specs/2026-04-17-retro-auto-file.md`. |
| `test-retro-file-proposed-edits.sh` | Operator pre-push, or CI | Regression test for `retro-file-proposed-edits.sh`. Ten cases: empty section, T1/T2/T3 bullets, inline repo slug, idempotency, missing retro, mixed bullets, usage errors, `--dry-run`. All `gh` calls routed to an in-memory stub via `HYDRA_GH`. |
| `state-get.sh` / `state-put.sh` | Commander + any adapter call site | Read / write a logical state blob. Defaults to `state/<key>.json` (Phase 1). Flips to DynamoDB when `HYDRA_STATE_BACKEND=dynamodb` (Phase 2). Awscli + jq. |
| `memory-mount.sh` | Operator, once per host | Mount an S3 bucket at `$HYDRA_EXTERNAL_MEMORY_DIR` via `mount-s3`. Prints clear install instructions if mount-s3 isn't on PATH. `--dry-run` previews the invocation. |
| `hydra-mcp-serve.sh` | `./hydra mcp serve` dispatches here | Thin wrapper that validates prereqs and `exec`s `hydra-mcp-server.py`. See the MCP server section below. |
| `hydra-mcp-server.py` | `hydra-mcp-serve.sh` (not called directly) | The actual MCP server process. Python 3 stdlib only — no `pip install` needed. Serves the 13 tools from `mcp/hydra-tools.json` per the spec in `docs/specs/2026-04-17-mcp-server-binary.md`. |
| `hydra-mcp-register-agent.sh` | `./hydra mcp register-agent <id> [--rotate]` | Generate a 32-byte bearer token for a new MCP client agent, hash it with SHA-256 (token never touches disk), and append an entry to `state/connectors/mcp.json`. Prints the raw token to stdout exactly once. Atomic config update via tmpfile + `mv`. Spec: `docs/specs/2026-04-17-mcp-register-agent.md`. |
| `test-cloud-config.sh` | Operator pre-push, or CI | Validate cloud-mode deployment artifacts (`infra/fly.toml`, `infra/Dockerfile`, `infra/entrypoint.sh`, `scripts/deploy-vps.sh`, `mcp/hydra-tools.json`, `state/connectors/mcp.json.example`) without deploying. Skips individual checks gracefully if flyctl/docker/shellcheck are absent. Spec: `docs/specs/2026-04-16-dual-mode-workflow.md`. |
| `test-local-config.sh` | Operator pre-push, or CI | Validate local-mode install artifacts (`setup.sh`, `.hydra.env` template, `state/repos.json` seeding, `./hydra` launcher) by running the full install flow inside a mktemp'd tree. Never touches the live worktree. Same spec as above. |
| `linear-poll.sh` | `linear-pickup-dispatch.sh`, worker subagents via MCP | Thin wrapper over the Linear MCP `list_issues` tool. Emits a normalized JSON envelope regardless of whether the source is a live MCP call or a fixture file. Supports env-var tool-name overrides so operators whose Linear MCP install uses different names can retarget without editing the script. Contract: `docs/linear-tool-contract.md` (ticket #5). |
| `linear-pickup-dispatch.sh` | Commander's pickup loop, once per autopickup tick when any repo has `ticket_trigger: linear` | Reads `state/linear.json`, iterates configured teams, invokes `linear-poll.sh` per team, and filters out tickets already in a commander-managed Linear state (the Linear equivalent of GitHub's `commander-working` / `commander-stuck` labels). Emits a JSON array Commander feeds into `worker-implementation` spawn. Empty array on missing config or `enabled=false`. Spec: `docs/specs/2026-04-17-linear-ticket-trigger.md` (ticket #140). |
| `trace-append.sh` | A worker, at known points in its run (tool start/end, test run, the root `invoke_agent` span) | Append ONE span event to the worker's append-only session trace at `logs/traces/<ticket>.jsonl` (one JSON object per line). Vocabulary is OpenTelemetry GenAI semantic-convention attribute names (`gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.usage.*_tokens`, `error.type`). Duration-bearing spans emit `--phase start` then `--phase end` sharing one `span_id`; the analyzer pairs them. Echoes the `span_id` on stdout (reuse as `--parent-span-id`). Content attrs (`gen_ai.prompt` / `gen_ai.completion`) are dropped unless `--with-content` / `HYDRA_TRACE_CONTENT=1` (secrets hard-rail). bash + jq, no daemon. Spec: `docs/specs/2026-05-21-worker-session-trace.md` (ticket #197). |
| `trace-analyze.sh` | Operator/debug after a `commander-stuck` or rescue; future consumers cost #195 + watchdog #206 | jq analysis over a `logs/traces/<ticket>.jsonl`. Subcommands: `durations` (pair start/end → ms; half-open → `incomplete`, phase-less → `instant`), `errors` (spans with `error.type` set), `tools` (ordered `gen_ai.tool.name` sequence), `summary` (event/span/tool/error counts + wall-clock span). File arg or stdin; `--json` for machine output. Spec: `docs/specs/2026-05-21-worker-session-trace.md` (ticket #197). |
| `test-trace.sh` | Operator pre-push, or CI | Regression test for `trace-append.sh` + `trace-analyze.sh` (38 assertions). Covers append validity + required keys, start/end pairing, numeric token attrs, content gating (default-off + `--with-content` + env opt-in), empty-attr + usage errors, and every analyze subcommand against `self-test/fixtures/worker-session-trace/sample-trace.jsonl` plus stdin + missing-file paths. Pure bash + jq, no fixtures outside the committed sample + `mktemp`. |
| `promote-trace-to-golden.sh` | Commander (future watchdog wiring) or operator, after a `commander-stuck`/failed/rescued run leaves a trace | The production-to-test flywheel: convert ONE ticket's session trace (`logs/traces/<ticket>.jsonl`, #197) + its rescue verdict / review outcome into ONE `kind:"script"` self-test golden case (`trace-golden-<ticket>`), growing the regression suite from real failures. Writes a content-sanitized fixture (`gen_ai.prompt`/`gen_ai.completion` stripped — secrets hard-rail) and emits a trace-replay case asserting (a) the trace still parses and (b) its `error.type` signature is still detected by `trace-analyze.sh` (idle-ghost traces assert `.errors == 0` instead). Prints the case to stdout by default; `--into <cases-file>` merges it idempotently (keyed by case id — no duplicates); `--dry-run` writes nothing. bash + jq, offline. Spec: `docs/specs/2026-05-21-trace-to-golden-promotion.md` (ticket #205). |
| `test-promote-trace-to-golden.sh` | Operator pre-push, or CI | Regression test for `promote-trace-to-golden.sh` (24 assertions). Proves the flywheel end-to-end: emit a valid case from a failed-run trace, capture the failure signature, sanitize content out of the written fixture, idempotent `--into` merge, and the headline check — promote into a tmp cases file and run `self-test/run.sh` on the produced case to assert it executes green. Plus the idle-ghost path, the `--ticket` shell-injection guard, and usage/missing-trace errors. Self-cleaning fixtures (no committed-dir pollution). |
| `trace-cost.sh` | Cost rollup (`cost-rollup.sh`) + operator/quota; consumer of the #197 trace substrate | Compute USD cost from a `logs/traces/<ticket>.jsonl` by multiplying the `gen_ai.usage.*_tokens` the substrate already captures by the per-model rates in `state/pricing.json`. Subcommands: `spans` (per token-bearing span cost) and `rollup` (per-ticket totals + `by_model`). `--model` sets the model for spans lacking `gen_ai.request.model`; unknown models fall back to the table `default` rate (never silently $0); a token-less trace yields `cost_usd: 0`. File arg or stdin; `--json`. Spec: `docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md` (ticket #195). |
| `cost-rollup.sh` | Commander/worker after a run, to record per-ticket spend | Run `trace-cost.sh rollup` for a ticket and MERGE the result (a top-level `cost_usd` + a `cost` object) into the existing `logs/<ticket>.json` without clobbering the worker's other fields. Creates a minimal `{ticket, cost_usd, cost}` log if none exists; `--dry-run` prints without writing; atomic write (tmp + `mv`). Spec: `docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md` (ticket #195). |
| `cost-per-pr.sh` | Commander `quota` / digest; operator efficiency check | The headline metric: join every `logs/<ticket>.json:cost_usd` against merged-PR status and report total-cost-over-merged-PRs ÷ merged-PR count (the cost-per-merged-PR number the community settled on). Merged status from `gh pr view <url> --json mergedAt`, or fully offline via `--merged-prs <file>` (no `gh`). `--include-unmerged` surfaces wasted spend; `--json`. Zero merged PRs → `cost_per_merged_pr: null` (no divide-by-zero). Spec: `docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md` (ticket #195). |
| `test-cost.sh` | Operator pre-push, or CI | Regression test for `trace-cost.sh` + `cost-rollup.sh` + `cost-per-pr.sh` (36 assertions). Covers exact pricing math, per-model rollup, `--model` override, unknown-model fallback, degrade-safe zero-token trace, log-merge field preservation + minimal-create + `--dry-run`, the offline cost-per-PR join, the divide-by-zero guard, and usage errors, plus the committed `self-test/fixtures/cost-attribution/` round-trip. Pure bash + jq, offline. |

Each script is self-contained bash with a `usage()` block (the MCP server is Python 3 stdlib). `jq` is the only required non-standard bash dependency — it's already required by Hydra at install time (`INSTALL.md`). `ajv-cli` is an optional strict-validation upgrade for `validate-state.sh` / `validate-state-all.sh`; install with `npm i -g ajv-cli ajv-formats`. Python 3 is required for the MCP server (already present in the Fly image via the `/health` server).

## MCP server (agent-only interface)

`scripts/hydra-mcp-server.py` implements Hydra's agent-only interface — the server process external client agents (OpenClaw, supervisor agents, dashboard bots) reach over HTTP + JSON-RPC 2.0. The server is launched via `./hydra mcp serve` (which dispatches to `scripts/hydra-mcp-serve.sh`).

Phase 1 scope (ticket #72): three tools implemented (`hydra.get_status`, `hydra.list_ready_tickets`, `hydra.pause`), ten scaffolded as `NotImplemented`, `hydra.merge_pr` always refuses T3 PRs before falling through. See `docs/specs/2026-04-17-mcp-server-binary.md` for the full contract and `docs/mcp-tool-contract.md` for the human-readable tool reference.

Prerequisites:

- `state/connectors/mcp.json` with at least one `authorized_agents[]` entry (server refuses to start otherwise).
- `mcp/hydra-tools.json` present (always committed).
- Python 3 on PATH.

Environment overrides (respected by the Python script):

| Env var | Default | Purpose |
|---|---|---|
| `HYDRA_MCP_PORT` | `8765` | HTTP port |
| `HYDRA_MCP_BIND` | `127.0.0.1` | Bind address — never set `0.0.0.0` without a TLS reverse proxy. |
| `HYDRA_MCP_CONFIG` | `state/connectors/mcp.json` | Path to the connector config |
| `HYDRA_MCP_TOOLS` | `mcp/hydra-tools.json` | Tool contract |
| `HYDRA_MCP_AUDIT_LOG` | `logs/mcp-audit.jsonl` | Audit log path |
| `HYDRA_MCP_PAUSE_FILE` | `commander/PAUSE` | Sentinel written by `hydra.pause` |
| `HYDRA_MCP_ENABLED` | `1` | Set to `0` to make the shell wrapper no-op (operator rollback). |

## Memory directory resolution

Each script accepts an optional `--memory-dir <path>` argument. When absent, the scripts resolve the memory directory in this order:

1. `$HYDRA_EXTERNAL_MEMORY_DIR` (from `.hydra.env`, set by `setup.sh` in the future external-memory-split refactor — see `docs/specs/2026-04-16-external-memory-split.md`)
2. `./memory/` (current behaviour — framework + operational memory both live in-repo)

This lets the scripts work today with in-repo memory AND keep working after the external memory split lands without changes.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / validation passed |
| 1 | Validation failure (clear error messages on stderr) |
| 2 | Usage error (bad flags / missing input) |

## How Commander wires them in

Rough shape of the citation-merge flow Commander runs after each worker report:

```bash
delta=$(scripts/parse-citations.sh < "logs/$ticket_num.report.txt")
jq -s '.[0] as $cur | .[1] as $delta | <merge-logic>' \
   state/memory-citations.json <(printf '%s' "$delta") > state/memory-citations.json.new
mv state/memory-citations.json.new state/memory-citations.json
```

Commander owns the merge semantics (incrementing counts, deduping tickets, flipping `promotion_threshold_reached`). The scripts stay stateless and composable.

## Adding a new script

Follow the existing convention:

- `#!/usr/bin/env bash` + `set -euo pipefail`
- A `usage()` function printed on `-h` / `--help` / bad args
- Accept `--memory-dir <path>` if the script touches memory files
- Accept `--state-dir <path>` / `--schema-dir <path>` if the script touches `state/*.json` (lets fixtures reuse the canonical schemas without duplication)
- Exit codes per table above
- `bash -n` clean
- A matching fixture under `self-test/fixtures/<topic>/` (memory-validator, state-schemas, linear, etc.)
- A case in `self-test/golden-cases.example.json`
