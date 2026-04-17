---
name: learnings-otherrepo
description: Fixture — second repo learnings, used to verify cross-repo patterns + repo-scoping.
type: feedback
---

# learnings-otherrepo (fixture)

Used to prove that learnings for another repo DO NOT show up in the samplerepo brief's `## Top repo learnings` section, but MAY show up in `## Cross-repo patterns` if their citation count is high enough globally.

## Conventions

- 2026-04-16 #201 — Use pnpm, not npm, in this repo.

## Known gotchas

- Stream idle timeout around 18 minutes — chunk long tasks.
- Redis port 6379 collides on parallel workers; remap with docker-compose.override.yml.
