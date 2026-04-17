---
status: implemented
date: 2026-04-16
author: hydra worker (issue #53)
---

# Hydra operator skill for Main Agents

Implements: ticket #53 (T2). Depends on #52 (MCP server binary) for runtime execution; the contract (`mcp/hydra-tools.json`) shipped in #50 is enough for this skill to be meaningful immediately.

## Problem

The Main Agent (the operator's own Claude Code session) is the only agent the human talks to, per the Who's-who table in `README.md`. When the operator types `pick up 3` or `merge #501`, the Main Agent has to know:

- That those phrases map to `hydra.pick_up` / `hydra.merge_pr` MCP tool calls rather than "open a file named pick up 3" or "go find PR #501 and merge it directly via gh CLI"
- Which parameters those tools take and when NOT to call them (e.g. never auto-approve a T2 merge; refuse T3 outright)
- How to respond when Commander pushes a `supervisor.resolve_question` call upstream — without that, the Main Agent drops novel escalations on the floor

Today the only documentation of this mapping lives in `docs/mcp-tool-contract.md` (agent-author reference) and `CLAUDE.md` (Commander's internal operating loop). Neither is in the Main Agent's context automatically. The operator has to re-explain the verbs every session, or paste a cheat-sheet into their personal system prompt.

Packaging the decision knowledge as a Claude Code skill solves this: installed once into `~/.claude/skills/`, it auto-activates on matching operator messages and is loaded into context exactly when needed. It's the operator-facing counterpart to Commander's `CLAUDE.md`.

## Goals

- Ship a `skills/hydra-operator/` skill in this repo, with `SKILL.md` (decision prompt) + `README.md` (install/verify/troubleshoot).
- Claude Code's skill-loader fires the skill on the natural-language operator phrases that map to `hydra.*` MCP tools (pick up / status / merge / reject / pause / resume / kill / retro) and on inbound `supervisor.resolve_question` callbacks from Commander.
- The skill enforces safety boundaries that policy already mandates: never auto-approve T2 merges, refuse T3 outright, never guess `pick_up_specific` parameters.
- Install path is a single `cp -r skills/hydra-operator ~/.claude/skills/` command, verifiable with `claude --list-skills`.
- An index `skills/README.md` documents the convention so future Main-Agent skills (e.g. a future `hydra-retro-reader`) can be added in the same shape.
- `README.md` (root) points operators at the skill install step as a follow-up to the main install flow.
- Script-kind self-test case (`hydra-operator-skill-valid`) validates frontmatter + install-smoke so future edits don't silently break discovery.

## Non-goals

- **Not implementing the MCP server binary.** That's ticket #52. This skill is useful the moment #52 lands; until then it sits dormant in the operator's skills dir.
- **Not editing policy or worker subagents.** The skill is strictly Main-Agent-side; Commander's behavior is unchanged.
- **Not a codex-equivalent skill.** Operators on Codex CLI read the prompt manually. Follow-up when Codex skill format stabilizes.
- **Not auto-installing.** Operators opt in with the explicit `cp -r` command — we don't modify their `~/.claude/` during `./setup.sh`.
- **Not extending the MCP tool contract.** `mcp/hydra-tools.json` is unchanged. The skill consumes the existing surface.

## Proposed approach

Standard Claude Code skill layout under `skills/hydra-operator/`:

```
skills/
├── README.md                 index + conventions
└── hydra-operator/
    ├── SKILL.md              frontmatter + decision prompt
    └── README.md             install / verify / troubleshoot
```

`SKILL.md` frontmatter declares:

- `name: hydra-operator`
- `description:` tuned for the dispatch / status / merge / pause phrases plus inbound `supervisor.resolve_question` matching
- `mcpServers: [hydra]` so Claude Code checks the MCP server is connected before firing

The body is a verb-mapping table + rules section (no T2 auto-approve, no T3 merges, no parameter guessing on `pick_up_specific`) + a short inbound-escalation protocol for `supervisor.resolve_question`.

Install is a manual `cp -r` into `~/.claude/skills/`. Intentional: we don't want `./setup.sh` reaching into the operator's dotfiles without consent, and we don't want auto-update fights if an operator has customized the skill locally.

### Alternatives considered

- **Alternative A: bake the operator verbs into Commander's `CLAUDE.md` and rely on the Main Agent reading the repo.** Rejected — Main Agent doesn't have Commander's repo in context by default, and even if it did, Commander's prompt is the wrong place for operator-facing decision trees.
- **Alternative B: write the skill as a project-scoped `.claude/skills/hydra-operator/` entry in every operator's external repo.** Rejected — per-repo duplication, plus project-scoped skills only fire in that project's sessions. Operator-facing verbs should work in any Claude Code session.
- **Alternative C: auto-copy during `./setup.sh`.** Rejected for consent reasons (see above) and because `~/.claude/skills/` is user-scoped; writing there from a repo installer violates the least-surprise principle.

## Test plan

- `bash -n` on any shell in the skill directory (none today — declarative only).
- Frontmatter check: `head -20 skills/hydra-operator/SKILL.md | grep -E 'name:|description:|mcpServers:'` → 3 matches.
- `jq . self-test/golden-cases.example.json` → valid JSON after adding the new `hydra-operator-skill-valid` case.
- Install smoke: copying the directory into a fake skills dir yields a readable `SKILL.md`.
- Self-test harness: `./self-test/run.sh --case hydra-operator-skill-valid` runs the 3 script steps and exits 0 on a clean worktree.

The self-test case is the important one for preventing future regressions — edits to the frontmatter that break Claude Code's skill discovery will now fail the self-test before they land.

## Risks / rollback

- **Claude Code's skill format evolves and the frontmatter schema changes.** Mitigation: the self-test exercises the required fields, so a mismatch fails loudly. Rollback: edit `SKILL.md` frontmatter to match the new schema, re-run self-test.
- **Operator installs the skill but has no MCP server configured.** Mitigation: the `README.md` troubleshooting section covers this explicitly with a `./hydra mcp serve` pointer.
- **Skill description is too broad and fires on unrelated messages.** Mitigation: the phrases are anchored to Hydra-shaped verbs (`pick up`, `merge #`, `pause`, `status`). If operators report spurious activation, tighten the description in a follow-up.
- **Rollback:** `rm -rf ~/.claude/skills/hydra-operator` on the operator side; revert this PR's commits in the repo. No state outside the skill directory.

## Implementation notes

- Skill location chosen: `skills/` at repo root, not under `.claude/skills/`. Rationale: `.claude/skills/` is reserved for worker-subagent skills (promoted automatically by the memory pipeline). Main-Agent skills are operator-scoped and shouldn't mix.
- The `skills/README.md` index documents this distinction so the next contributor doesn't accidentally add a Main-Agent skill under `.claude/skills/`.
- Root `README.md` install section was updated with a single pointer line; full install docs (INSTALL.md) were intentionally not touched to keep the PR narrow.
