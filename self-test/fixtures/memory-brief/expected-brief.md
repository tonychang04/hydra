## Top repo learnings (by citation count)

- docker compose up -d — cited 10 times (last: 2026-04-17)
- npm install strips peer markers — cited 7 times (last: 2026-04-17)
- Commit the spec before code — cited 5 times (last: 2026-04-16)
- Always run tests inside docker compose — cited 3 times (last: 2026-04-16)
- Host-level postcss.config.js pollutes Vite — cited 2 times (last: 2026-04-10)

## Cross-repo patterns (top 3, last 30 days)

- `learnings-otherrepo.md#"Stream idle timeout around 18 minutes"` — cited 15 times (last: 2026-04-17)
- `learnings-samplerepo.md#"docker compose up -d"` — cited 10 times (last: 2026-04-17)
- `learnings-otherrepo.md#"Redis port 6379 collides on parallel workers"` — cited 9 times (last: 2026-04-15)

## Escalation FAQ (scoped)

- **Q:** Broken lint on baseline — fix it here? → **A:** NO. Note it; do not bundle unrelated fixes.
- **Q:** pnpm workspace has stale symlink → **A:** `pnpm install --force` then retry.
- **Q:** Stream idle timeout at ~18 min → **A:** Commander's watchdog rescues; no action from the worker.
- **Q:** Lockfile drift from npm install → **A:** Revert lockfile changes before committing unless ticket is about deps.

## Latest retro — citation leaderboard

- `learnings-samplerepo.md#"docker compose up -d"` — cited 5 times this week.
- `learnings-samplerepo.md#"npm install strips peer markers"` — cited 4 times.
- `learnings-otherrepo.md#"Stream idle timeout around 18 minutes"` — cited 3 times.
