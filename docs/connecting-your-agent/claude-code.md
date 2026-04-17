# Pair Claude Code with Hydra

Connect the `claude` CLI (Anthropic's Claude Code) as an MCP client so your Main Agent session can call `hydra.*` tools.

## Prerequisites

- `claude` CLI installed and on `PATH` (run `claude --version` to confirm).
- Your Commander is running. Quick check: `./hydra status` reports alive; cloud mode: `fly status --app <your-app>` shows a started machine.
- An agent-id in mind — a short label like `my-laptop-claude` that identifies this client in Commander's audit log.

## Fast path

```
./hydra pair-agent --editor claude-code my-laptop-claude
```

Copy the `claude mcp add ...` line it prints, paste it into your terminal, and you're done. The script also runs a live sanity check and reports `✓` on success.

## Manual path

If you want to see what's happening under the hood, here's the same flow step-by-step:

```
# 1. Generate a bearer and widen scope if needed (default: read,spawn).
./hydra mcp register-agent my-laptop-claude
#   → prints a 44-char base64 token on stdout, exactly once.
#   → Commander stores only the SHA-256 hash in state/connectors/mcp.json.

# 2. Register Hydra as an MCP server in your Claude Code config.
claude mcp add hydra \
  --url http://127.0.0.1:8765/mcp \
  --transport http \
  --header "Authorization: Bearer <token-would-go-here>"
#   → Replace the URL with your cloud URL (https://<your-app>.fly.dev/mcp) if running on Fly.
#   → Replace <token-would-go-here> with the token printed in step 1.

# 3. Verify.
claude mcp list | grep hydra
#   → should list the hydra server as registered.
```

## Sanity check

From any Claude Code session, ask the agent to call `hydra.get_status`. Expected: a JSON-RPC success result describing how many workers are active, the pause flag, and autopickup state.

Or run the raw curl:

```
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token-would-go-here>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}'
```

Expected: HTTP 200 with `{"jsonrpc":"2.0","result":{...}}`.

## Top 3 failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| **HTTP 401 from `hydra.get_status`** | Server doesn't recognize the bearer. Likely: token was rotated, or you paired against the wrong URL. | Re-run `./hydra pair-agent --editor claude-code <agent-id>` to mint a fresh bearer, then re-paste the `claude mcp add` line. |
| **HTTP 404 or connect-refused** | MCP server isn't running at that URL. | Local: run `./hydra mcp serve` in another terminal. Cloud: `fly deploy` to redeploy, then verify with `fly status --app <your-app>`. |
| **`claude mcp list` shows hydra, but tool calls fail silently** | The `--header` flag is present but your Claude Code version pre-dates HTTP-transport headers, or the header string got mangled by shell quoting. | Upgrade `claude` to the latest version. If still broken, fall back to stdio-style config via `generic-mcp.md`. |

## Related

- [`docs/mcp-tool-contract.md`](../mcp-tool-contract.md) — full `hydra.*` tool surface, scopes, JSON shapes.
- [`docs/specs/2026-04-17-pair-agent.md`](../specs/2026-04-17-pair-agent.md) — spec for the `./hydra pair-agent` command.
- [`scripts/hydra-pair-agent.sh`](../../scripts/hydra-pair-agent.sh) — the script this recipe mirrors; source of truth for the exact commands.

# Verified against the `claude mcp add` grammar emitted by `scripts/hydra-pair-agent.sh` on 2026-04-17 (matches the ticket #124 self-test golden case).
