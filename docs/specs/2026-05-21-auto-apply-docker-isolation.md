---
status: draft
date: 2026-05-21
author: hydra worker (ticket #178)
implements: tonychang04/hydra#178
---

# Auto-apply docker worktree isolation at worker spawn

## Problem

Worker docker-isolation rules — Layer 1 (Compose project namespacing) and
Layer 2 (host-port remapping) — are documented in
`.claude/agents/worker-implementation.md` ("Docker isolation for parallel
workers") and the spec `docs/specs/2026-04-16-worker-port-isolation.md`. Both
layers are **delegated to the worker**: the worker is expected to remember to
export `COMPOSE_PROJECT_NAME`, enumerate the compose file's published ports,
call `scripts/alloc-worker-port.sh` per service, and hand-write a
`docker-compose.override.yml` with `ports: !override`.

That delegation is fragile. If a worker forgets, skips, or botches Layer 2 (the
`!override` idiom is the documented #1 failure mode), two parallel workers
publish the same host port (`5432:5432`, `3000:3000`, …) and the second
`docker compose up` dies with `bind: address already in use`. The ticket then
fails for a reason unrelated to its code change. Parallel issue-clearing is
Hydra's core job (CLAUDE.md, "parallel issue-clearing"), so silent host-port
collisions are a direct ceiling on throughput — a P1 safety/observability gap.

`scripts/alloc-worker-port.sh` already owns the "pick a free slot-scoped port"
half of the fix. What's missing is a non-delegated step that *applies* the
override automatically at spawn time, so isolation happens whether or not the
worker thinks about it.

## Goals / non-goals

**Goals**

- A Commander-side helper, `scripts/auto-apply-docker-isolation.sh`, that, given
  a target repo path and a worker slot, scaffolds a `docker-compose.override.yml`
  in the worker's worktree root: namespaced Compose project + every published
  host port remapped via `alloc-worker-port.sh`, using `ports: !override`.
- **Idempotent.** Re-running it on an already-isolated worktree produces the
  same override (overwrites a Hydra-authored file) and does not stack ports.
- **No-op when there is no `docker-compose.yml`** in the target repo — exit 0,
  write nothing.
- **No-op when `HYDRA_WORKER_SLOT` is unset** (run outside Commander's spawn
  path), unless an explicit `--worker-slot` flag is passed — exit 0, write
  nothing. This keeps the helper from scaffolding overrides in contexts where
  there is no parallelism to protect.
- **Graceful fallback:** if port allocation fails for any service (slot range
  exhausted, probe tool missing), log a warning and continue. The helper exits
  0 so the spawn is never aborted — the worker hits/retries the collision rather
  than the spawn dying. This matches the ticket's explicit requirement.
- Document the spawn-time hook in `.claude/agents/worker-implementation.md`
  (extend the existing "Docker isolation" section in place) so the worker knows
  the override may already exist and must not double-apply.
- A regression test (`scripts/test-auto-apply-docker-isolation.sh`) mirroring
  the existing `scripts/test-*.sh` style.

**Non-goals**

- **Replacing `alloc-worker-port.sh`.** This helper *calls* it; it does not
  reimplement port probing or slot math.
- **Running `docker compose up` / `down`.** The helper only scaffolds the
  override file + emits the env exports a caller should source. Bring-up,
  teardown, and the `down -v` trap stay the worker's responsibility (unchanged
  from the existing doc + escalation-faq cleanup rule).
- **Parsing arbitrary compose YAML perfectly.** No `yq` is available on the
  operator host. The helper uses a deterministic line-scan for `ports:` entries
  of the documented shapes (`"5432:5432"`, `5432:5432`, `"${PG_PORT:-5432}:5432"`,
  `"127.0.0.1:5432:5432"`). Exotic long-form `ports:` mappings (the
  `- target:`/`published:` dict form) fall through to the graceful-fallback
  warning rather than being silently mishandled.
- **Modifying the target repo's committed `docker-compose.yml`.** The override
  is written to the worktree root only; the committed compose file is never
  touched (same guardrail as the worker-implementation doc).
- **Layer 3 (cloud sandbox per worker).** Out of scope; Phase 2.

## Proposed approach

`scripts/auto-apply-docker-isolation.sh` (bash, `set -euo pipefail`):

1. **Args:** `--worktree <abs path>` (the worktree root; the override is written
   here — default `$PWD`), `--repo-path <abs path>` (where `docker-compose.yml`
   lives — default the worktree), `--worker-slot <N>` (default
   `$HYDRA_WORKER_SLOT`), `--worker-id <id>` (default `$HYDRA_WORKER_ID`, else
   `worker-$$`), `--compose-file <name>` (default `docker-compose.yml`),
   `--allocator <path>` (default the sibling `alloc-worker-port.sh`), and a
   `--quiet` flag. `-h/--help`.
2. **No-op gates:**
   - If `<repo-path>/<compose-file>` does not exist → log "no compose file,
     skipping" (suppressed under `--quiet`) and exit 0.
   - If no slot is resolvable (neither flag nor `HYDRA_WORKER_SLOT`) → log
     "no worker slot, skipping isolation" and exit 0.
3. **Layer 1 — project name:** compute
   `COMPOSE_PROJECT_NAME=hydra-<sanitized worker-id>` (lowercase,
   `[a-z0-9_-]` only) exactly as the worker doc prescribes. Emitted as an
   `export …` line on stdout (so a caller can `eval`/source it) and written as a
   comment header in the override file.
4. **Enumerate published ports:** line-scan the compose file. For each service
   block, collect `ports:` list entries that publish a host port. Capture, per
   entry: the service name, the host-side token, and the container port. Skip
   entries that don't publish a host port (single-value `- "5432"` short form
   binds an ephemeral host port already → no collision to fix → skip).
5. **Allocate + build override:** for each `(service, host, container)`, call
   `alloc-worker-port.sh --worker-slot <slot> --service <service>
   --desired-port <40000 + slot*100 + (host mod 100)>`.
   - On success, record `service → "<allocated>:<container>"`.
   - On allocator failure (non-zero exit), log a warning naming the service and
     **continue** (graceful fallback). That service is omitted from the override
     (its base binding stays, which may collide — but the spawn proceeds, per
     the ticket).
6. **Write override:** if at least one port was allocated, write
   `<worktree>/docker-compose.override.yml` with a generated-by header comment,
   then per service a `ports: !override` block with the remapped entries. If
   *zero* ports were allocated (all failed, or the compose file published none),
   write no file and exit 0 — there is nothing to isolate. (Idempotency:
   the file is always fully regenerated, never appended to.)
7. **Emit env exports** on stdout: `COMPOSE_PROJECT_NAME`, and one
   `HYDRA_<SERVICE>_PORT=<allocated>` per allocated service, so a caller can
   `eval "$(auto-apply-docker-isolation.sh …)"` and have the ports in its env.
   All human-readable logging goes to stderr so stdout stays eval-safe.

**Exit codes:** `0` success or any graceful-fallback path (no compose / no slot
/ partial alloc failure / all alloc failed); `2` usage error (bad flags). There
is intentionally no failure exit for allocation problems — the whole point is to
never abort the spawn.

### Wiring (documentation, not code)

The ticket's conflict-avoidance rule restricts code edits to the script + test +
`worker-implementation.md` + this spec. The actual spawn path lives in
Commander's `Agent(...)` invocation flow, which other tickets own. So this PR
**documents** the hook in `worker-implementation.md`: a worker that finds a
Hydra-generated `docker-compose.override.yml` already in its worktree must treat
Layer 2 as already applied (read `HYDRA_*_PORT` / `COMPOSE_PROJECT_NAME` from
the emitted exports rather than hand-writing a second override). A PR note will
flag that the Commander spawn path should `eval` this helper before handing the
worktree to the worker — a one-line CLAUDE.md/spawn-flow pointer for a later
ticket (CLAUDE.md is owned by another worker per the conflict-avoidance rule).

### Alternatives considered

- **A: Make the worker call the helper itself.** That's still delegation — the
  failure mode (worker forgets) survives. Rejected; the point is to remove the
  worker from the critical path.
- **B: Parse compose with a YAML lib / `yq`.** No `yq` on the host and adding a
  Python/Node dependency for a 3-shape line-scan is overkill. The existing
  ecosystem (alloc-worker-port.sh, the validators) is pure bash+jq. Rejected;
  line-scan with explicit fallback for the long-form case.
- **C: Mutate the compose file in place.** Pollutes `git status`, risks an
  accidental commit, fights the worker-review gate. Same rejection as
  Alternative D in the port-isolation spec. Rejected.

## Test plan

`scripts/test-auto-apply-docker-isolation.sh`, bash, mirroring
`scripts/test-check-claude-md-size.sh` (colored `say`/`ok`/`bad`, pass/fail
counter, mktemp tmpdir + trap cleanup, summary). A stub allocator is dropped in
the tmpdir so tests are hermetic (no real port probing) and a "failing
allocator" stub exercises the fallback path. Cases:

1. **Compose present → override written.** Fixture compose binds `5432:5432`
   and `3000:3000`; run with `--worker-slot 0` and a stub allocator returning
   deterministic ports. Assert `docker-compose.override.yml` is created in the
   worktree, contains `ports: !override`, contains both remapped host ports, and
   does NOT contain the original `5432:5432` host binding for the remapped
   service. Assert stdout has the `COMPOSE_PROJECT_NAME` + `HYDRA_*_PORT`
   exports.
2. **Compose absent → no-op.** Empty repo dir, `--worker-slot 0`. Assert exit 0,
   no override file written, a "no compose" message on stderr.
3. **Allocation failure → logs + exit 0.** Stub allocator that always exits 1.
   Assert exit 0, a warning naming the service on stderr, and (since every alloc
   failed) no override file written.
4. **No slot → no-op.** Compose present but no `--worker-slot` and
   `HYDRA_WORKER_SLOT` unset. Assert exit 0, no file, a "no slot" message.
5. **Idempotency.** Run case 1 twice; assert the second run's override file is
   byte-identical to the first (no port stacking, no duplicate service blocks).
6. **Long-form ports fall through gracefully.** Compose with only the dict-form
   `- target:/published:` mapping → helper logs an unsupported-shape warning and
   exits 0 without writing a (wrong) override.

Run locally: `bash scripts/test-auto-apply-docker-isolation.sh`. No Docker
required — the allocator is stubbed and no `docker compose` is invoked.

## Risks / rollback

- **Risk: line-scan misreads an exotic `ports:` shape.** Mitigated by the
  long-form fall-through (case 6): unrecognized shapes warn + skip rather than
  emit a malformed override. Worst case is the same as today (no Layer 2 for
  that service), never worse.
- **Risk: the helper isn't actually wired into the spawn path by this PR.** True
  by design — the spawn-flow edit lives in code another worker owns. This PR
  ships the helper + test + worker-doc hook; the PR body flags the one-line
  spawn-flow wiring as a follow-up. Until wired, the helper is callable
  manually and the worker doc tells workers to honor a pre-existing override.
- **Risk: stdout pollution breaks `eval`.** Mitigated: all logging goes to
  stderr; stdout carries only `export …` lines. The test asserts stdout is
  eval-safe (only export lines).
- **Rollback:** revert the PR. The helper is stateless and additive; workers
  fall back to the existing hand-written Layer-2 procedure (unchanged in the
  doc), and the doc hook is purely additive guidance.
