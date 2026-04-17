# Hydra skills

User-installable Claude Code skills that teach a Main Agent how to drive Hydra.

These are **not** worker-subagent skills (those live in `.claude/skills/` per repo and graduate automatically via the memory → skill-promotion pipeline). These are Main-Agent skills: they teach the operator's primary assistant when to call Hydra's MCP tools and how to interpret structured callbacks from Commander.

## What's here

| Skill | Purpose |
|---|---|
| [`hydra-operator/`](./hydra-operator/) | Maps natural-language operator messages to `hydra.*` MCP tool calls; handles inbound `supervisor.resolve_question` calls from Commander. Install into `~/.claude/skills/`. |

## Conventions for adding more skills here

Mirror Claude Code's skill shape exactly — no Hydra-specific extensions:

1. One directory per skill: `skills/<skill-name>/`.
2. `SKILL.md` at the directory root, with YAML frontmatter containing at minimum:
   - `name:` — matches the directory name
   - `description:` — one paragraph; Claude Code's loader matches operator messages against this, so be precise about when the skill should activate
   - `mcpServers:` — list of MCP servers the skill expects to be connected (or omit if the skill is pure reasoning)
3. `README.md` next to `SKILL.md` with install / verify / troubleshoot instructions. The `cp -r skills/<name> ~/.claude/skills/` install step should be copy-pasteable.
4. Optional: fixtures, example transcripts, or supplementary docs in the same directory.

Keep skills **additive** and **narrow**. A skill that does one thing well is more useful than a skill that does ten things ambiguously — Claude Code's description-matching is more reliable when descriptions are specific.

## Codex-equivalent skills (future work)

These skills target Claude Code's skill shape. Operators using OpenAI Codex CLI or other agent harnesses today can read `SKILL.md` as a decision prompt and paste it manually, but we don't yet ship a codex-native equivalent. Follow-up ticket: mirror each skill in `skills/<name>/codex/` once the Codex skill format stabilizes.

## Related

- `.claude/agents/` — worker subagents (different from Main-Agent skills).
- `mcp/hydra-tools.json` — the MCP tool contract these skills call against.
- `docs/mcp-tool-contract.md` — prose mirror of the tool contract.
