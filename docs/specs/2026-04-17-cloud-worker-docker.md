---
status: draft
date: 2026-04-17
author: hydra worker (issue #77)
---

# Cloud worker docker support — opt-in DinD layer

Implements: ticket [#77](https://github.com/tonychang04/hydra/issues/77) (T2).

## Problem

Cloud commander on Fly.io runs out of `infra/Dockerfile` (debian-bookworm-slim
with git, gh, jq, tmux, python3, claude). It does **not** have a docker
binary or daemon. On local commander (operator's laptop) workers happily
invoke `docker compose up` against any repo's compose file — that's how
`worker-test-discovery` verifies test procedures for repos that need
postgres/redis/etc.

On cloud commander, workers **cannot**. There's no docker binary, no
`/var/run/docker.sock`. Any ticket whose test procedure requires containers
(most of InsForge's repos: `InsForge/InsForge`, `InsForge/insforge-cloud-backend`,
etc.) fails at step 1 of the test-discovery flow.

This defeats the Phase 2 vision in
[`CLAUDE.md`](../../CLAUDE.md#your-identity-non-negotiable): _"each worker
runs in a managed cloud sandbox that can stand up the service end-to-end."_
Without docker, cloud workers are limited to pure-source tickets (no
integration testing).

## Goals

1. Produce an **opt-in** docker-in-docker image variant so an operator who
   wants docker-backed workers on Fly can `docker build --build-arg
   ENABLE_DOCKER=true` and get a daemon-capable commander image.
2. Keep the default image **unchanged** (smaller, no privileged-mode surface)
   so existing operators don't inherit a security or disk cost regression.
3. Document the privileged-mode / Fly-config implications so an operator
   turning this on knows what they're agreeing to (attestation, not blind
   deploy).
4. Land a self-test that runs `docker info` inside the built image when the
   operator has opted into testing the DinD path (`HYDRA_TEST_CLOUD_DOCKER=1`),
   and SKIPs cleanly everywhere else.

## Non-goals

- **Option B** (per-service Fly Machines with rewritten connection strings).
  Explicitly deferred to its own ticket when we decide the DinD trade-off
  isn't working.
- **Option C** (E2B / Daytona / Managed Agents per-worker sandboxes). This
  is the proper long-term fix and lands under ticket #40 and the
  Managed-Agents umbrella. Option A here is a deliberate bridge.
- **podman / nerdctl swap.** Out of scope; follow-up if requested.
- **Flipping privileged mode on in `infra/fly.toml` itself.** This PR only
  documents the requirement. Flipping the actual VM flag is the operator's
  call per deploy, and can't be committed as a default without exposing
  every non-DinD operator to privileged-mode risk.
- **Docker socket bind-mount (`-v /var/run/docker.sock`) instead of DinD.**
  On Fly Machines there is no host docker daemon to share — the VM _is_ the
  container. Socket bind-mount only helps on laptops (where local commander
  already works).

## Proposed approach (Option A: DinD via conditional Dockerfile layer)

### Dockerfile: new `ARG ENABLE_DOCKER=false` + conditional apt layer

Add a single ARG + single RUN stanza near the existing system-packages
install. When `ENABLE_DOCKER=false` (the default), the layer is a near-noop
— apt not invoked, image size unchanged. When `ENABLE_DOCKER=true`, the
layer installs docker-ce, docker-ce-cli, containerd.io from Docker's own
apt repo (NOT Debian's default `docker.io` package, which lags upstream
and has different daemon semantics), and adds the `hydra` user to the
`docker` group.

```dockerfile
ARG ENABLE_DOCKER=false
RUN if [ "$ENABLE_DOCKER" = "true" ]; then \
        set -eux; \
        install -m 0755 -d /etc/apt/keyrings; \
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
        chmod a+r /etc/apt/keyrings/docker.gpg; \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; \
        rm -rf /var/lib/apt/lists/*; \
        groupadd -f docker; \
        usermod -aG docker hydra; \
    fi
```

Placement: after the `gh` install stanza, before the Claude Code install
(so `hydra` user membership update in `usermod -aG docker hydra` runs
**before** the user is created — wait, the user is created later. We
place the conditional layer AFTER the user creation so `usermod -aG docker
hydra` targets an existing user. See "Implementation ordering" below).

### Implementation ordering (important)

The existing Dockerfile creates the `hydra` user in a late stanza. The
`ENABLE_DOCKER` block needs that user to exist (so `usermod -aG docker
hydra` has something to add to the group), so the block goes **after**
the `useradd` line but **before** `USER hydra`. This keeps every
`ENABLE_DOCKER=true` side-effect in one RUN — cache-friendly and easy to
revert.

### fly.toml: document-only comment near `[[vm]]`

Add a NOTE comment stanza (no actual setting flip) explaining:

- DinD requires privileged mode on Fly Machines.
- Privileged mode is OFF by default; the operator enables it via
  `fly machine update --vm-privileged=true` or the equivalent in a
  follow-up `[vm]` field (Fly's API has moved; the runbook section is the
  single source of truth for the current syntax).
- Security surface: a privileged machine can manipulate kernel state
  (load modules, access raw devices) and escape the usual container
  isolation. This matters because the commander process runs arbitrary
  worker code, including `docker compose up` on repo-supplied compose
  files. Enabling this means trusting every repo in `state/repos.json`
  at the kernel level.
- Rollback: `fly machine update --vm-privileged=false && fly deploy`
  rebuilds with the default image.

The stanza is a pure comment — no `privileged = true` line, nothing CI or
`fly config validate` would flag. The default fly.toml stays as-is.

### Runbook: new "Enabling worker docker support" section in `docs/phase2-vps-runbook.md`

A walkthrough covering:

1. **When to enable** — you want cloud workers to run `docker compose up`
   (most InsForge repos).
2. **Build the image variant** — `fly deploy --build-arg ENABLE_DOCKER=true`
   on first rebuild; sets the arg once, persists via release metadata.
3. **Enable privileged mode on the Machine** — the current Fly CLI syntax
   (pinned here so we can update the single spot when Fly moves again).
4. **Verify DinD is live** — `fly ssh console --app <app> -C 'docker info'`
   should return a daemon report, not `Cannot connect to the Docker daemon`.
5. **Security caveats** — privileged mode widens the blast radius;
   `docker pull` + `docker run` on worker-supplied compose files mean the
   commander implicitly trusts every `image:` tag in every repo's
   `docker-compose.yml`. Mitigation options documented:
   - Restrict `state/repos.json` to a narrow allowlist during DinD
     operation.
   - Plan migration to Option C (E2B / Managed Agents per-worker VM)
     sooner rather than later if operating at scale.
6. **Disk cost** — DinD images layer on each other in `/var/lib/docker`
   inside the commander volume. The `hydra_data` volume should be sized
   at least 3× the usual allocation (3-5 GB instead of 1 GB) when DinD
   is on.
7. **Future migration to Option C** — one paragraph pointer to #40 and
   the Managed-Agents umbrella so the next operator knows this is a
   bridge, not a destination.

### Self-test: `cloud-worker-docker-available`

A `kind: script` case, SKIP-gated by env `HYDRA_TEST_CLOUD_DOCKER=1` via
a new `requires: [requires_cloud_docker_opt_in]` marker. When the marker is
absent, the runner prints `∅ SKIP: HYDRA_TEST_CLOUD_DOCKER=1 not set`
— the canonical "opt-in expensive test" convention used by
`requires_flyctl`, `requires_hadolint`, etc.

When active, the case:

1. Builds the DinD image: `docker build --build-arg ENABLE_DOCKER=true -t
   hydra-dind-test:ci -f infra/Dockerfile .`
2. Runs `docker info` **inside** the built image (via a short
   `docker run --privileged --rm hydra-dind-test:ci docker info`) and
   asserts the exit code is 0 and stdout contains `Server Version`.
3. On failure, tags result for review. No retry, no mutation.

`--privileged` is required at `docker run` time because the inner
`dockerd` needs the same kernel capabilities that Fly's privileged mode
grants. This is what the runbook section documents.

The case MUST default to SKIP because:
- The outer machine running self-test needs docker + `--privileged`
  support, which isn't guaranteed on every laptop or CI runner.
- Each build is ~600MB + ~minutes of wall-clock time.
- False green on a machine that doesn't actually have docker is worse
  than SKIP.

## Alternatives considered

### Option B — externalize test services (Fly Machines per service)

Worker-test-discovery, when it sees a `docker-compose.yml`, spins up
each service as its own short-lived Fly Machine and rewrites connection
strings in the test command.

**Pros:** no DinD, cleaner isolation per service, matches Fly's own
orchestration model.

**Cons:**
- Every service spawn is a Fly billing event. Cold-start latency on
  each test run (~5-15s per service) multiplies across a compose file.
- Orchestration logic is real work: inspecting the compose file,
  mapping services → Fly apps, injecting rewritten env vars, tearing
  down at the end. Probably a week of engineering.
- Doesn't handle service-to-service networking without a Fly private
  network setup per-worker — another layer of config.

**Rejected** for Phase 2 because the engineering cost is high and
Option C (sandboxes) is a better long-term answer anyway.

### Option C — per-worker managed cloud sandbox (E2B / Modal / Daytona / GH Codespaces API)

Each worker boots into its own Linux VM with docker pre-installed.
Commander stays on Fly; only workers go to sandboxes.

**Pros:** matches the `CLAUDE.md` "managed cloud sandbox" vision
verbatim. Per-worker isolation closes #61 (worker env/network
isolation) simultaneously. DinD is native to the sandbox image.

**Cons:**
- Biggest architectural change. Introduces a new SaaS dependency.
  Per-worker billing adds a fourth cost dimension (Fly + Claude +
  GitHub + sandbox).
- Requires #40 Managed-Agents work first so workers can ship their
  prompt + toolbelt to the sandbox provider cleanly.

**Deferred** to Phase 3 under the #40 umbrella. Option A here unblocks
Phase 2 in the meantime.

## Test plan

1. **Default image unchanged.**
   - `docker build -t hydra:default -f infra/Dockerfile .` (no
     `--build-arg ENABLE_DOCKER`) — size ≤ existing baseline +/- 5%.
   - `docker run --rm hydra:default which docker || echo "no docker"` →
     prints `no docker`, exits 0.
2. **DinD image functional when opted in.**
   - `docker build --build-arg ENABLE_DOCKER=true -t hydra:dind -f
     infra/Dockerfile .` succeeds.
   - `docker run --privileged --rm hydra:dind docker --version` prints
     a docker version (daemon not required for `--version`).
   - `docker run --privileged --rm hydra:dind id hydra` shows hydra is
     in group `docker`.
3. **Self-test gating correct.**
   - `./self-test/run.sh --case cloud-worker-docker-available` with
     `HYDRA_TEST_CLOUD_DOCKER` unset → `∅ SKIP`.
   - (Not run in this ticket) with `HYDRA_TEST_CLOUD_DOCKER=1` set on
     a machine with docker + `--privileged` support → executes the
     steps above and passes.
4. **fly.toml still valid.**
   - `fly config validate --config infra/fly.toml` still passes
     (governed by `fly-toml-valid` self-test case).
5. **CI syntax + spec-presence checks pass.**
   - Existing CI jobs, see `.github/workflows/`.

## Risks / rollback

- **Privileged mode is a genuine security escalation.** The runbook
  documents this. Operators can revert by rebuilding with
  `ENABLE_DOCKER=false` (the default) and `fly machine update
  --vm-privileged=false`. Nothing on the `hydra_data` volume is touched
  by the arg flip, so no state migration.
- **DinD disk growth.** Layered images accumulate in `/var/lib/docker`
  inside the commander volume. The runbook flags this and recommends a
  3-5 GB volume for DinD operators. `docker system prune` guidance is
  included.
- **Base-image CVE drift.** The Docker apt repo is upstream-managed;
  security updates flow in via `apt-get update` at each image rebuild.
  No new CVE exposure beyond what a standard Debian + Docker install
  carries.
- **Rollback to default image.** A single build-arg flip. Workers that
  were relying on `docker` inside the cloud commander degrade gracefully
  — `docker compose up` fails with a clear `command not found` message,
  and `worker-test-discovery` can annotate the test procedure as
  "container-required, not executable on this commander."

## Acceptance (mirrors ticket #77)

- [x] Spec at `docs/specs/2026-04-17-cloud-worker-docker.md` covering
  problem, three options compared, Phase-2 / Phase-3 split, rollback.
- [x] `infra/Dockerfile` — conditional DinD layer: `ARG
  ENABLE_DOCKER=false`; when true, installs docker-ce + adds `hydra`
  user to docker group. Default false.
- [x] `infra/fly.toml` — document (comment only) the privileged-mode
  requirement for DinD operators.
- [x] `docs/phase2-vps-runbook.md` — new "Enabling worker docker
  support" section.
- [x] Self-test case `cloud-worker-docker-available` (kind: script,
  SKIP by default unless `HYDRA_TEST_CLOUD_DOCKER=1`).
