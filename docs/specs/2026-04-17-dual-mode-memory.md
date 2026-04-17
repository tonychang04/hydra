---
status: draft
date: 2026-04-17
author: hydra worker (commander/103)
---

# Dual-mode memory: local ↔ S3 sync via `aws s3 sync`

Implements #103. Operator explicitly: "transfer and make a copy of the local memory to the s3 file based memory in the future make sure both works but you can use s3 memory."

## Problem

Hydra's framework + operational memory lives in `./memory/` today (Phase 1). Workers and commander read+write plain files there. A one-shot `aws s3 cp` run (commander, 2026-04-17) copied `./memory/` to `s3://hydra-mem-test-1776444672/gary-laptop/memory/` — 11 files, 41 KiB, verified. That proves the wire works but is a one-shot, not a mode.

For Phase 2 / multi-commander operation we need:

1. **Local stays first-class.** Most operators run one commander on one laptop; forcing them onto S3 for memory is overkill.
2. **S3 becomes a supported backend** so a cloud commander (Fly, VPS) can share memory with the operator's laptop without the operator FUSE-mounting a bucket.
3. **Sync is bidirectional** so both commanders see each other's writes without a conflict-resolution layer — single-writer at any moment, but the writer can migrate (laptop today, Fly next week).
4. **Graceful degradation.** If S3 is unreachable, commander shouldn't wedge — the working copy on disk is the source of truth for the current tick. The sync is the backup, not the critical path.

The existing `scripts/memory-mount.sh` (mount-s3 / FUSE) is the alternative path and stays supported. It's overkill for operators who just want a daily mirror, and mount-s3 has install friction (macOS kext / FUSE permissions, daemon management). `aws s3 sync` is already installed (`aws` CLI is a Phase-2 prerequisite) and works without a daemon.

## Goals / non-goals

**Goals:**

- `scripts/hydra-memory-sync.sh` — one script, two modes: `--push` (local → S3) and `--pull` (S3 → local). Idempotent. Uses `aws s3 sync`. Logs which files changed.
- `HYDRA_MEMORY_BACKEND` env var with values `local | s3 | s3-strict`. Default `local` (bit-for-bit Phase-1 behavior).
- Memory-layer scripts (`parse-citations.sh`, `validate-learning-entry.sh`, `validate-citations.sh`) gain **one** new conditional each: on successful exit, if `HYDRA_MEMORY_BACKEND=s3` (or `s3-strict`), invoke `hydra-memory-sync.sh --push`. Nothing else changes in those scripts.
- Commander startup (`./hydra` launcher + `infra/entrypoint.sh`) adds a preflight: if backend is `s3` (or `s3-strict`), run `hydra-memory-sync.sh --pull` before anything else.
- `s3-strict` mode hard-fails on S3 unreachable. `s3` mode warns and continues with local only.
- Self-test `memory-sync-roundtrip` (kind `script`, `requires_docker`) — uses the localstack S3 from #34's `self-test/fixtures/s3-backend/`. Round-trips a dummy memory tree through push + pull + verify.
- Runbook addition in `docs/phase2-vps-runbook.md`: "S3-backed memory" section — how to enable, how to verify, how to roll back.

**Non-goals:**

- Modifying `scripts/memory-mount.sh`. It stays as the FUSE path for operators who prefer it. Dual-mode-memory is additive.
- mount-s3 / fuse work (explicitly out-of-scope per ticket).
- Cross-commander locking / CRDT-style conflict resolution. v1 assumes single-writer at any moment. Two commanders writing concurrently will last-write-win at the file level (which is what `aws s3 sync` already does based on `mtime` + `size`).
- Encryption layer. Operator configures SSE-KMS via bucket policy (same as #34 notes).
- Pre-write S3 read. The read-path sync happens exactly once, at commander session start. Reading from S3 on every file read would thrash and add I/O latency to a hot path.
- `--dry-run` sync preview. Nice-to-have; leave for a follow-up if an operator asks.
- Touching `state/*.json`. That's the DynamoDB adapter (#13). This spec is about `memory/*.md` only.

## Proposed approach

### Read/write directionality

```
session start
   │
   ├── HYDRA_MEMORY_BACKEND=local       → nothing extra (Phase 1)
   ├── HYDRA_MEMORY_BACKEND=s3          → try sync --pull; on fail, log + continue
   └── HYDRA_MEMORY_BACKEND=s3-strict   → try sync --pull; on fail, exit 1
```

During the session, commander + workers read and write `./memory/` (or `$HYDRA_EXTERNAL_MEMORY_DIR` when the #8 split lands) exactly as today. The local dir is the **working copy** — the authoritative state *during* a session.

```
after any memory-layer write (parse-citations / validate-learning-entry / validate-citations)
   │
   ├── HYDRA_MEMORY_BACKEND=local       → nothing extra
   ├── HYDRA_MEMORY_BACKEND=s3          → sync --push; log warning on fail
   └── HYDRA_MEMORY_BACKEND=s3-strict   → sync --push; exit 1 on fail
```

The push is **post-write**, not pre-write. If S3 is unreachable the local memory is already updated and correct; we're just missing the backup for that moment. The next successful push catches up (`aws s3 sync` is idempotent).

### Why `aws s3 sync` over `mount-s3`

| Dimension                | `aws s3 sync`                             | `mount-s3`                                        |
|---                       |---                                         |---                                                 |
| Setup                    | `aws` already on Phase-2 operator's box   | macOS kext / Linux FUSE permissions; daemon       |
| Latency on read          | Zero (local file I/O)                      | Roundtrip to S3 per `open()` (or cached)          |
| Failure mode             | Stays local; operator sees clear error    | Mount disappears; writes land in a shadow tmpfs   |
| Concurrent writers       | Last-push-wins (mtime-aware)              | FUSE POSIX sort-of; undefined on concurrent appends |
| Observability            | Every sync logs files changed             | mount-s3 logs are FUSE-level, harder to parse     |
| Rollback                 | Unset env var                              | `umount` + clean up mountpoint                    |

For Hydra's workload — mostly append to `learnings-*.md`, occasional JSON index rewrites, bytes-per-day sub-kilobyte — the sync-based approach is simpler and strictly more robust than mount-s3. The mount-s3 path stays as-is for operators who want it; this spec adds a parallel path, doesn't replace anything.

### Shape of `scripts/hydra-memory-sync.sh`

```
Usage: hydra-memory-sync.sh [--push | --pull] [--memory-dir <path>] [--bucket <name>] [--prefix <str>] [--region <r>] [--dry-run]

Required env (or flag):
  HYDRA_S3_BUCKET, HYDRA_S3_PREFIX, HYDRA_AWS_REGION

Optional env:
  HYDRA_AWS_ENDPOINT_URL  (for localstack)
  HYDRA_EXTERNAL_MEMORY_DIR  (memory dir override; else ./memory/)

Exit codes:
  0   success (sync completed, or nothing to do)
  1   sync failed (S3 unreachable, auth missing, etc.)
  2   usage error (bad flags, missing env, no direction flag)
```

Internally, it just execs `aws s3 sync` with:
- `--delete` on pull (operator's S3 is the source of truth on a pull; cleans up local files that were deleted remotely). NOT on push — we never delete S3 files from a laptop push, guards against accidental local rm rf wiping the remote.
- `--exclude '.git*'` — defensive. We sync a memory dir, not a git worktree; shouldn't contain these, but cheap insurance.
- `--exclude 'archive/**'` — memory hygiene archives 30-day-old entries locally but they don't need to round-trip over S3 on every sync. They're already captured in prior pushes and stay durable on S3 (no `--delete` on push).

The script is ~80 lines of bash + `aws` CLI passthrough. No Python, no daemons.

### Hook into memory-layer scripts

Each of `parse-citations.sh`, `validate-learning-entry.sh`, `validate-citations.sh` gets a single post-success hook:

```bash
# --- S3 sync hook -------------------------------------------------------
# If HYDRA_MEMORY_BACKEND=s3 or s3-strict, push the (just-mutated) memory
# dir to S3. Fail-soft for s3, hard for s3-strict.
if [[ "${HYDRA_MEMORY_BACKEND:-local}" =~ ^s3(-strict)?$ ]]; then
  sync_script="$(dirname "${BASH_SOURCE[0]}")/hydra-memory-sync.sh"
  if [[ -x "$sync_script" ]]; then
    if ! "$sync_script" --push --memory-dir "$memory_dir" 2>&1; then
      if [[ "${HYDRA_MEMORY_BACKEND}" == "s3-strict" ]]; then
        echo "<scriptname>: S3 push failed and backend=s3-strict; exiting" >&2
        exit 1
      fi
      echo "<scriptname>: warning — S3 push failed, continuing (backend=s3)" >&2
    fi
  fi
fi
```

Only `validate-learning-entry.sh` and `validate-citations.sh` actually mutate files (or rather, their success implies something was just mutated by commander/worker code preceding them). `parse-citations.sh` is stateless and emits JSON to stdout; it doesn't need the hook directly, but the ticket calls out all three — the hook is still harmless because it sees no delta and the sync is a no-op. For clarity and auditability, all three get the hook with identical semantics.

### Launcher + entrypoint preflight

`./hydra` launcher (generated by `setup.sh`): after sourcing `.hydra.env`, before `exec claude`, if `HYDRA_MEMORY_BACKEND=s3` (or `s3-strict`), call `scripts/hydra-memory-sync.sh --pull`. On strict failure, exit before launching Claude.

`infra/entrypoint.sh` (cloud commander): same preflight, inside the existing dry-run-aware structure. Place it right after rewiring the volume symlinks (stanza 2) so when the pull populates `/hydra/data/memory/`, the symlink sees it immediately.

### Backwards compatibility

- Default `HYDRA_MEMORY_BACKEND=local` → bit-for-bit today's behavior. No S3 calls. No network I/O. No new required env vars.
- Operators with existing `$HOME/.hydra/memory` or external-memory-split setups (#8) are unaffected — `--memory-dir` honors `HYDRA_EXTERNAL_MEMORY_DIR`.
- `scripts/memory-mount.sh` is unchanged and remains the FUSE path.

### Alternatives considered

- **A: Modify `memory-mount.sh` to also support non-FUSE sync mode.** Rejected: overloads a script with two very different responsibilities, makes the `--dry-run` semantics ambiguous (dry-run WHICH mode?), and the ticket is explicit about not touching it.
- **B: S3 reads on every memory file access.** Rejected: thrashes hot path. A commander session reads `MEMORY.md` + several learnings files per ticket; hitting S3 each time adds 100-500ms per access. Pull-once-at-start is the right granularity for our write pattern.
- **C: Push on a timer (cron / `/loop`) instead of post-write.** Rejected: post-write gives exact-at-event durability. A timer would leave a window where a successful memory mutation hasn't been durable-ized yet. Post-write is also cheaper (only syncs when something changed). `aws s3 sync` with no deltas is ~100ms, so the cost on a write-heavy tick is negligible.
- **D (picked):** `aws s3 sync` + post-write push + pre-session pull.

## Test plan

1. `bash -n scripts/hydra-memory-sync.sh` — script is syntactically valid.
2. **Local default path unchanged**: run `parse-citations.sh` / `validate-learning-entry.sh` / `validate-citations.sh` with `HYDRA_MEMORY_BACKEND` unset — zero S3 calls, zero new warnings, same exit code as today. Covered by the existing `memory-validators` golden case (it already runs with no env set).
3. **Push path**: `HYDRA_MEMORY_BACKEND=s3 scripts/hydra-memory-sync.sh --push --dry-run` (or with localstack) — shows it'd run the expected `aws s3 sync` command.
4. **Pull path**: same with `--pull`.
5. **Roundtrip (self-test golden case)**: new `memory-sync-roundtrip` case (kind `script`, `requires_docker`) uses `self-test/fixtures/memory-sync/`:
   - Bring up localstack via existing `self-test/fixtures/s3-backend/docker-compose.yml` (reuse, don't duplicate).
   - Create a tmpdir with a fake memory tree (`learnings-test.md`, `MEMORY.md`).
   - Push to localstack, delete local, pull back, diff — expect bit-for-bit match.
   - Teardown runs on trap.
   - SKIP when docker is unavailable (standard `requires_docker` handling).
6. **Strict mode**: `HYDRA_MEMORY_BACKEND=s3-strict` against an unreachable endpoint → exit 1, clear error on stderr. Can be asserted in the self-test via an unroutable endpoint override.
7. **Launcher preflight**: not unit-tested (generated heredoc), but `bash -n` the extracted launcher content. Documented in runbook.

## Risks / rollback

- **Risk: S3 credentials leak into logs.** Mitigation: `aws s3 sync` doesn't emit creds; we pass `HYDRA_AWS_ENDPOINT_URL` / region / bucket only. No raw creds in the sync script.
- **Risk: `--delete` on pull wipes a file the operator was actively editing.** Mitigation: pull runs exactly once, at session start. Operator mid-edit on a laptop who forgot to push from another commander is the scenario and it's the operator's explicit choice to flip to s3 backend. The runbook calls this out.
- **Risk: `aws s3 sync --delete` on push accidentally wipes remote.** Mitigation: we NEVER pass `--delete` on push. That's a one-way safety rail; push is strictly additive from the laptop's POV.
- **Risk: Two commanders both write to the same file simultaneously.** Mitigation: v1 is explicit single-writer. Documented in runbook. Post-v1 could add DynamoDB-based write locks (out of scope here).
- **Risk: S3 bucket gets deleted or permissions revoked.** Mitigation: `s3-strict` catches at session start. `s3` mode degrades to local; next push attempt will error and commander continues with a warning. No data loss (local working copy is authoritative during session).
- **Rollback:** `HYDRA_MEMORY_BACKEND=local` (or unset) restores Phase-1 behavior instantly. No state to unwind, no schema migration, no lingering processes. `scripts/memory-mount.sh` is untouched.

## Implementation notes

(Fill in after the PR lands.)

- Hook placement: post-success, before `exit` — early exits (validation failures) intentionally skip the push because there's nothing safe to push.
- `aws s3 sync` reports changed keys on stdout; the sync script tees stdout to a compact `logs/memory-sync.log` for audit.
- Self-test reuses `self-test/fixtures/s3-backend/docker-compose.yml` — cheaper than spinning up a second localstack and keeps the fixture directory structure parallel.
