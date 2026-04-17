# Phase 2 VPS Runbook — Hydra commander on Fly.io

This document is the operational guide for running Hydra's commander on a cheap Fly.io Machine. It covers first-time deploy, updates, rollback, monitoring, cost, and security.

For the decision record / architecture rationale, see the design spec at [`docs/specs/2026-04-16-vps-deployment.md`](specs/2026-04-16-vps-deployment.md) and the umbrella issue [#48](https://github.com/tonychang04/hydra/issues/48).

## Scope of this runbook

**In:** Dockerfile, `fly.toml`, entrypoint, persistent volume, `/health`, one-command deploy, attach / logs / rollback.

**Out (separate tickets):**
- Webhook receiver (GitHub / Linear triggers) — [#40](https://github.com/tonychang04/hydra/issues/40), [#41](https://github.com/tonychang04/hydra/issues/41)
- Slack bot chat surface — [#42](https://github.com/tonychang04/hydra/issues/42)
- End-to-end automated test from phone → cloud commander → merged PR — covered by the umbrella `#48` acceptance criteria when those land

## Prerequisites

| Need | How |
|---|---|
| `flyctl` installed | `brew install flyctl` or see [fly.io/docs/hands-on/install-flyctl](https://fly.io/docs/hands-on/install-flyctl/) |
| `fly auth login` done | One-time login in your browser |
| Claude Code Max subscription | For flat-rate billing. Metered `ANTHROPIC_API_KEY` works too but costs per-token. |
| GitHub personal access token | `repo` + `workflow` scopes. Same token Hydra uses locally. |
| This repo checked out | `scripts/deploy-vps.sh` expects to be run from the repo root |

## First-time deploy

One command:

```bash
./scripts/deploy-vps.sh
```

It prompts for:

1. **Fly app name** — e.g. `hydra-alice` (must be globally unique in Fly).
2. **Region** — e.g. `iad`, `sjc`, `fra`, `nrt`. Run `fly platform regions` to list. Pick the one closest to you (commander uses `gh` against GitHub, so WAN latency barely matters; optimize for `fly ssh console` responsiveness).
3. **Volume size** — default `1` GB. Memory / state / logs live here. Bump to `3+` if you retain many retros.
4. **`CLAUDE_CODE_OAUTH_TOKEN`** — generate on your laptop with:
   ```bash
   claude setup-token
   ```
   The output is a `sk-ant-oat-…` token valid for 1 year. Paste it into the prompt (hidden). If you skip it, the script falls back to asking for `ANTHROPIC_API_KEY` (metered).
5. **`GITHUB_TOKEN`** — `gh auth token` prints yours.

Under the hood:

- `fly launch --copy-config --no-deploy` creates the app using `infra/fly.toml`.
- `fly secrets set --stage` registers the tokens without deploying yet.
- `fly volumes create hydra_data --size N` provisions the persistent volume.
- `fly deploy` builds the image, boots the Machine, and runs `infra/entrypoint.sh`.

When it finishes, you'll see:

```
✅ Hydra commander is live on Fly.io

  Health check:
    curl https://hydra-alice.fly.dev/health
  Attach:
    fly ssh console --app hydra-alice -C 'tmux attach -t commander'
```

## Verifying the deploy

```bash
# 1. Health endpoint returns 200 + small JSON.
curl https://<app>.fly.dev/health

# 2. Machine is running.
fly status --app <app>

# 3. Commander booted inside tmux.
fly ssh console --app <app> -C 'tmux list-sessions'
# Expected: `commander: 1 windows ...`

# 4. Attach interactively to see commander's greeting.
fly ssh console --app <app> -C 'tmux attach -t commander'
# Detach with Ctrl-b d (don't Ctrl-c — that kills commander).
```

## Updating

Framework updates flow the same way as any git repo:

```bash
git pull --ff-only
fly deploy --app <app> --config infra/fly.toml
```

`fly deploy` builds a fresh image, stops the old Machine, starts the new one. Your data (`/hydra/data` = `state`, `memory`, `logs`) persists through the restart because it lives on the `hydra_data` volume.

For a hot-patch to CLAUDE.md or a worker subagent, prefer the framework update path — don't `fly ssh` and `vim` on the running Machine; those edits are ephemeral (wiped on next deploy unless you also commit them).

## Rolling back

```bash
# List recent releases.
fly releases --app <app>

# Redeploy by image label (e.g. v12 -> previous).
fly deploy --app <app> --image-label v11
```

State survives the rollback (same volume). Your only risk in a rollback is losing framework changes you shipped in the newer release — if those have already written to memory, that data stays.

## Monitoring

| Question | Command |
|---|---|
| Is it up? | `fly status --app <app>` |
| What's it doing right now? | `fly logs --app <app>` (stdout tail from entrypoint, commander, and the `/health` server) |
| Attach to chat? | `fly ssh console --app <app> -C 'tmux attach -t commander'` |
| /health response? | `curl https://<app>.fly.dev/health` → `{"status":"ok","uptime_s":<N>}` |
| Disk usage? | `fly ssh console --app <app> -C 'df -h /hydra/data'` |

`fly logs` is the primary surface. Commander's own chat log lives at `/hydra/logs/commander.log` (also streamed to stdout via `tail -F`).

## Cost expectations

| Item | Monthly |
|---|---|
| Fly shared-cpu-1x / 512MB with auto-stop `suspend` | $2-5 (usage-billed; charges only when awake) |
| 1 GB persistent volume | ~$0.15 |
| Outbound egress (PR creation, `gh` calls, /health probes) | cents |
| Claude Code LLM usage | $0 extra — your Max subscription covers it |
| **Total** | **~$3-5/mo** |

If you disable auto-stop (set `min_machines_running = 1` in `infra/fly.toml` so the scheduler can tick without inbound traffic), expect ~$5-10/mo — still cheaper than any per-ticket metered alternative.

## Security

- **All secrets go in `fly secrets`.** Never commit them to the repo. `infra/entrypoint.sh` hard-fails if auth vars are missing.
- **OAuth token is 1-year-valid.** No auto-rotation in v1. Regenerate + `fly secrets set` annually.
- **GitHub token** has `repo` + `workflow` scope only — the minimum commander needs. Prefer a fine-grained token restricted to the repos listed in `state/repos.json`.
- **SSH access.** `fly ssh console` uses Fly's WireGuard — no open port 22 on the public internet.
- **Volume.** `/hydra/data` is encrypted at rest by Fly. It contains your memory, learnings, and logs — valuable, but not credentials (tokens live in Fly's secret store, not on disk).
- **Webhook secret (follow-up #40/#41).** Will ride in `fly secrets` as `HYDRA_WEBHOOK_SECRET`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Machine won't start, logs show `Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set` | `fly secrets list --app <app>` — re-run `fly secrets set` for the missing var. |
| `/health` returns 503 | `fly logs` — the entrypoint failed before the Python server bound :8080. Usually an auth-env issue. |
| `tmux attach` shows an empty pane | Commander exited; `fly logs` shows why. Most likely cause: bad OAuth token or rate limit. |
| Deploy hangs on "Waiting for healthy status" | `grace_period` in `fly.toml` is 30s — commander takes longer than that on first boot on slow links. Retry `fly deploy`; subsequent boots are faster. |
| Lost state after deploy | Verify the volume is still attached: `fly volumes list --app <app>`. If the volume is gone, you created a new app without re-attaching — don't `fly apps destroy` without first `fly volumes snapshot`. |

## Repo cloning on Fly

Cloud commander needs the actual source tree of every enabled repo before it can spawn a `worker-implementation`. Unlike a laptop, Fly Machines start empty — there's no `/Users/<you>/projects/<repo>` waiting. `scripts/ensure-repo-cloned.sh` handles this.

Spec: [`docs/specs/2026-04-17-cloud-repo-clone.md`](specs/2026-04-17-cloud-repo-clone.md) · Ticket: [#73](https://github.com/tonychang04/hydra/issues/73).

### Where clones live

Default: `/hydra/data/repos/<owner>/<name>`.

Why that path: `/hydra/data` is the Fly volume mountpoint (`hydra_data`). Anything under it survives `fly deploy`, so repos stay cloned across framework updates — no bandwidth cost on every redeploy.

### How a clone is triggered

1. **At boot (follow-up after #72 lands).** `infra/entrypoint.sh` will iterate `state/repos.json:.repos[]` after rewiring the volume and call `scripts/ensure-repo-cloned.sh <owner>/<name>` for each enabled entry. This PR ships the tool; the entrypoint wiring is a follow-up because ticket #72 is currently editing `entrypoint.sh`.
2. **Before worker spawn (follow-up, same PR as #1).** Commander's spawn path will re-run `ensure-repo-cloned.sh` right before `git worktree add`, so a ticket pickup after a long idle window still starts from a clean, up-to-date base.
3. **Manually.** SSH into the commander and run it by hand:
   ```bash
   fly ssh console --app <app> -C 'scripts/ensure-repo-cloned.sh owner/name'
   ```
   Idempotent — safe to re-run when debugging.

### Override the clone path or git URL

Both fields are optional on each `state/repos.json:.repos[]` entry:

- `git_url` — override the default `https://github.com/<owner>/<name>.git`. Useful for forks, mirrors, or self-hosted GitLab.
- `cloud_local_path` — override the default `/hydra/data/repos/<owner>/<name>`. Useful when the operator wants a flatter layout or wants different repos on different volumes.

See `state/repos.example.json` for a populated example. Local-mode operators never need to touch these fields — `local_path` continues to work as today.

### Exit codes and failure modes

`scripts/ensure-repo-cloned.sh` exits:

- `0` on success, or on a safe no-op (e.g. it found an active worker worktree and declined to `git reset --hard`).
- `1` on config errors: missing `GITHUB_TOKEN` on a private-repo clone, repo not in `state/repos.json`, malformed slug, missing `git` / `jq`.
- `2` on git operation failures: network, auth rejected, corrupted local checkout.

All non-zero exits print a single-line reason to stderr. Tail `fly logs --app <app>` to see which repo failed and why.

### Authentication

The script uses `GITHUB_TOKEN` (already required by `entrypoint.sh`) to synthesize an HTTPS-auth URL at clone and fetch time: `https://x-access-token:${GITHUB_TOKEN}@github.com/<owner>/<name>.git`. The embedded token is never persisted into `.git/config` — the script restores the token-less origin URL immediately after the fetch. So `git remote -v` inside the clone never shows the token.

Public repos clone without `GITHUB_TOKEN`; that's how the self-test case runs in CI.

### What's out of scope (phase 1)

- Submodules (`git submodule update --init`). Tracked as future work.
- git LFS — pointers clone, blobs don't. Tracked as future work.
- SSH-key-based auth. HTTPS + `GITHUB_TOKEN` only.

These are documented in the spec so future tickets inherit the context.

## Non-Fly operators (Hetzner, DO, bare VPS)

Use `infra/systemd/hydra.service` instead of Fly. The install steps are documented in-file at the top of that unit. Same `infra/entrypoint.sh` runs in both paths, so the operational muscle memory (attach, logs, deploy) carries over via `journalctl -u hydra.service -f` and `sudo -iu hydra tmux attach -t commander`.
