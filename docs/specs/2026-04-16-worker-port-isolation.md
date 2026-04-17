---
status: draft
date: 2026-04-16
author: hydra worker (ticket #60)
---

# Worker port isolation for parallel docker-compose workers

## Problem

When two workers run in parallel against repos that use `docker compose` for testing, both invoke `docker compose up` against the same host. Most `docker-compose.yml` files bind well-known ports to the host — `5432:5432` (postgres), `6379:6379` (redis), `3000:3000` (web), `8080:8080`, etc. Whichever worker starts second fails with `bind: address already in use`, the test run crashes, and the ticket fails for a reason unrelated to the worker's code change.

Observed signal:

- `memory/escalation-faq.md` already tells workers to `docker compose down` on exit (line 106-109), but that's cleanup hygiene, not isolation. Even two workers that both clean up properly still collide while they're simultaneously running.
- `budget.json:phase1_subscription_caps.max_concurrent_workers` is 3. As soon as two of those three workers pick up repos with overlapping compose services, one of them breaks.
- The project's directional goal (CLAUDE.md, "Parallel issue-clearing") is N tickets in flight concurrently. Port collisions are a ceiling on that N.

This is a Phase 1 problem. Phase 2 plans one cloud sandbox per worker (see Layer 3 below), which side-steps it entirely — but we cannot wait for the cloud migration.

## Goals / non-goals

**Goals**

- Two (or more, up to `max_concurrent_workers`) `worker-implementation` subagents can each run `docker compose up` against the same compose file on the same host without port collisions.
- Each worker's containers are namespaced so `docker ps` clearly shows which worker owns which container, and `docker compose down -v` at end-of-ticket tears down **only that worker's** stack.
- The pattern is documented in `.claude/agents/worker-implementation.md` so workers apply it automatically, and a helper script (`scripts/alloc-worker-port.sh`) owns the port-allocation logic — workers do not reinvent it per ticket.
- Self-test coverage: a golden-case script exercises the allocator against a fixture with a known-taken port, and a Docker-gated integration smoke brings two compose stacks up in parallel against the same compose file and asserts both land.

**Non-goals**

- **Layer 3 (cloud sandbox per worker).** Out of scope for this ticket. That's a Phase 2 initiative requiring VPS / managed sandbox provisioning; it's called out here only to signal that the Phase-1 fix is a bridge, not the end state.
- **Modifying any target repo's `docker-compose.yml` in place.** The fix generates a runtime `docker-compose.override.yml` in the worker's worktree; it never touches the committed compose file of the repo under test.
- **Picking ports "optimally."** A simple deterministic-range + probe-next-free algorithm is enough. No port-pool manager, no distributed leader election.
- **Supporting non-Docker isolation** (e.g., native postgres on the host). The reported failure mode is specifically `docker compose up` collisions; workers that run services natively are rare enough to stay a manual case.

## Proposed approach

Two layers, applied together:

### Layer 1 — namespace the compose project

Before `docker compose up`, the worker exports:

```
COMPOSE_PROJECT_NAME=hydra-worker-<worker-id>
```

Docker Compose uses this prefix for container names, the default network, and named volumes. Two workers invoking `docker compose up` with different `COMPOSE_PROJECT_NAME` values get fully independent container graphs — no container-name collision, no network collision, independent volume lifecycles. `docker compose down -v` then tears down only that worker's graph.

Layer 1 is free: one env var, no generated files, no port logic. It solves *container-name* collisions but **not** host-port collisions: two `pg` containers both still try to publish `5432:5432` on the host.

### Layer 2 — remap host-side ports to a worker-scoped range

The host-port collision is what Layer 2 solves. On top of `COMPOSE_PROJECT_NAME`, the worker:

1. Reads the target repo's `docker-compose.yml` and enumerates `services[*].ports[]` entries that publish a host port (lines of the form `"5432:5432"`, `"8080:80"`, `"${PG_PORT:-5432}:5432"`, etc.).
2. For each host port it finds, it asks `scripts/alloc-worker-port.sh` for a free port drawn from the worker's scoped range: `40000 + worker_slot * 100` through `40000 + (worker_slot + 1) * 100 - 1`, where `worker_slot` is a small integer in `[0, max_concurrent_workers)`. The allocator probes each candidate with `nc -z 127.0.0.1 <port>` (or the `bash</dev/tcp` idiom as a fallback) and returns the first that's free.
3. Writes a `docker-compose.override.yml` **in the worktree** (not in the target repo's committed tree) that remaps published ports to the allocated ones. Compose auto-merges `docker-compose.override.yml` with `docker-compose.yml`, so no flags are needed at `up` time.
4. Exports the chosen ports as env vars — `HYDRA_PG_PORT`, `HYDRA_WEB_PORT`, etc. — so the worker's test code can reach the services.
5. On exit (success, failure, timeout — any exit), runs `docker compose down -v` with the same `COMPOSE_PROJECT_NAME` in scope. This is required by `memory/escalation-faq.md` already; Layer 2 just inherits the existing rule.

Port range math:

| Worker slot | Range          | Notes                                                |
|-------------|----------------|------------------------------------------------------|
| 0           | 40000–40099    | First worker; avoids IANA registered ports (<32768)  |
| 1           | 40100–40199    | Second worker                                        |
| 2           | 40200–40299    | Third worker (matches current `max_concurrent_workers=3`) |
| 3+          | 40300+         | Grows if the cap grows; 100 ports per slot is enough for any sane compose file |

40000–40299 is below the ephemeral-port range on Linux (`net.ipv4.ip_local_port_range` default 32768–60999 on most distros) and on macOS (49152–65535), so the worker range does not clash with the kernel's ephemeral allocator.

The `worker_slot` comes from the position of the worker's ID in `state/active.json:workers[]` at spawn time. A worker with no slot assigned (e.g., run outside Commander's spawn path, or the self-test harness) falls back to slot 0 with a warning.

### Alternatives considered

- **Alternative A: Rely on `COMPOSE_PROJECT_NAME` alone (Layer 1 only).** Cheaper — no script, no override file — but does not solve host-port collisions. Host ports live outside Compose's naming scope. Rejected.
- **Alternative B: Pick a random ephemeral port per service.** Ask the kernel for an unused port via `bash -c 'echo $(</dev/tcp/0.0.0.0/0)'` or `python -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1])"`. Simpler allocator, no slot math. Rejected: the allocated port would be unpredictable across a worker's lifetime (the env var is stable but the port value wouldn't match anything in the worker's logs or its generated override file if we regenerated), and harder for the operator to eyeball what's running from `docker ps`. Deterministic scoped ranges make `docker ps` + `lsof -iTCP:40100-40199` trivially readable.
- **Alternative C: One docker host per worker (container-in-container or nested VM).** The cleanest isolation, but heavyweight — boot time dominates, and the Phase-1 deployment story is "operator runs Hydra on their own mac/linux box," where nested docker is painful. Defer to Phase 2's cloud-sandbox-per-worker design.
- **Alternative D: Patch the compose file in-place per worker.** Simpler than generating an override (one file, no merge semantics), but mutates files inside the target-repo worktree, which pollutes `git status`, risks accidental commits of the mutated ports, and fights with any preflight `git diff`-based reviewer. The override-file approach keeps the target repo pristine.

## Test plan

Three layers of testing, matching the ticket's acceptance criteria:

1. **Unit test — port allocator against a known-taken port.** Fixture driver `self-test/fixtures/worker-port-isolation/run.sh` opens a listener on one port in the worker's range, then invokes `scripts/alloc-worker-port.sh --worker-slot 0 --service pg --desired-port <taken>` and asserts the returned port is different from the taken one and falls within slot 0's range. Runs locally; no Docker needed. Wired as a step in the `worker-port-isolation-allocator` golden case.

2. **Integration smoke — two dummy workers in parallel on the same compose file.** Fixture driver `self-test/fixtures/worker-port-isolation/parallel-smoke.sh` stages two worktrees with copies of a fixture compose file that binds `5432:5432`, launches `docker compose up -d` in each with `COMPOSE_PROJECT_NAME=hydra-worker-A` / `B` and a generated override remapping the host port, asserts both stacks come up with `docker ps` showing two containers, then tears both down. Marked `requires_docker` so the case SKIPs on CI (which has `HYDRA_CI_SKIP_DOCKER=1` set per `.github/workflows/ci.yml`). Runs locally on operator machines that have Docker.

3. **Regression check — no orphans after both workers exit.** The parallel-smoke driver runs `docker ps --filter name=hydra-worker-` **after** both `docker compose down -v` calls and asserts zero matching containers. Prevents the "forgot to clean up" failure mode.

All three go in a single golden case `worker-port-isolation` under `self-test/golden-cases.example.json` with `kind: script`, matching the existing `release-script-smoke` / `memory-validators` pattern. The allocator unit test runs on CI; the parallel-smoke + regression steps are gated on `requires_docker`.

No Tier-2 "tests on the target repo" story: the fix lives entirely in Hydra's own framework + scripts layer, so its tests live in Hydra's self-test harness.

## Risks / rollback

- **Risk: port exhaustion in a slot range.** A slot has 100 ports. If a compose file publishes >100 host ports, the allocator fails and the worker falls back to the legacy behavior (set `COMPOSE_PROJECT_NAME`, skip Layer 2, warn the operator). The fallback is documented in `.claude/agents/worker-implementation.md`. Unlikely in practice — typical compose files publish 1-4 ports.
- **Risk: the target repo's test code hardcodes `localhost:5432`.** When we remap to 40042, the test can't connect. Workers already need to read `HYDRA_PG_PORT` / equivalent env vars; repos that hardcode ports will fail loudly and the worker can fall back to "no override, serial execution" (document as known limitation). The commander can also serialize work on that repo via a per-repo `concurrency: 1` knob in `state/repos.json` as a future mitigation — out of scope for this ticket.
- **Risk: override file leaks into the target repo's git index.** The worker writes the override in the worktree but `.gitignore` in the target repo doesn't know about `docker-compose.override.yml`. Mitigation: the worker-implementation doc explicitly says "write `docker-compose.override.yml`; before commit, verify it is NOT in `git status -s`; if it is, delete or add to `.git/info/exclude` (local-only, not committed)." The self-test's `must_not_touch_paths` assertion on future worker-implementation runs will catch accidental commits.
- **Risk: `nc` or `/dev/tcp` not available.** `nc` is on every mainstream distro + macOS; `/dev/tcp` is a bash builtin always available under bash. The allocator tries `nc` first, falls back to bash's `</dev/tcp`, and errors with a clear message if neither works. Tested in the unit case.
- **Rollback:** revert the PR. Workers fall back to pre-change behavior (no `COMPOSE_PROJECT_NAME`, no override) and the operator runs one worker at a time until a fix re-lands. No state-migration risk — the script is stateless and the worker-implementation doc section is additive.

## Implementation notes

(Fill in after the PR lands.)
