# Pair Zed with Hydra

Connect the Zed editor as an MCP client so its assistant can call `hydra.*` tools.

## Prerequisites

- Zed installed (0.160+ for stable MCP client support — older builds have incomplete grammar).
- Your Commander is running. Quick check: `./hydra status` reports alive.
- An agent-id for this Zed instance, e.g. `zed-laptop`.
- Know where Zed stores config: `~/.config/zed/settings.json` on Linux, `~/Library/Application Support/Zed/settings.json` on macOS. (Open Zed and run the `zed: open settings` command to have Zed open its own settings file.)

## Fast path

Since Zed's MCP config grammar is close enough to the generic shape, use the `generic` editor:

```
./hydra pair-agent --editor generic zed-laptop
```

The script prints a generic MCP config block. Translate it into Zed's `assistant.mcp_servers` stanza (shown below).

## Manual path

```
# 1. Generate a bearer.
./hydra mcp register-agent zed-laptop
#   → prints the token once; copy it.

# 2. Add Hydra to Zed's settings.json. Merge into the existing object —
#    don't wholesale-replace your settings file.
#    The "assistant.mcp_servers" key is Zed's documented location for MCP.
#    Zed's MCP config accepts either stdio commands OR (on recent builds)
#    an HTTP URL with headers.
```

Append to your Zed `settings.json`:

```
{
  "assistant": {
    "mcp_servers": {
      "hydra": {
        "url": "http://127.0.0.1:8765/mcp",
        "transport": "http",
        "headers": {
          "Authorization": "Bearer <token-would-go-here>"
        }
      }
    }
  }
}
```

Replace the URL with `https://<your-app>.fly.dev/mcp` for cloud mode. Replace `<token-would-go-here>` with the real token.

```
# 3. Restart Zed so it re-reads the config.
```

## Sanity check

Open Zed's assistant panel and ask it to call `hydra.get_status`. Expected: a JSON-RPC result describing worker counts, pause flag, autopickup state.

Independent curl (doesn't touch Zed):

```
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token-would-go-here>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}'
```

Expected: HTTP 200 with `result` in the body.

## Top 3 failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| **Zed doesn't recognize the `assistant.mcp_servers` stanza** | Your Zed build predates stable MCP support (~0.160). | Upgrade Zed. Meanwhile, use a non-Zed Claude Code session as your Main Agent (see [`claude-code.md`](claude-code.md)). |
| **Zed recognizes the config but tool calls return 401** | Bearer mismatch — token rotated, wrong URL, or mismatched cloud/local context. | Re-run `./hydra pair-agent --editor generic <agent-id>` to mint fresh, update the `Authorization` header in `settings.json`, restart Zed. |
| **Config is valid JSON but Zed can't connect (timeout / refused)** | MCP server is not serving at the URL in the config. | Local: `./hydra mcp serve` in another terminal; confirm port matches. Cloud: `fly status --app <your-app>` shows a started machine; confirm the URL in `settings.json` matches `https://<your-app>.fly.dev/mcp`. |

## Related

- [`docs/mcp-tool-contract.md`](../mcp-tool-contract.md) — `hydra.*` tool surface.
- [`docs/specs/2026-04-17-pair-agent.md`](../specs/2026-04-17-pair-agent.md) — the pairing command spec.
- [Zed docs: MCP integration](https://zed.dev/docs/) — authoritative reference for the `assistant.mcp_servers` grammar in your installed version.

# Community-verified pending — run this against your Zed install and, if it works, edit this line to `# Verified against Zed <version> on <date>` and open a PR. If the config block needs different keys, open an issue with the symptom and the working version.
