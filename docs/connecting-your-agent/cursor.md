# Pair Cursor with Hydra

Connect the Cursor editor as an MCP client so its agent can call `hydra.*` tools.

## Prerequisites

- Cursor installed. MCP support is available in Cursor's agent / Composer modes.
- Your Commander is running. Quick check: `./hydra status` reports alive.
- An agent-id for this Cursor project, e.g. `cursor-myproject`.
- Know where Cursor reads MCP config: either `~/.cursor/mcp.json` (user-level) or `<project>/.cursor/mcp.json` (project-level).

## Fast path

```
./hydra pair-agent --editor cursor cursor-myproject
```

The script prints a ready-to-drop-in JSON block. Merge it into your `~/.cursor/mcp.json` (or create the file if it doesn't exist). Restart Cursor. Done.

## Manual path

```
# 1. Generate a bearer.
./hydra mcp register-agent cursor-myproject
#   → prints the token once; copy it.

# 2. Edit ~/.cursor/mcp.json (create if missing). Merge this block into the
#    existing "mcpServers" object; don't wholesale-replace it if you have
#    other MCP servers configured.
cat > ~/.cursor/mcp.json <<'EOF'
{
  "mcpServers": {
    "hydra": {
      "url": "http://127.0.0.1:8765/mcp",
      "transport": "http",
      "headers": {
        "Authorization": "Bearer <token-would-go-here>"
      }
    }
  }
}
EOF
#   → Replace the URL with https://<your-app>.fly.dev/mcp for cloud mode.
#   → Replace <token-would-go-here> with the real token from step 1.

# 3. Restart Cursor so it re-reads the MCP config.
```

## Sanity check

In a Cursor agent session (Composer / Agent mode), ask it to list available tools. You should see `hydra.get_status`, `hydra.pick_up`, etc. Ask the agent to call `hydra.get_status` — expected: a result payload with worker counts and flags.

CLI sanity (independent of Cursor):

```
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token-would-go-here>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}'
```

Expected: HTTP 200 with a JSON-RPC `result` object.

## Top 3 failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| **Cursor shows no `hydra.*` tools after restart** | MCP config file not in the path Cursor reads, or JSON is malformed. | Validate with `jq . ~/.cursor/mcp.json`. Check the file lives at `~/.cursor/mcp.json` (user-level) or `<project>/.cursor/mcp.json` (project-level). Restart Cursor fully (quit from the menu, not just close window). |
| **Tools appear but every call returns 401** | Bearer mismatch — token rotated, or wrong server URL. | Re-run `./hydra pair-agent --editor cursor <agent-id>` to mint fresh, replace the `Authorization` header in `mcp.json`, restart Cursor. |
| **`connect ECONNREFUSED` on every call** | MCP server isn't running at the URL Cursor has. | Local: `./hydra mcp serve` in another terminal, then confirm `http://127.0.0.1:8765/mcp` responds. Cloud: check `fly status --app <your-app>` and the `mcp.json` URL matches your Fly app. |

## Related

- [`docs/mcp-tool-contract.md`](../mcp-tool-contract.md) — full `hydra.*` tool surface.
- [`docs/specs/2026-04-17-pair-agent.md`](../specs/2026-04-17-pair-agent.md) — the `./hydra pair-agent` command.
- [`scripts/hydra-pair-agent.sh`](../../scripts/hydra-pair-agent.sh) — the `emit_cursor_recipe()` function is the source of truth for the JSON shape.

# Community-verified pending — run this against your Cursor install and, if it works, edit this line to `# Verified against Cursor <version> on <date>` and open a PR. If the recipe is wrong, open an issue with the symptom and what you had to change.
