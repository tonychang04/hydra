# hydra-operator skill

A Claude Code skill that teaches your Main Agent **when** and **how** to call Hydra's MCP tools. Install it once into your user-scoped skills dir and every Claude Code session you open knows how to drive Hydra without you re-explaining the verbs each time.

This skill does not ship the MCP server itself — it packages the operator-facing decision knowledge. For the server side, see `mcp/hydra-tools.json` (the tool contract) and `docs/mcp-tool-contract.md`.

## Install

Copy the skill into Claude Code's user-scoped skills directory:

```bash
cp -r skills/hydra-operator ~/.claude/skills/
```

That's it. Claude Code picks up new skills on next session start.

## Verify

```bash
claude --list-skills | grep hydra-operator
```

You should see the skill name printed. If you don't, re-check the path — Claude Code's skill discovery is strict about the `SKILL.md` filename and the YAML frontmatter (`name`, `description`, and optional `mcpServers`).

## When the skill auto-activates

Claude Code's skill loader matches the operator's chat message against every skill's `description:` frontmatter. This skill's description is tuned to fire on:

- Dispatch-shaped messages: `pick up 3`, `grab a ticket`, `work on that one`
- Status-shaped messages: `what's running`, `status`, `what's Hydra doing`
- Merge-shaped messages: `merge #501`, `land that one`, `reject #501`
- Lifecycle: `pause`, `resume`, `kill the worker on #42`
- Retro: `show this week's retro`
- **Inbound** from Commander: when Commander calls `supervisor.resolve_question` back into the Main Agent, the skill's description matches those structured calls too.

If none of those patterns match, the skill stays dormant — no unnecessary priming of the context window.

## Troubleshooting

**Skill not triggering on operator messages**

- Confirm `~/.claude/skills/hydra-operator/SKILL.md` exists.
- Confirm the YAML frontmatter has `name:`, `description:`, and `mcpServers:` (the loader rejects skills missing required fields silently).
- Try an exact trigger phrase like "what's Hydra doing" to rule out description-matching flakiness.
- Restart your Claude Code session — skills are discovered once at startup.

**"MCP server not found" when the skill tries to call a tool**

The skill assumes a `hydra` MCP server is connected. Bring it up with:

```bash
./hydra mcp serve
```

(Or the equivalent in your install — follow `docs/mcp-tool-contract.md`.) In Claude Code, verify with `/mcp` that `hydra` is listed and connected.

**Skill runs but refuses to merge**

By design. T2 merges always require an operator confirmation — the skill will not auto-approve. T3 (auth, migrations, infra) is refused outright with the message "Tier 3 — needs human." If you hit this and disagree, the right fix is a `policy.md` change in your Hydra repo, not a skill edit.

**Skill conflicts with another "hydra"-shaped skill**

Claude Code resolves skill name clashes by last-write-wins in the discovery order (user-scoped beats project-scoped). Rename your other skill or delete this one — don't leave two `name: hydra-operator` skills side by side.

## Uninstall

```bash
rm -rf ~/.claude/skills/hydra-operator
```

No residual state. The next session start re-reads the skills dir and the entry is gone.
