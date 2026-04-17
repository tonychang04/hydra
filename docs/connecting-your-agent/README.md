# Connecting your agent to Hydra

One recipe per supported MCP-speaking client. Each recipe produces a client that can call `hydra.*` tools against your Commander (local laptop or cloud VPS).

**Fast path for any client:** run `./hydra pair-agent --editor <name> <agent-id>` — it prints a paste-ready config block plus a live sanity check. See ticket #124's spec at [`docs/specs/2026-04-17-pair-agent.md`](../specs/2026-04-17-pair-agent.md) for the full flag surface.

| Your client | Recipe | `--editor` value |
|---|---|---|
| Claude Code (Anthropic CLI) | [`claude-code.md`](claude-code.md) | `claude-code` |
| Cursor (editor) | [`cursor.md`](cursor.md) | `cursor` |
| Zed (editor) | [`zed.md`](zed.md) | `generic` |
| OpenClaw | [`openclaw.md`](openclaw.md) | `openclaw` |
| Anything else that speaks MCP | [`generic-mcp.md`](generic-mcp.md) | `generic` |

If your client isn't listed and you're not sure whether it speaks MCP, start with [`generic-mcp.md`](generic-mcp.md) — it covers the lowest-common-denominator MCP-over-HTTP flow. If you work through it and your client needs its own recipe, open an issue or PR.

**Before you start:** your Commander must be running and reachable. `./hydra status` should report it's alive; for cloud mode, `fly status --app <your-app>` should show a started machine. Per-client recipes assume this; if you haven't deployed, start with [`../../INSTALL.md`](../../INSTALL.md) Option A or B first.

**Canonical MCP surface:** [`docs/mcp-tool-contract.md`](../mcp-tool-contract.md) lists every `hydra.*` tool, its scope, and its input/output shape. Recipes below pair your client; the contract tells you what it can do once paired.
