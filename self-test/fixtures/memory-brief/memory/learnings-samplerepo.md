---
name: learnings-samplerepo
description: Fixture — samplerepo learnings used by the memory-brief builder self-test.
type: feedback
---

# learnings-samplerepo (fixture)

Fixture for `scripts/build-memory-brief.sh`. Seeded with three well-known quoted substrings so the brief builder can rank them by citation count deterministically.

## Conventions

- 2026-04-16 #101 — Always run tests inside docker compose; local installs drift.
- 2026-04-16 #102 — Commit the spec before code; keeps "why" atomic.

## Test commands

- `pnpm test` — unit tests (Vitest).
- `docker compose up -d && curl http://localhost:9000/health` — smoke test.

## Known gotchas

- npm install strips peer markers from `package-lock.json`. Revert before commit.
- Host-level postcss.config.js pollutes Vite in fresh worktrees — stub it.
- `DATABASE_URL` defaults to sqlite in tests; integration needs postgres up.
