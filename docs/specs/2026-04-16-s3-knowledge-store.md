---
status: implemented (adapter + fixture; operator steps documented)
date: 2026-04-16
author: hydra worker (commander/hydra-13)
---

# S3 knowledge store: state adapter + localstack fixture

Implementation ticket for `docs/phase2-s3-knowledge-store.md`. Ships the *mechanics* of the Phase 2 split so the migration is a config flip, not a refactor, once the operator is ready.

## Problem

`docs/phase2-s3-knowledge-store.md` describes the end state: memory + logs on S3, hot state on DynamoDB. But every piece of commander code today reads `state/*.json` directly. If we land the S3 migration as one big PR, it collides with the external-memory-split (#8) and bundles "move to cloud" with "refactor reads." We want the adapter layer **before** the migration so Phase 2 is a env-var flip.

Additionally, no part of the commander has been exercised against S3 or DynamoDB yet. Waiting to find out that our expectation about DynamoDB semantics was wrong would be expensive. We want a localstack-backed roundtrip test that runs today.

## Goals

- `scripts/state-get.sh` + `scripts/state-put.sh` abstract local vs DynamoDB behind `HYDRA_STATE_BACKEND=local|dynamodb`.
- `HYDRA_STATE_BACKEND` unset = `local` = today's behavior, bit-for-bit.
- `scripts/memory-mount.sh` is a thin wrapper over `mount-s3` with clear failure messages when the binary isn't installed.
- `INSTALL.md` has a self-contained Phase 2 section the operator can follow.
- A localstack fixture under `self-test/fixtures/s3-backend/` proves the dynamodb roundtrip works without real AWS.
- Every Phase-2-specific path (bucket, prefix, region, table names) comes from env vars. No AWS region or account ID hardcoded anywhere.

## Non-goals

- Rewriting commander's internal `state/active.json` read-sites to call `state-get.sh`. That belongs with the external-memory-split refactor (#8) so workers and commander both flip at once.
- Real mount-s3 exercise in CI. mount-s3 needs FUSE / macFUSE privileges that localstack cannot provide. The operator validates mount-s3 behavior against real AWS; we only smoke-test the wrapper's preflight logic.
- IAM / KMS provisioning. Those are the operator's responsibility on their own AWS account.

## Proposed approach

### Shape of the adapter

`state-get.sh --key <name>` maps `<name>` to:
- **Local mode**: `state/<name>.json` (plain `cat`).
- **DynamoDB mode**: table `commander-<name>` (override via `HYDRA_DDB_TABLE_<NAME_UPPER>`), one row keyed by `id = singleton` (override via `HYDRA_DDB_PK_VALUE`), payload stored as a stringified JSON in attribute `payload`.

`state-put.sh --key <name>` is the symmetric write. Local mode is atomic (tmp + mv). DynamoDB mode sets `{id, payload, updated_at}` via `put-item`. Payload is validated as JSON before commit — we never write garbage.

Both accept `HYDRA_AWS_ENDPOINT_URL` so the localstack fixture can point them at `http://localhost:4566`. Production leaves it unset.

### mount-s3 wrapper

`memory-mount.sh` stays thin — we don't want to hide the mount-s3 command. It checks the binary is on PATH (clear install instructions if not), sanity-checks env, refuses to remount over an existing mount, and prints validation commands after success. Operator can pass `--dry-run` to see the exact `mount-s3` invocation before it runs.

### Localstack fixture

`self-test/fixtures/s3-backend/` spins up localstack (S3 + DynamoDB), creates the bucket + three tables, runs `state-put.sh` then `state-get.sh`, and compares via `jq`. Teardown always runs via trap. Marked `requires_docker` in the golden-cases file so the self-test runner skips it on a machine without docker instead of failing.

### Alternatives considered

- **A: Abstract in commander CLAUDE.md prose only (no scripts).** Rejected — commander's shell-out loops and workers both need a programmatic handle, not instructions.
- **B: Write the adapter in a single Python module.** Rejected — Hydra is bash + jq everywhere else; introducing Python adds a runtime dependency the operator doesn't already need.
- **C: Skip localstack; test against real AWS in CI.** Rejected — requires storing AWS creds in CI, and localstack catches 95% of the DynamoDB shape bugs we'd hit.
- **D (picked):** Two small shell scripts + localstack fixture + operator-run real-AWS validation.

## Test plan

1. `bash -n scripts/state-get.sh scripts/state-put.sh scripts/memory-mount.sh` → OK
2. Local-mode smoke (no AWS needed):
   ```
   HYDRA_STATE_BACKEND=local scripts/state-put.sh --key active < active.json
   HYDRA_STATE_BACKEND=local scripts/state-get.sh --key active
   ```
   roundtrips.
3. Localstack e2e (`self-test/fixtures/s3-backend/run-e2e.sh`): roundtrip through DynamoDB mode succeeds on a machine with docker.
4. Golden case `s3-backend-roundtrip` (kind=script, requires_docker) wraps the localstack e2e so the self-test harness picks it up.
5. **Operator-validated (manual, against real AWS):**
   - IAM role grants the scoped permissions listed in INSTALL.md; a commander instance running as that role can put+get.
   - SSE-KMS encryption is enforced at rest; `aws s3api get-object-attributes` shows the operator's CMK.
   - `mount-s3 --version` is on PATH, and `./scripts/memory-mount.sh` completes without error.
   - `ls $HYDRA_EXTERNAL_MEMORY_DIR/memory/` returns the expected tree.

## Risks / rollback

- **Risk:** Operator forgets to set `HYDRA_AWS_REGION` → adapter bails with a clear error. Mitigation: `state-{get,put}.sh` check env up front and fail fast rather than hanging on awscli default-region lookup.
- **Risk:** mount-s3 dies silently mid-session → commander sees empty `memory/` and might write new learnings into a shadow dir. Mitigation (future): a supervisor. Today: the `ls` validation in memory-mount.sh output catches it at mount time; commander's own escalation-faq pickup will surface "memory missing" as an escalation.
- **Risk:** DynamoDB eventual consistency race on `active.json` across two commanders. Phase 2 design already flags this — the adapter stays strongly-consistent by using `consistent-read` on gets (TODO if we see races; `commander-active` is a single-row hot spot, not a scan target).
- **Rollback:** unset `HYDRA_STATE_BACKEND` (or set to `local`). Nothing in local mode changed. The S3 bucket and DynamoDB tables are orphaned but harmless.

## Implementation notes

- **What works today (automated):**
  - Local-mode adapter is backward-compatible: `HYDRA_STATE_BACKEND` unset defaults to `local`, which is `cat state/<key>.json` / `mv <tmp> state/<key>.json`.
  - DynamoDB-mode adapter exercised via localstack roundtrip under `self-test/fixtures/s3-backend/`.
  - `memory-mount.sh --dry-run` validates env + prints the mount-s3 command without requiring mount-s3 to be installed (helps operators preview).

- **What the localstack fixture proves:**
  - put-item then get-item roundtrips a non-trivial JSON payload (workers array + timestamps) bit-for-bit.
  - The adapter correctly serializes payloads as a single `payload.S` attribute — deserialization doesn't lose structure.

- **What requires the operator to validate against real AWS (not covered by localstack):**
  - IAM role scoping (mount-s3 + put-item from a scoped-role shell).
  - SSE-KMS encryption-at-rest and the CMK grant for the role.
  - Real mount-s3 FUSE behavior — POSIX semantics under concurrent writes from multiple workers.
  - S3 versioning recovery — confirm an accidental overwrite of `memory/learnings-CLI.md` can be rolled back via `aws s3api list-object-versions`.
  - Cost shape — S3 cents/month estimate holds; DynamoDB PAY_PER_REQUEST doesn't spike on `active.json` churn. Watch for a week after migration.

- **Companion tickets:**
  - #8 (external-memory-split): once memory moves to `$HYDRA_EXTERNAL_MEMORY_DIR`, Phase 2 = `HYDRA_EXTERNAL_MEMORY_DIR=<s3-mount-point>` + `HYDRA_STATE_BACKEND=dynamodb`. No other commander-side changes.
  - #11 (review label automation): this PR uses the `commander-review` label on open so the commander-side review gate picks it up.
