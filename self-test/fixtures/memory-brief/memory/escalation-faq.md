---
name: Worker escalation FAQ (fixture)
description: Fixture escalation-faq with per-entry Scope tags; used by memory-brief builder self-test.
type: feedback
---

# Worker Escalation FAQ (fixture)

Fixture. Each entry has an optional `Scope:` line. Absent = global default. The builder should include scopes matching `samplerepo`, `global`, or absent — and exclude entries scoped to `otherrepo` only.

## Scope samplerepo

### Broken lint on baseline — fix it here?

- **Context:** lint command fails on a baseline run.
- **Answer:** NO. Note it; do not bundle unrelated fixes.
- **Source:** samplerepo#101
- **Scope:** samplerepo

### pnpm workspace has stale symlink

- **Context:** fresh clone sometimes leaves stale node_modules links.
- **Answer:** `pnpm install --force` then retry.
- **Source:** samplerepo#105
- **Scope:** samplerepo

## Global

### Stream idle timeout at ~18 min

- **Context:** worker emits partial output then silence.
- **Answer:** Commander's watchdog rescues; no action from the worker.
- **Source:** hydra#45
- **Scope:** global

### Lockfile drift from npm install

- **Context:** package-lock.json changes on every npm i.
- **Answer:** Revert lockfile changes before committing unless ticket is about deps.
- **Source:** CLI#50

## Scope otherrepo

### Redis port 6379 collides on parallel workers

- **Context:** two workers both bring up redis.
- **Answer:** Use docker-compose.override.yml with a slot-scoped host port.
- **Source:** otherrepo#201
- **Scope:** otherrepo
