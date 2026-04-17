---
name: learnings-sample
description: Fixture — validly-shaped learnings file used by the memory validator self-test.
type: feedback
---

# learnings-sample (fixture)

Fixture for `scripts/validate-learning-entry.sh`. This file must pass the validator.

## Conventions

- 2026-04-16 #50 — Use `pnpm` in this fixture repo; `npm install` drifts the lockfile.
- 2026-04-16 #51 — Commit specs before code changes so the "why" is atomic.

## Test commands

- `pnpm test` — unit tests (Vitest).
- `pnpm build` — production build.
- `docker compose up -d && curl http://localhost:8080/health` — smoke test the API.

## Known gotchas

- npm install strips peer markers from `package-lock.json`. Revert before commit.
- Host-level `postcss.config.js` can be picked up by Vite in a fresh worktree; stub it with an empty plugins list while testing, then delete the stub before committing.
