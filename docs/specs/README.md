# Specs

Every non-trivial change to Hydra (framework, policy, worker prompts, permissions) gets a spec in this directory **before** code is written.

This is spec-driven programming. The spec is a compounding artifact: it explains **why** a decision was made so future contributors (human or AI) can revisit the reasoning, not just the code.

## Convention

- Filename: `YYYY-MM-DD-<short-slug>.md`
- Frontmatter: `status: draft | approved | implemented | superseded`
- Required sections:
  - **Problem** — why now, what's broken or missing
  - **Goals + non-goals** — scope fence
  - **Proposed approach** — plus 1-2 alternatives considered, with tradeoffs
  - **Test plan** — how we'll know it works (and didn't regress anything)
  - **Risks / rollback** — what could go wrong, how we back out
- Body is usually 200-800 words. If you need more, the scope is probably too big — split the spec.

## When to write a spec

- Any change to `CLAUDE.md`, `policy.md`, worker subagents, or permission profile
- Any new worker type
- Any new ticket-source adapter (Linear, Jira, etc.)
- Any change to the memory lifecycle, escalation protocol, or self-test harness
- Any architecture change for Phase 2 migration

**Skip the spec** for: typo fixes, comment edits, obvious bug fixes with <10 LOC changed, dep-patch bumps.

## When an implementation PR lands

- Update the spec's frontmatter: `status: implemented`
- Add a trailing section `## Implementation notes` capturing anything that surprised you during implementation (things that will matter for future edits)

## When a spec is replaced

- Don't delete. Change `status: superseded` and add `## Superseded by` with a link to the new spec.

## Existing specs

**Implemented (Phase 1):**
- `../superpowers/specs/2026-04-16-commander-agent-design.md` — foundational design doc for Hydra (pre-rebrand; status: implemented)

**Draft / awaiting implementation** (candidates for "Hydra builds Hydra" — file as issues and let a worker take them):
- `2026-04-16-retro-workflow.md` — weekly retro command that learns from shipped work
- `2026-04-16-scheduled-autopickup.md` — cron-ish auto-pickup so Hydra runs while you sleep
- `../phase2-s3-knowledge-store.md` — S3 Files knowledge-store plan (Phase 2)
