# Commander Memory Index

One-line pointer per memory file. Keep under 200 lines total.

## How commander uses this

Read at session start. Each line → one discoverable memory file under `memory/`. Workers also read this to inherit cross-ticket learnings before starting work.

## Per-repo learnings (populated by workers after each ticket)

- [InsForge learnings](learnings-InsForge.md) — patterns, test commands, gotchas for the core InsForge repo
- [insforge-cloud learnings](learnings-insforge-cloud.md) — cloud-specific
- [insforge-cloud-backend learnings](learnings-insforge-cloud-backend.md) — backend-specific
- [insforge-content-management-system learnings](learnings-insforge-content-management-system.md) — CMS-specific
- [InsForge-sdk-js learnings](learnings-InsForge-sdk-js.md) — SDK-specific
- [CLI learnings](learnings-CLI.md) — CLI-specific (Stage 0 validated 2026-04-16)
- [insforge-standalone learnings](learnings-insforge-standalone.md)
- [insforge-skills learnings](learnings-insforge-skills.md)

## Operating rules (stable)

- [Escalation FAQ](escalation-faq.md) — answers to recurring worker questions (commander scans this first before pinging Gary)
- [Tier classification edge cases](tier-edge-cases.md) — tickets that looked T1 but were really T3, etc. (populated over time)
- [Worker failure modes](worker-failures.md) — recurring ways workers get stuck (populated over time)
