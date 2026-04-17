# Phase 2 VPS Runbook — Hydra commander on Fly.io

This document is the operational guide for running Hydra's commander on a cheap Fly.io Machine. It covers first-time deploy, updates, rollback, monitoring, cost, and security.

For the decision record / architecture rationale, see the design spec at [`docs/specs/2026-04-16-vps-deployment.md`](specs/2026-04-16-vps-deployment.md) and the umbrella issue [#48](https://github.com/tonychang04/hydra/issues/48).

## Scope of this runbook

**In:** Dockerfile, `fly.toml`, entrypoint, persistent volume, `/health`, one-command deploy, attach / logs / rollback.

**Out (separate tickets):**
- Webhook receiver (GitHub / Linear triggers) — [#40](https://github.com/tonychang04/hydra/issues/40), [#41](https://github.com/tonychang04/hydra/issues/41)
- End-to-end automated test from phone → cloud commander → merged PR — covered by the umbrella `#48` acceptance criteria when those land

**In (covered below):**
- Slack bot DM surface for the operator — see "Setting up Slack" below. (Ticket [#74](https://github.com/tonychang04/hydra/issues/74); supersedes the old `#42` reference above.)

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

## Setting up Slack

The Slack bot (`bin/hydra-slack-bot`) gives the operator a phone-friendly DM surface for Commander. It's a thin bridge: the operator DMs `status` or `pickup 2` and gets a reply; Commander DMs the operator when a PR is ready for human merge (label `commander-review-clean`). Spec: [`docs/specs/2026-04-17-slack-bot.md`](specs/2026-04-17-slack-bot.md).

Socket mode (outbound WebSocket to Slack) means **no public HTTP endpoint**. The bot works behind Fly's suspend-capable Machine with no extra port exposure.

**Scope (Phase 1):** single operator, DM only, two commands (`status` / `pickup [N]`), one notification trigger (`commander-review-clean`). Merge / reject / retry verbs are scaffolded as `NotImplemented` stubs.

### Step 1 — Create the Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**. Name it `hydra-commander` (or whatever you like), pick your workspace.
2. **Socket Mode** → enable it. Slack prompts you to create an **App-Level Token** with `connections:write` scope. Save the token — it starts with `xapp-`. This is your `HYDRA_SLACK_APP_TOKEN`.
3. **OAuth & Permissions** → add these **Bot Token Scopes**:
   - `chat:write` — post DM replies and proactive notifications
   - `im:history` — read the DM the user sends to the bot
   - `im:read` — list the bot's DM channels
   - `im:write` — open a DM conversation if one doesn't exist yet
   - `users:read` — verify the `allowed_user_id` lookup at boot (optional; the bot works without it, but logs a warning)
4. **Install App** → **Install to Workspace**. Approve the scopes. Save the resulting **Bot User OAuth Token** — it starts with `xoxb-`. This is your `HYDRA_SLACK_BOT_TOKEN`.
5. **Event Subscriptions** → **Enable Events** (it should default to on once socket mode is). Under **Subscribe to bot events**, add:
   - `message.im` — fires on every DM to the bot

No other events needed. No slash commands.

### Step 2 — Find your user ID and DM channel ID

In Slack, open your profile → three-dot menu → **Copy member ID**. Looks like `U0ABC12DEF`. This is `allowed_user_id`.

To find the `default_channel` (the DM conversation ID between you and the bot — used as fallback if direct user-ID DM fails): in Slack, open the DM with the bot; the channel ID shows in the URL (`https://app.slack.com/client/TXX/DXXXXXXXXXX`). Looks like `D0ABC12DEF`.

### Step 3 — Configure Hydra

Copy the template:

```bash
cp state/connectors/slack.json.example state/connectors/slack.json
```

Edit `state/connectors/slack.json`:

- Set `enabled: true`
- Confirm `bot_token_env` and `app_token_env` are the env-var names you'll use (defaults: `HYDRA_SLACK_BOT_TOKEN`, `HYDRA_SLACK_APP_TOKEN`)
- Set `allowed_user_id` (your `U…`)
- Set `default_channel` (your `D…`)
- Set `repos` to the list of `owner/name` repos to poll for the `commander-review-clean` label

The real `state/connectors/slack.json` file is gitignored — only the `.example` mirror is committed.

### Step 4 — Set tokens as Fly secrets

```bash
fly secrets set \
  HYDRA_SLACK_BOT_TOKEN=xoxb-… \
  HYDRA_SLACK_APP_TOKEN=xapp-… \
  --app <your-fly-app>
```

Secrets live in Fly's secret store — never committed, never on disk.

### Step 5 — Install the Python deps

The bot uses `slack-bolt` (Slack's official Python SDK). Add to your container build or install into the runtime venv:

```bash
pip install -r requirements.txt
```

On Fly: `requirements.txt` gets installed during `fly deploy` if your `infra/Dockerfile` runs `pip install -r requirements.txt`. If it doesn't yet, the deploy will succeed but the bot will refuse to start with "slack-bolt not installed" — update the Dockerfile in a follow-up PR.

### Step 6 — Wire the bot into entrypoint (follow-up)

**Deferred to ticket #72 landing.** Once `infra/entrypoint.sh` settles (that worker is rewriting it), add a stanza just before the `tmux new-session` line:

```bash
if [ -f state/connectors/slack.json ] && [ "$(jq -r .enabled state/connectors/slack.json 2>/dev/null)" = "true" ]; then
  ./bin/hydra-slack-bot &
fi
```

No changes to `infra/fly.toml` are needed — socket mode is outbound-only, no new port to expose.

Until that stanza lands, launch the bot manually in a second tmux window:

```bash
fly ssh console --app <app>
$ cd /hydra
$ tmux new-window -t commander -n slack-bot './bin/hydra-slack-bot'
```

### Step 7 — Verify

DM the bot `status`. Expected reply (shape varies with Commander state):

```
*Commander status:* running
*Active workers:* 1
*Today:* 3 done · 0 failed · 42 min wall-clock
*Autopickup:* on (every 30 min)
```

To verify proactive notifications, manually apply the `commander-review-clean` label to an open PR in one of your configured `repos`:

```bash
gh api --method POST /repos/<owner>/<repo>/issues/<pr>/labels -f 'labels[]=commander-review-clean'
```

Within `notification_poll_interval_sec` (default 60s) the bot should DM:

```
PR #501 ready for merge (T2 — owner/repo) — https://github.com/…
> PR title here
```

### Disabling

Flip `enabled: false` in `state/connectors/slack.json` and restart the process. Bot exits 0 with a clear log line. No migration or state cleanup needed.

### Troubleshooting

| Symptom | Check |
|---|---|
| Bot logs "env var HYDRA_SLACK_BOT_TOKEN unset" | `fly secrets list --app <app>` — re-run `fly secrets set`. |
| Bot logs "slack-bolt not installed" | `requirements.txt` not installed in the container — update `infra/Dockerfile`. |
| DMs from the right user are ignored | Check `logs/slack-audit.jsonl` for `refused-unauthorized-user` entries — if so, `allowed_user_id` is wrong. |
| Notifications don't fire on `commander-review-clean` | Check `gh` is installed inside the Machine and `GH_TOKEN` is set. Check `repos` in `slack.json` includes the repo. Check `logs/slack-audit.jsonl` shows outbound events. |
| Bot dies on every `fly deploy` | Normal — `fly deploy` replaces the Machine. The bot restarts from `entrypoint.sh`. `state/slack-notified-prs.json` on the volume preserves the seen-set, so no duplicate notifications. |

## Non-Fly operators (Hetzner, DO, bare VPS)

Use `infra/systemd/hydra.service` instead of Fly. The install steps are documented in-file at the top of that unit. Same `infra/entrypoint.sh` runs in both paths, so the operational muscle memory (attach, logs, deploy) carries over via `journalctl -u hydra.service -f` and `sudo -iu hydra tmux attach -t commander`.
