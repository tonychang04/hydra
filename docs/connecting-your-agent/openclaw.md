# Pair OpenClaw with Hydra

Connect an OpenClaw agent (or Codex-CLI, or any similar MCP-speaking workflow runner) so it can call `hydra.*` tools.

## Prerequisites

- OpenClaw installed and its config directory known to you (consult OpenClaw's own install docs — the path varies by version).
- Your Commander is running. Quick check: `./hydra status` reports alive.
- An agent-id for this client, e.g. `openclaw-ops`.
- OpenClaw config grammar for MCP servers. The field names have shifted across OpenClaw releases; the generic shape below works for the current stable but YOUR build may need slight adjustments.

## Fast path

```
./hydra pair-agent --editor openclaw openclaw-ops
```

The script prints a generic MCP config block. Drop it into OpenClaw's config file (the path depends on your OpenClaw install — check its docs).

## Manual path

```
# 1. Generate a bearer.
./hydra mcp register-agent openclaw-ops
#   → prints the token once; copy it.

# 2. Add a generic MCP server entry to OpenClaw's config. Exact field names
#    depend on your OpenClaw version — consult `openclaw --help mcp` or
#    the docs shipped with your build. The mapping below is the grammar
#    `scripts/hydra-pair-agent.sh` emits; translate into OpenClaw's form.
```

Generic MCP config block (what `./hydra pair-agent --editor openclaw` emits):

```
# Generic MCP config — client-specific grammar varies.
# Replace auth_header with your client's equivalent (--header, headers, etc.).
url=http://127.0.0.1:8765/mcp
transport=http
auth_header=Authorization: Bearer <token-would-go-here>
```

Replace the URL with `https://<your-app>.fly.dev/mcp` for cloud mode. Replace `<token-would-go-here>` with the real token.

```
# 3. Restart OpenClaw or reload its config so the new server is picked up.
```

## Sanity check

Ask OpenClaw to list available MCP tools — you should see `hydra.get_status` among them. Call it and expect a result payload with worker counts and flags.

Independent curl (client-agnostic):

```
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token-would-go-here>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}'
```

Expected: HTTP 200 with a JSON-RPC `result`.

## Top 3 failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| **OpenClaw rejects the config file after editing** | Field names don't match your OpenClaw version's grammar (e.g. `auth_header` vs. `headers` vs. `--header`). | Consult `openclaw --help mcp` for your version's exact schema. The URL + transport + bearer header are always the three pieces you need; only the JSON/YAML key names shift. |
| **Config loads but every tool call returns 401** | Bearer mismatch — token rotated, wrong URL, or you pasted the dry-run placeholder by accident. | Search the config file for `<token-would-go-here>` — if present, you pasted the placeholder. Re-run `./hydra pair-agent --editor openclaw <agent-id>` and use the real token this time. |
| **Nothing listening / connect refused** | The MCP server is not up at the configured URL. | Local: `./hydra mcp serve` in another terminal, confirm port 8765 is LISTENING (`lsof -i :8765`). Cloud: `fly status --app <your-app>` + confirm the config URL matches `https://<your-app>.fly.dev/mcp`. |

## Related

- [`docs/mcp-tool-contract.md`](../mcp-tool-contract.md) — `hydra.*` tool surface.
- [`docs/specs/2026-04-17-pair-agent.md`](../specs/2026-04-17-pair-agent.md) — the pairing command spec.
- [`scripts/hydra-pair-agent.sh`](../../scripts/hydra-pair-agent.sh) — `emit_openclaw_recipe()` is the source of truth for the generic-format block.
- OpenClaw's own docs — authoritative on field names; consult those when this recipe drifts.

# Community-verified pending — run this against your OpenClaw install and, if it works, edit this line to `# Verified against OpenClaw <version> on <date>` and open a PR. If field names differ, open an issue so this recipe can be updated for current OpenClaw grammar.
