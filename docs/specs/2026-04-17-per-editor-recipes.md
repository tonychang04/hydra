---
status: implemented
date: 2026-04-17
author: hydra worker (ticket #129)
---

# Per-editor MCP integration recipes

## Problem

Today Hydra's `INSTALL.md` and `README.md` assume Claude Code as the consuming agent. The actual MCP-over-HTTP surface (`docs/mcp-tool-contract.md`) is client-agnostic — any MCP-speaking client can pair — but each client has a different config grammar. Operators running Cursor, Zed, or OpenClaw have to translate the Claude Code recipe into their own client's format and Google for the right JSON block. When they get it wrong (usual failure: header syntax, URL vs. command transport, stale bearer), the error surfaces as a vague 401 or 404 from the MCP server rather than "Cursor stores headers under `mcpServers.*.headers`, not `mcpServers.*.env`."

Ticket #124 shipped `./hydra pair-agent --editor <name>` to automate the bearer + recipe emission for a single client. That closes the "how do I copy-paste the JSON" part of the problem. What remains is the **narrative** piece: where does the JSON go, how do you verify it worked, what are the top three failure modes per client. That's what this ticket adds — one doc per supported client, short and testable.

## Goals / non-goals

**Goals:**

- `docs/connecting-your-agent/` directory with five markdown files, one per supported client family: `claude-code.md`, `cursor.md`, `zed.md`, `openclaw.md`, `generic-mcp.md`.
- A short `README.md` index inside the directory that routes the reader to the right recipe in ≤10 lines.
- Each recipe has the same skeleton: **prerequisites** → **commands** (5-15 lines, real copy-pasteable) → **sanity check** → **three common failure modes with fixes** → verification footer.
- Each recipe points at `./hydra pair-agent --editor <name>` (shipped in #124) as the fast path, so the doc stays in sync with the automation.
- Cross-link from `README.md` (one small paragraph in a new `## Connect your agent` section or inline in the existing `## How Hydra compares` area) and from `INSTALL.md` Option A's "Connect your main agent via MCP" block.
- Be honest about verification. Recipes for clients the worker could reasonably run against its own install are marked `# Verified against <client-version> on <date>`. Recipes for clients the worker can't run are marked `# Community-verified pending` — operator runs them and reports back.

**Non-goals:**

- **Not a tutorial on MCP itself.** The existing `docs/mcp-tool-contract.md` is the canonical reference for tool names, scopes, error shapes. Per-editor recipes link into it; they don't duplicate it.
- **Not a searchable docs site.** Plain markdown under `docs/` is fine for v1. If these grow past ~10 clients, revisit.
- **Not support for non-MCP clients** (JetBrains pre-MCP-plugin, raw REPL loops, etc.). `generic-mcp.md` covers the lowest-common-denominator MCP-over-HTTP/stdio flow; anything that doesn't speak MCP natively is out of scope for v1.
- **Not a replacement for `./hydra pair-agent`.** The recipes are the *description* of what pair-agent emits, plus troubleshooting. Operators should still run pair-agent for the actual paste-ready JSON with a fresh bearer.
- **Does not touch `scripts/hydra-pair-agent.sh`, `setup.sh`, or `CLAUDE.md`.** Docs-only change.

## Proposed approach

Placement: `docs/connecting-your-agent/` lives alongside the existing `docs/mcp-tool-contract.md` and `docs/specs/`. Chose this over top-level `connecting-your-agent.md` because (a) there are five+ files, (b) the directory signals "per-client recipes" to readers scanning `docs/`, and (c) it mirrors the pattern used by `docs/demo/` and `docs/templates/`.

Structure of each recipe file (~40-80 lines):

1. **Heading + one-sentence summary** — "Pair Cursor with your Hydra Commander."
2. **Prerequisites** — 3-5 bullets (client installed, MCP server running, agent-id idea).
3. **Fast path** — single `./hydra pair-agent --editor <name> <agent-id>` call. Copy the output it prints, done.
4. **Manual path** — if the operator wants to understand what's happening, 5-15 lines of commands (bearer generation → config file edit → restart client → sanity call).
5. **Sanity check** — one `curl` or in-client tool call that confirms the wiring works (expected output shown).
6. **Top 3 failure modes** — for each: symptom, diagnosis command, fix. Pulled from the error table in `scripts/hydra-pair-agent.sh`'s sanity-check logic (401 / 404 / connect-refused / timeout) plus client-specific gotchas.
7. **Verification footer** — `# Verified against <client-version> on <date>` OR `# Community-verified pending — run this against your install and open an issue with the result.`

Index `docs/connecting-your-agent/README.md` is a two-column table: client → recipe link, with a fallback line pointing at `generic-mcp.md` for anything unlisted.

Cross-links:
- `README.md`: add a **§ Connect your agent** section (or append to the existing MCP-adjacent section) with one paragraph + link to `docs/connecting-your-agent/`. Small addition, no restructuring.
- `INSTALL.md` Option A: the existing "Connect your main agent via MCP" subsection gets a one-line pointer above its step-by-step instructions: "For per-client recipes (Cursor, Zed, OpenClaw), see `docs/connecting-your-agent/`."

### Verification policy

The worker can realistically run the recipe for **Claude Code** (the worker itself speaks Claude Code grammar — the same `claude mcp add` command is documented and exercised in ticket #124's self-test). For that file, the footer reads `# Verified against claude-code CLI shipping with Claude Code (commander base image) on 2026-04-17`. The command is lifted verbatim from `scripts/hydra-pair-agent.sh`'s `emit_claude_code_recipe()`.

The other four clients (Cursor, Zed, OpenClaw, generic) get `# Community-verified pending`. Reasoning: the worker can read each client's published MCP config grammar and assemble a plausible config block, but "plausible" ≠ "tested on a live install." Marking `pending` is the honest signal that says "this is what the published docs say; your mileage may vary; open an issue if it doesn't work." Falsely marking `Verified` on an untested recipe would destroy the footer's signal for the one recipe where it is true.

### Alternatives considered

- **Alternative A: one giant `docs/per-editor-recipes.md` with headers per client.** Rejected — at ~400 lines it becomes hard to cross-link ("see the Cursor recipe"), hard to diff (any edit touches the whole file), and hard to add clients later (every add expands an already-large file). Five focused files scale better.
- **Alternative B: generate the recipes from `scripts/hydra-pair-agent.sh` output + a prose shell.** Rejected for v1 — keeps two sources of truth (script output + narrative) that must stay in sync. The script's output is the source of truth for the *commands*; these docs are the source of truth for the *narrative and troubleshooting*. The recipes deliberately quote the commands rather than generate them.
- **Alternative C: skip `zed.md` and `openclaw.md` until an operator asks.** Rejected — the ticket explicitly names all five. Absent files make a worse index (readers assume no support rather than "pending"). "Community-verified pending" is the honest middle ground.
- **Alternative D: put the recipes on a docs site (MkDocs / Docusaurus).** Rejected — see "Not a searchable docs site" in non-goals. Not enough volume yet to justify the site infrastructure.

## Test plan

- **Link integrity:** every cross-link (`README.md` → `docs/connecting-your-agent/`, `INSTALL.md` → `docs/connecting-your-agent/`, `README.md` inside the new dir → each of the five files, each file → `docs/mcp-tool-contract.md` + `scripts/hydra-pair-agent.sh`) resolves. Manually checked; CI's doc-link-check (if present) picks it up.
- **Markdown lint:** all six new files parse as valid markdown (no unclosed code fences, no orphan headings).
- **Command accuracy:** the `claude mcp add` command in `claude-code.md` byte-matches the one emitted by `scripts/hydra-pair-agent.sh:emit_claude_code_recipe()` (modulo the `<agent-id>` and `<token>` placeholders).
- **Verification footer discipline:** `claude-code.md` has `# Verified against ...` with a concrete version+date; the other four have `# Community-verified pending` verbatim.
- **CI gate:** the existing `ci.yml` spec-presence check picks up `docs/specs/2026-04-17-per-editor-recipes.md` and finds it referenced from the PR body.

No code changes means no unit tests — this is docs only. The "test" is the operator running `./hydra pair-agent --editor cursor my-laptop` and following the recipe; a broken recipe fails at the sanity-check step the script already runs.

## Risks / rollback

- **Risk: recipe drifts from `scripts/hydra-pair-agent.sh` output.** If ticket #124's script later renames a flag or changes the emitted block format, the recipe becomes subtly wrong. Mitigation: each recipe cites the script (`see scripts/hydra-pair-agent.sh` at the bottom). A future audit (`./hydra audit`-driven worker-auditor) can diff the recipe against the script's current emission and file a drift ticket.
- **Risk: `# Community-verified pending` stays forever.** Mitigation: explicit follow-up note in each file — "when you verify this, edit the footer to `# Verified against <client-version> on <date>` and open a PR." Low-friction; operators who run pair-agent against their client are the exact population that can flip this atom.
- **Risk: recipe leaks a real bearer.** Mitigation: every code block uses the literal placeholder `<token-would-go-here>` (same placeholder `--dry-run` emits). Search each file before commit for any 40+ char base64-shaped substring; none should exist. The recipes never commit a token.
- **Rollback:** delete `docs/connecting-your-agent/` and the two cross-link paragraphs in `README.md` / `INSTALL.md`. No state writes, no script changes — one `git revert` reverts cleanly.

## Implementation notes

- Recipe files land in the same commit as the spec. The cross-links to `README.md` / `INSTALL.md` land in a follow-up commit within the same PR so the diff is legible.
- `generic-mcp.md` intentionally mirrors `openclaw.md` closely — both target the lowest-common-denominator MCP-over-HTTP flow. The split exists because "OpenClaw" is a named product with its own config file location and "generic MCP" is the fallback for anything else; readers scan for their client name, not for a generic doc.
- The `zed.md` recipe references Zed's `assistant.mcp_servers` config block (Zed's documented location for MCP servers as of Zed 0.168.x). If Zed ships a breaking change, the recipe is a single-file edit.
