---
status: implemented
date: 2026-04-16
author: hydra worker (issue #48)
---

# Phase 2: Commander on a cheap VPS (Fly.io)

## Problem

Hydra today runs in a laptop terminal. Close the lid and commander stops. That bounds the "clear tickets while the operator sleeps" promise in a real and annoying way — the machine can only work while a human machine is also on.

Issue [#48](https://github.com/tonychang04/hydra/issues/48) laid out the decision: host commander on a cheap Linux VPS running the same `claude` CLI, keep everything else (workers, worktrees, memory, self-test) identical, and pay flat rate (Max subscription) instead of metered API. Supersedes #46 (Fly.io + E2B) and #47 (Managed Agents-direct).

This spec captures what shipped in the first PR against that umbrella — the core deploy artifacts. The webhook receiver and Slack bot are separate follow-ups.

## Goals

- Deploy commander to Fly.io with one operator-facing command.
- Framework + state survive `fly deploy` unchanged (persistent volume).
- Same `CLAUDE.md` / worker subagents / `state/` layout as the laptop path — no fork.
- Authenticate via Claude Code Max's OAuth token by default (flat-rate), fall back to `ANTHROPIC_API_KEY` (metered) if the operator doesn't have Max.
- Operator-facing `/health` on :8080 for Fly's HTTP probe and ad-hoc smoke tests.
- Documented rollback and monitoring paths.
- Also work on non-Fly Debian VPS (Hetzner, DO) via a systemd unit.

## Non-goals

- **Webhook receiver** — moved to [#40](https://github.com/tonychang04/hydra/issues/40) (GitHub) and [#41](https://github.com/tonychang04/hydra/issues/41) (Linear). The `/health` server is deliberately tiny; the real HTTP surface lands separately.
- **Slack bot** — [#42](https://github.com/tonychang04/hydra/issues/42). Chat surface stays `fly ssh console` + `tmux attach` in this PR.
- **End-to-end automated test** — "file issue from phone, cloud commander ships a PR, laptop closed" is the umbrella acceptance criterion; it becomes possible only once #40/#41/#42 land.
- **Multi-operator deployment** — still one commander per operator. Shared memory via S3 is a separate spec ([`2026-04-16-s3-knowledge-store.md`](2026-04-16-s3-knowledge-store.md)).
- **Auto-scaling workers to more than one machine** — commander stays on a single Fly Machine. Workers run as subprocesses on that same machine.

## Proposed approach

Four artifacts and a runbook:

1. **`infra/Dockerfile`** — `debian:bookworm-slim` + Claude Code (via official installer) + `gh` / `git` / `jq` / `curl` / `tmux` / `openssh-client`. Non-root `hydra:1000`. Inline Python `http.server` for `/health`. `ENTRYPOINT` hands off to `infra/entrypoint.sh` under `tini`.
2. **`infra/fly.toml`** — `shared-cpu-1x` / 512MB Machine, persistent volume `hydra_data` mounted at `/hydra/data`, `auto_stop_machines = "suspend"` for idle savings, `[http_service]` probing `/health`.
3. **`infra/entrypoint.sh`** — verifies auth env, rewires `/hydra/{state,memory,logs}` into the persistent volume, seeds `state/repos.json` from the example on first boot, launches the `/health` server, starts `claude` inside a detached `tmux` session named `commander`, `tail -F`s the log files to keep PID 1 alive and stream everything to `fly logs`.
4. **`infra/systemd/hydra.service`** — same entrypoint, same env contract, for non-Fly operators (Hetzner / DO / bare VPS). `Restart=always`, `RestartSec=30s`.
5. **`scripts/deploy-vps.sh`** — one-command operator flow: prompt → `fly launch --copy-config --no-deploy` → `fly secrets set` → `fly volumes create` → `fly deploy`. Prints attach / health / rollback commands at the end.

Plus docs: [`docs/phase2-vps-runbook.md`](../phase2-vps-runbook.md) is the operational reference; `INSTALL.md` got a short section linking to it.

### Alternatives considered

- **Managed Agents via raw API** (ruled out in #48 body). Double-pays: the operator still has a Max subscription on their laptop. Ties us to Anthropic's cloud specifically. VPS is provider-agnostic.
- **E2B sandboxes per worker** (superseded #46). Adds a second billing meter on top of the VPS bill. Workers already isolate via git worktrees on the local filesystem; there's no security win from E2B for a single-operator machine.
- **Kubernetes / Nomad / dedicated orchestrator.** Over-kill for one long-lived process. Fly Machines are the right shape: one container, one volume, one public endpoint.
- **SSH into a laptop from mobile and run commander there.** Works, but doesn't solve "laptop closed." Reverse-tethering through a cloud VPN (Tailscale + laptop) was considered but the VPS approach is simpler and more durable.

### Auth decision

Preferred: `CLAUDE_CODE_OAUTH_TOKEN`, generated via `claude setup-token` on a host where the operator is already signed in with Max. This token is valid for one year and makes commander's LLM usage ride the flat-rate subscription — the whole economic argument for Phase 2.

Fallback: `ANTHROPIC_API_KEY`. Metered. The entrypoint accepts it so the feature works for operators without Max, but the runbook is clear about the cost delta.

Both land in `fly secrets`. Neither touches the repo. The entrypoint hard-fails on boot if neither is set, with a log message pointing at `fly secrets set`.

## Test plan

- `docker build -f infra/Dockerfile . -t hydra-test` — succeeds against the real Dockerfile.
- `bash -n infra/entrypoint.sh scripts/deploy-vps.sh` — syntax clean.
- `shellcheck infra/entrypoint.sh scripts/deploy-vps.sh` — run when shellcheck is available (skipped in this worker's environment; no shellcheck installed on the host that ran the PR).
- `fly config validate --config infra/fly.toml` — passes (verified during this PR).
- Future (once #40/#41 land): smoke-test end-to-end — operator sends a fake webhook, commander spawns a worker, worker opens a draft PR. Currently out of scope.

## Risks / rollback

- **First-boot auth misconfig.** Entrypoint fails fast with a specific error ("Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set"). `fly logs` surfaces it immediately. Fix: `fly secrets set` and `fly deploy`.
- **State corruption across redeploys.** Mitigated by the rewire-to-volume logic in `entrypoint.sh`: `/hydra/{state,memory,logs}` become symlinks into `/hydra/data/*` on every boot, and we only seed from image defaults when the volume target is empty. Redeploying never clobbers existing state.
- **Claude Code installer URL changes.** The Dockerfile currently pulls `https://claude.ai/install.sh`. If Anthropic moves it, the build breaks — the `# NOTE FOR MAINTAINERS:` comment in the Dockerfile flags it. Rollback: pin `CLAUDE_VERSION` via build-arg or vendor a known-good installer.
- **Fly auto-suspend interacts badly with autopickup.** With `min_machines_running = 0` and no webhook inbound, commander won't tick while suspended. Operators who need continuous polling should set `min_machines_running = 1` per the note in `fly.toml`. Real fix is the webhook receiver (#40/#41).
- **Full rollback.** `fly releases` → `fly deploy --image-label <previous>`. State persists on the volume, so rolling the image back is safe. Full app teardown: `fly apps destroy <app>` (irreversible; snapshot the volume first).

## Follow-up tickets

- [#40](https://github.com/tonychang04/hydra/issues/40) — GitHub webhook receiver on `/webhook/github`.
- [#41](https://github.com/tonychang04/hydra/issues/41) — Linear webhook receiver on `/webhook/linear`.
- [#42](https://github.com/tonychang04/hydra/issues/42) — Slack bot bridging chat ↔ tmux session.
- Umbrella [#48](https://github.com/tonychang04/hydra/issues/48) end-to-end test: fresh operator runs `./scripts/deploy-vps.sh`, files an issue from their phone, commander picks it up via webhook, merges a PR, pings Slack. Laptop closed the whole time.

## Implementation notes

- `debian:bookworm-slim` omits the `passwd` package, so `groupadd`/`useradd` aren't on PATH. Used `addgroup --system` / `adduser --system` (from `adduser`, which IS in slim) instead. Caught by the first `docker build` attempt.
- Fly.io's TOML schema uses `[http_service]` (single) not `[[http_service]]` (array). Caught by `fly config validate`.
- `tini` as PID 1 so SIGTERM propagates cleanly to tmux + the inline Python server; the entrypoint's own `trap` then cleans up.
- The `/health` server is deliberately inline Python rather than a separate file — no extra artifact to maintain, and the surface is trivial. When `/webhook/*` routes land in #40/#41, the inline server gets replaced by a proper handler module.
- `tmux new-session -d -s commander "cd /hydra && claude | tee -a commander.log"` keeps the log stream visible both inside tmux (for attach) and outside (for `fly logs` via `tail -F`).
