# Commander helper scripts

These are **helper scripts invoked by Commander during memory lifecycle operations + state preflight** (see `memory/memory-lifecycle.md`). They are not standalone tools — Commander calls them from its operating loop and merges / interprets their output.

## Overview

| Script | Who calls it | Purpose |
|---|---|---|
| `parse-citations.sh` | Commander, after every worker report comes back | Extract `MEMORY_CITED:` markers from a worker report and emit a JSON delta that Commander merges into `state/memory-citations.json` |
| `build-memory-brief.sh` | Commander, as the spawn pre-step for `worker-implementation` / `worker-codex-implementation` / `worker-test-discovery` | Compile a ≤ 2000-byte repo-scoped memory brief: top-5 repo learnings by citation count + top-3 cross-repo patterns (last 30 days) + scoped escalation-faq entries + the latest retro's citation-leaderboard excerpt. Commander prepends output under a `# Memory Brief` H1 before the ticket body. Closes the open citation feedback loop so workers start with preloaded memory rather than re-discovering every time. Spec: `docs/specs/2026-04-17-memory-preloading.md`. |
| `validate-learning-entry.sh` | Commander, before appending/committing a learnings file; pre-commit hook material | Sanity-check a `learnings-<repo>.md` file against the schema (frontmatter keys, section headings, line length, date format) |
| `validate-citations.sh` | Commander, during `compact memory` / `promote learnings` hygiene passes | Walk `state/memory-citations.json`, check every citation quote still exists in its referenced file. Flags stale references that need cleanup. |
| `promote-citations.sh` | Commander, once per day via the autopickup tick (and on operator `promote learnings`) | Scan `state/memory-citations.json` for entries where `count >= 3` AND `len(unique(tickets)) >= 3`. For each eligible entry, draft `.claude/skills/<slug>/SKILL.md` in the target repo (from `repos.json:repos[]` whose name matches the `learnings-<slug>.md` basename) and open a draft PR labeled `commander-skill-promotion`. Idempotent on re-run: existing skills get their citations block updated in place, never clobbered outside the `<!-- hydra:citations-* -->` markers. `--dry-run` prints the plan without git/gh side effects. Spec: `docs/specs/2026-04-17-skill-promotion-automation.md` (ticket #145). |
| `test-promote-citations.sh` | Operator pre-push, or CI | Regression test for `promote-citations.sh`. Eight dry-run cases: threshold gate (3 cites × 3 tickets), distinct-tickets dedup, `--only` filter, idempotent re-author, missing-citations-file no-op, usage errors, cross-cutting-file skip, slug disambiguation. No fixtures outside `mktemp`. |
| `validate-state.sh` | Commander, before reading any `state/*.json` file (and the Preflight step of every spawn — see CLAUDE.md). Pre-commit hook material for contributors editing state files. | Validate one `state/*.json` against its schema under `state/schemas/*.schema.json`. Minimal bash+jq path by default (required-keys check); delegates to `ajv-cli` when available for full Draft-07 validation (types, enums, patterns, ranges). `--strict` forces the ajv path. Flags `--schema <file>` / `--schema-dir <dir>` override auto-detection so fixtures don't need duplicated schemas. |
| `validate-state-all.sh` | Commander, as the first preflight item before any spawn | Bulk-validate every known `state/*.json` against its schema in one pass. Iterates `state/schemas/*.schema.json`, skips state files that don't exist yet, reports every failure in one summary (does NOT short-circuit). Same `--strict` semantics as the per-file script. Also runs `check-claude-md-size.sh` as a first-class preflight item — see that row. |
| `check-claude-md-size.sh` | Commander, invoked from `validate-state-all.sh` as part of preflight | Enforce the CLAUDE.md character budget (default 18000; override via `--max` or `HYDRA_CLAUDEMD_MAX`). Exit 1 if over, with the top 5 H2 sections printed as trim candidates. Keeps CLAUDE.md to routing + hard rails + spec pointers; full procedures belong in `docs/specs/`. Spec: `docs/specs/2026-04-17-claudemd-size-guard.md`. |
| `test-check-claude-md-size.sh` | Operator pre-push, or CI | Regression test for `check-claude-md-size.sh`. Covers over/under threshold, env override, flag-beats-env, missing file, non-integer `--max`, and the `validate-state-all.sh` integration path. No fixtures outside `mktemp`. |
| `state-get.sh` / `state-put.sh` | Commander + any adapter call site | Read / write a logical state blob. Defaults to `state/<key>.json` (Phase 1). Flips to DynamoDB when `HYDRA_STATE_BACKEND=dynamodb` (Phase 2). Awscli + jq. |
| `memory-mount.sh` | Operator, once per host | Mount an S3 bucket at `$HYDRA_EXTERNAL_MEMORY_DIR` via `mount-s3`. Prints clear install instructions if mount-s3 isn't on PATH. `--dry-run` previews the invocation. |
| `hydra-mcp-serve.sh` | `./hydra mcp serve` dispatches here | Thin wrapper that validates prereqs and `exec`s `hydra-mcp-server.py`. See the MCP server section below. |
| `hydra-mcp-server.py` | `hydra-mcp-serve.sh` (not called directly) | The actual MCP server process. Python 3 stdlib only — no `pip install` needed. Serves the 13 tools from `mcp/hydra-tools.json` per the spec in `docs/specs/2026-04-17-mcp-server-binary.md`. |
| `hydra-mcp-register-agent.sh` | `./hydra mcp register-agent <id> [--rotate]` | Generate a 32-byte bearer token for a new MCP client agent, hash it with SHA-256 (token never touches disk), and append an entry to `state/connectors/mcp.json`. Prints the raw token to stdout exactly once. Atomic config update via tmpfile + `mv`. Spec: `docs/specs/2026-04-17-mcp-register-agent.md`. |
| `test-cloud-config.sh` | Operator pre-push, or CI | Validate cloud-mode deployment artifacts (`infra/fly.toml`, `infra/Dockerfile`, `infra/entrypoint.sh`, `scripts/deploy-vps.sh`, `mcp/hydra-tools.json`, `state/connectors/mcp.json.example`) without deploying. Skips individual checks gracefully if flyctl/docker/shellcheck are absent. Spec: `docs/specs/2026-04-16-dual-mode-workflow.md`. |
| `test-local-config.sh` | Operator pre-push, or CI | Validate local-mode install artifacts (`setup.sh`, `.hydra.env` template, `state/repos.json` seeding, `./hydra` launcher) by running the full install flow inside a mktemp'd tree. Never touches the live worktree. Same spec as above. |
| `linear-poll.sh` | `linear-pickup-dispatch.sh`, worker subagents via MCP | Thin wrapper over the Linear MCP `list_issues` tool. Emits a normalized JSON envelope regardless of whether the source is a live MCP call or a fixture file. Supports env-var tool-name overrides so operators whose Linear MCP install uses different names can retarget without editing the script. Contract: `docs/linear-tool-contract.md` (ticket #5). |
| `linear-pickup-dispatch.sh` | Commander's pickup loop, once per autopickup tick when any repo has `ticket_trigger: linear` | Reads `state/linear.json`, iterates configured teams, invokes `linear-poll.sh` per team, and filters out tickets already in a commander-managed Linear state (the Linear equivalent of GitHub's `commander-working` / `commander-stuck` labels). Emits a JSON array Commander feeds into `worker-implementation` spawn. Empty array on missing config or `enabled=false`. Spec: `docs/specs/2026-04-17-linear-ticket-trigger.md` (ticket #140). |

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
