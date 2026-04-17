# fixture-repo

Tiny fixture for the `worker-test-discovery` self-test case (`test-discovery-dormant-to-active`).

This is deliberately a minimal service-shell repo:

- `docker-compose.yml` spins up a single Redis container on port 6379.
- `.env.example` declares a handful of placeholder vars.
- `package.json` is a stub (no `scripts.test`).

It is **intentionally missing** any testing documentation (`TESTING.md`, CLAUDE.md, or a README "Testing" section). That is the point — the self-test asks `worker-test-discovery` to discover the test procedure and open a PR adding `TESTING.md` with the real `docker compose up` + `redis-cli ping` (or `curl localhost:6379`) verify steps.

## What it does

Starts Redis. Nothing else.

## Not-yet-documented

How to verify it works. That's the worker's job.
