# Pair any MCP client with Hydra

Fallback recipe for any MCP-speaking client not specifically covered in this directory. If your client speaks the [Model Context Protocol](https://modelcontextprotocol.io/), the three things you need are the **URL**, the **transport** (http or stdio), and the **bearer token** — everything else is client-specific.

## Prerequisites

- Any MCP-compatible client (editor, CLI, custom orchestration script).
- Your Commander is running. Quick check: `./hydra status` reports alive.
- An agent-id for this client, e.g. `my-custom-bot`.
- Access to your client's MCP server config — location and grammar are up to the client.

## Fast path

```
./hydra pair-agent --editor generic my-custom-bot
```

The script prints a minimal URL + transport + bearer tuple plus a ready-to-run raw-curl sanity check. Translate the three fields into whatever config format your client uses.

## Manual path

```
# 1. Generate a bearer.
./hydra mcp register-agent my-custom-bot
#   → prints the token once; copy it.

# 2. Configure your MCP client with these three values:
#      URL:       http://127.0.0.1:8765/mcp           (local)
#                 https://<your-app>.fly.dev/mcp       (cloud)
#      transport: http
#      header:    Authorization: Bearer <token-would-go-here>

# 3. Most clients reload config on restart; some pick it up live.
#    Consult your client's docs for the right reload gesture.
```

## Sanity check

The universal sanity check is raw curl — it doesn't depend on your client's config at all. If this returns HTTP 200, your Commander and token are good; anything past this is purely client-side config:

```
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token-would-go-here>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}'
```

Expected: HTTP 200 with `{"jsonrpc":"2.0","result":{...}}` in the body.

Once curl works, the same URL + same header should work from your client. If curl works and your client doesn't, the issue is 100% client-side config — not Hydra.

## Top 3 failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| **HTTP 401 from the curl sanity check** | Bearer mismatch. Either the token is stale, the agent-id hash on the server doesn't match this token, or you pasted the `<token-would-go-here>` placeholder from the dry-run. | Re-run `./hydra pair-agent --editor generic <agent-id>` to mint fresh. Paste the real token into both your client config AND the curl command — they must match. |
| **HTTP 404 or connect-refused from curl** | No MCP server listening at that URL. | Local: run `./hydra mcp serve` in another terminal; confirm port via `lsof -i :8765`. Cloud: check `fly status --app <your-app>` and confirm the URL in your config matches `https://<your-app>.fly.dev/mcp`. |
| **Curl works, client doesn't** | Client-side config error. Common: wrong header key (`Authorization` is case-sensitive in some clients), wrong transport (stdio vs. http mix-up), JSON config file not reloaded. | Bisect: add a second MCP server to your client pointing at a known-good public MCP echo server. If that also fails, your client's MCP transport is broken. If the echo works but Hydra doesn't, your Hydra-specific config (URL/header) is wrong. |

## Related

- [`docs/mcp-tool-contract.md`](../mcp-tool-contract.md) — every `hydra.*` tool, its scope, its input/output shape. This is the canonical reference once your client is paired.
- [`docs/specs/2026-04-17-pair-agent.md`](../specs/2026-04-17-pair-agent.md) — the `./hydra pair-agent` command spec.
- [`scripts/hydra-pair-agent.sh`](../../scripts/hydra-pair-agent.sh) — the `emit_openclaw_recipe()` function emits the same generic block used here.
- [modelcontextprotocol.io](https://modelcontextprotocol.io/) — upstream MCP spec. Useful when your client's MCP config grammar is unfamiliar.

# Community-verified pending — if you use this recipe to pair a client not covered elsewhere in this directory, edit this line to `# Verified against <client> <version> on <date>` and open a PR with a link to the client's docs. If the generic recipe doesn't work for your client, open an issue — we may need a dedicated file for that client.
