# Commander helper scripts

These are **helper scripts invoked by Commander during memory lifecycle operations** (see `memory/memory-lifecycle.md`). They are not standalone tools — Commander calls them from its operating loop and merges / interprets their output.

## Overview

| Script | Who calls it | Purpose |
|---|---|---|
| `parse-citations.sh` | Commander, after every worker report comes back | Extract `MEMORY_CITED:` markers from a worker report and emit a JSON delta that Commander merges into `state/memory-citations.json` |
| `validate-learning-entry.sh` | Commander, before appending/committing a learnings file; pre-commit hook material | Sanity-check a `learnings-<repo>.md` file against the schema (frontmatter keys, section headings, line length, date format) |
| `validate-citations.sh` | Commander, during `compact memory` / `promote learnings` hygiene passes | Walk `state/memory-citations.json`, check every citation quote still exists in its referenced file. Flags stale references that need cleanup. |
| `state-get.sh` / `state-put.sh` | Commander + any adapter call site | Read / write a logical state blob. Defaults to `state/<key>.json` (Phase 1). Flips to DynamoDB when `HYDRA_STATE_BACKEND=dynamodb` (Phase 2). Awscli + jq. |
| `memory-mount.sh` | Operator, once per host | Mount an S3 bucket at `$HYDRA_EXTERNAL_MEMORY_DIR` via `mount-s3`. Prints clear install instructions if mount-s3 isn't on PATH. `--dry-run` previews the invocation. |
| `hydra-mcp-serve.sh` | `./hydra mcp serve` dispatches here | Thin wrapper that validates prereqs and `exec`s `hydra-mcp-server.py`. See the MCP server section below. |
| `hydra-mcp-server.py` | `hydra-mcp-serve.sh` (not called directly) | The actual MCP server process. Python 3 stdlib only — no `pip install` needed. Serves the 13 tools from `mcp/hydra-tools.json` per the spec in `docs/specs/2026-04-17-mcp-server-binary.md`. |

Each script is self-contained bash with a `usage()` block (the MCP server is Python 3 stdlib). `jq` is the only non-standard bash dependency — it's already required by Hydra at install time (`INSTALL.md`). Python 3 is required for the MCP server (already present in the Fly image via the `/health` server).

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
- Exit codes per table above
- `bash -n` clean
- A matching fixture under `self-test/fixtures/memory-validator/`
- A case in `self-test/golden-cases.example.json`
