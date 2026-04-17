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

## Migrating from local to cloud

If you've been running Hydra locally (`./hydra` in a terminal) and want to move to cloud without losing memory, learnings, or ticket state, use `scripts/hydra-migrate-to-cloud.sh`. The script walks you through: generate both OAuth tokens (Claude + Codex, if desired) → push to `fly secrets` → generate MCP bearer for your main agent → deploy and health-check.

Spec: [`docs/specs/2026-04-17-cloud-default-oauth.md`](specs/2026-04-17-cloud-default-oauth.md) · Ticket: [#106](https://github.com/tonychang04/hydra/issues/106).

### What migration does (and doesn't) do

**Preserves:**
- Memory directory (`~/.hydra/memory/` or whatever `HYDRA_EXTERNAL_MEMORY_DIR` points at). Cloud commander starts with the same learnings. Enable `HYDRA_MEMORY_BACKEND=s3` after migration for bi-directional sync.
- `state/repos.json` — committed to your laptop's git clone, gets copied into the Fly image on deploy.
- Flat-rate OAuth billing. The whole point of the migration is to keep Claude Code Max + Codex OAuth working after the move — neither requires an API key.

**Does NOT preserve / touch:**
- In-flight workers in `state/active.json`. Migration should run when the queue is idle. Verify with `./hydra status` or `./hydra ps` first.
- Laptop auth state (`~/.claude/`, `~/.codex/`). Those sit on your laptop; migration just reads env vars that you've exported or generates fresh tokens via `claude setup-token` / `codex login`.
- Your GitHub identity. `GITHUB_TOKEN` is still the operator's own PAT (or a bot-account PAT if you configured `assignee_override`).

### Pre-flight checklist

Before running migration:

```bash
# 1. No in-flight workers. Either wait for them to finish or `pause` first.
./hydra status
# Expected: "0 heads active" or similar.

# 2. All local changes committed or stashed.
git status
# Expected: clean working tree.

# 3. Fly CLI logged in.
fly auth whoami
# Expected: your Fly account email.

# 4. Optional — rehearse the migration with --dry-run first.
./scripts/hydra-migrate-to-cloud.sh --dry-run
# Executes no side effects; prints what WOULD happen.
```

### The migration

```bash
./scripts/hydra-migrate-to-cloud.sh
```

Interactive: auto-detects what auth you already have, prompts only for what's missing, asks at most one question per step. Respects `HYDRA_NON_INTERACTIVE=1` and CI env for scripted runs.

Steps (same as printed by `--help`):

1. **Preflight** — verify `flyctl` + auth, `infra/fly.toml`, `claude` + `gh` + `jq`.
2. **Auth inventory** — report what's in your shell env (presence only, never values).
3. **Claude OAuth** — offer to run `claude setup-token` if nothing's set. Pastes back into shell.
4. **Codex OAuth** — offer to run `codex login`; alternatively accept `OPENAI_API_KEY` (preferred for headless).
5. **Fly secrets push** — stage whichever tokens are present via `fly secrets set --stage`.
6. **MCP bearer** — run `./hydra mcp register-agent <main-agent-id>` on the commander, print token to stdout once.
7. **Deploy + health check** — `fly deploy` followed by `curl /health`.
8. **Next steps** — optional follow-ups (laptop `autopickup off`, dual-mode memory, Slack bot).

Each step is idempotent — re-running the script is safe. Side effects are logged with `DRY RUN:` prefix in dry-run mode; real-run executes them only after operator confirmation at each step.

### OAuth env vars Hydra accepts

As of ticket #106, `infra/entrypoint.sh` accepts either (or both) provider families:

| Provider | Env var | Mode | Validity |
|---|---|---|---|
| Claude | `CLAUDE_CODE_OAUTH_TOKEN` | OAuth (preferred, flat-rate) | 1 year from generation |
| Claude | `ANTHROPIC_API_KEY` | Metered API | no expiry (rotate per your policy) |
| Codex | `OPENAI_API_KEY` | API-key auth (preferred for headless) | per OpenAI dashboard |
| Codex | `$HYDRA_CODEX_AUTH_ENV` (default `CODEX_SESSION_TOKEN`) | ChatGPT-session OAuth | upstream-dependent, not documented |

Commander boots with at least ONE provider present. Workers route per `state/repos.json:preferred_backend` — a Codex-only deploy is valid; a Claude-only deploy is today's default.

**Why `HYDRA_CODEX_AUTH_ENV` is configurable.** Codex-CLI hasn't settled on a canonical env-var name for its session-auth OAuth. Hydra picks `CODEX_SESSION_TOKEN` as the default Hydra-side convention and makes it overridable so operators can track upstream without a Hydra release. If Codex-CLI settles on a different name, set `HYDRA_CODEX_AUTH_ENV=<new-name>` as a Fly secret AND set the token itself under that name.

### OAuth rotation

Commander does not auto-rotate. Set a calendar reminder + surface in `retro` (the retro template's `## Proposed edits` section is the intended hook starting ~11 months after migration).

| Token | Rotate how |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Re-run `claude setup-token` on your laptop, then `fly secrets set CLAUDE_CODE_OAUTH_TOKEN=<new>`. 1-year validity. |
| `ANTHROPIC_API_KEY` | Generate in Anthropic console, `fly secrets set ANTHROPIC_API_KEY=<new>`. |
| `OPENAI_API_KEY` | Generate in OpenAI dashboard, `fly secrets set OPENAI_API_KEY=<new>`. |
| `CODEX_SESSION_TOKEN` (or whatever `HYDRA_CODEX_AUTH_ENV` names) | Re-run `codex login` to refresh persisted tokens, then `fly secrets set <var>=<new>`. Validity is upstream-dependent; check after deploy with a smoke ticket. |
| `GITHUB_TOKEN` | Generate new PAT with `repo` + `workflow` scope, `fly secrets set GITHUB_TOKEN=<new>`. |

Running the migration script with fresh tokens in your shell env re-stages them all in one shot — idempotent.

### Rollback

Migration is fully reversible. Cloud commander on Fly and laptop commander can coexist — migration doesn't disable local mode.

- **Partial rollback — stop cloud ticking, keep laptop as primary:**
  ```bash
  # Either:
  fly ssh console --app <your-app> -C '/hydra/hydra pause --reason "rolling back to local"'

  # Or scale to zero (machine idle, no cost except volume + secrets):
  fly scale count 0 --app <your-app>
  ```
  Your laptop's `./hydra` keeps working with `autopickup` on as usual.

- **Full rollback — destroy cloud:**
  ```bash
  fly apps destroy <your-app>
  # (this also destroys the volume — export memory first if you want to keep
  #  anything only-cloud has written)
  ```
  Local state is untouched.

### Security posture

- All secrets live in `fly secrets` — never committed, never on laptop disk after the migration script exits.
- The migration script reads tokens from env vars only. `--dry-run` prints secret NAMES only, never values.
- The MCP bearer generated in step 6 is printed to stdout exactly once (contract inherited from `scripts/hydra-mcp-register-agent.sh`). Copy it immediately into your main agent's config.
- Fly's secret store is encrypted at rest by Fly. Tokens are injected as env vars into the Machine at boot time; they never hit the persistent volume.

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

## Enabling worker docker support

**Default: off.** The standard commander image has no docker binary. Workers running on cloud commander therefore can't `docker compose up` against a repo's compose file — so any test procedure that needs postgres/redis/any other containerised dep will fail at step 1 of `worker-test-discovery`.

To enable it, rebuild with an opt-in build arg and flip one Fly setting. This is a deliberate per-operator attestation — **read the security caveats below before enabling**.

Spec: [`docs/specs/2026-04-17-cloud-worker-docker.md`](specs/2026-04-17-cloud-worker-docker.md) · Ticket: [#77](https://github.com/tonychang04/hydra/issues/77).

### When to enable

You probably want this if:

- You're running Hydra against repos whose test procedure uses `docker compose` (most InsForge repos — `InsForge/InsForge`, `insforge-cloud-backend`, anything with a `docker-compose.yml` in the root).
- `worker-test-discovery` has returned "test procedure unclear" on a repo twice in a row with the docker-missing signature in the worker log.

You probably don't want this if:

- Your repos are pure-source (no integration tests, or tests that use in-memory fixtures).
- You're not comfortable with the security posture of a privileged Fly Machine (see below).

### Step 1 — Rebuild the image with DinD enabled

```bash
fly deploy --build-arg ENABLE_DOCKER=true --app <your-app>
```

`fly deploy` passes the build-arg to `docker build`, which triggers the conditional stanza in `infra/Dockerfile`. The layer installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin` from Docker's own apt repo, then adds the `hydra` user to the `docker` group so workers run `docker` without sudo.

Image size delta: ~+400-600 MB (docker-ce + containerd + plugins). Build time delta: ~+60-90 s on a warm cache.

### Step 2 — Enable privileged mode on the Fly Machine

DinD needs the inner daemon to load kernel modules and access raw devices, which requires the Fly Machine to run privileged. The current flyctl command is:

```bash
fly machine list --app <your-app>
fly machine update <machine-id> --vm-privileged=true --app <your-app>
```

(Fly's syntax for privileged mode has changed twice in the past year — if the flag above is rejected, `fly machine update --help | grep -i priv` surfaces the current form. We keep the runbook as the single source of truth so you update in one place.)

Without this step, the inner daemon can start but will fail to create any container — `docker run` returns `operation not permitted`.

### Step 3 — Verify DinD is live

```bash
fly ssh console --app <your-app> -C 'docker info'
```

Expected (shortened):

```
Server Version: 27.x.y
Storage Driver: overlay2
Cgroup Driver: systemd
...
```

If you see `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`, the inner daemon didn't start — usually because Step 2 (privileged mode) wasn't applied. Re-check `fly machine list --app <app>` and look for `privileged: true` in the output.

### Step 4 — Size the volume for docker images

DinD builds accumulate under `/var/lib/docker` inside the commander volume. `hydra_data` defaults to 1 GB; bump it to 3-5 GB for DinD operation:

```bash
fly volumes extend <volume-id> --size 5 --app <your-app>
```

`docker system prune -af` inside the machine reclaims space between major compose-heavy ticket runs — add to your monthly housekeeping.

### Security caveats (read this before enabling)

**Privileged mode genuinely widens the blast radius.** The Fly Machine gains kernel capabilities a normal container doesn't have: can load kernel modules, access raw block devices, escape the usual namespace isolation. This matters for commander specifically because:

- Commander runs worker subagents that execute **arbitrary code from the repos in `state/repos.json`**. That includes `docker compose up` on repo-supplied compose files — every `image:` tag in every compose file is now something the commander trusts at the kernel level.
- A malicious or compromised `docker-compose.yml` in one of your repos could mount host paths, join host networks, or load kernel modules via the inner daemon.

Mitigations in rough priority order:

1. **Narrow `state/repos.json`** to repos you fully control. This is the single biggest lever.
2. **Short-lived Machines.** `auto_stop_machines = "suspend"` in `fly.toml` already limits the always-on surface. Don't set `min_machines_running` above what you actually need.
3. **Audit the compose files** for every enabled repo before turning DinD on for the first time. Look for `privileged: true` services, `volumes: - /:/host`, and `network_mode: host` — none of these should be in a repo you're testing.
4. **Plan migration to Option C** (per-worker managed sandboxes via E2B / Daytona / Managed Agents, tracked under [#40](https://github.com/tonychang04/hydra/issues/40)). DinD is Phase 2 only — the long-term fix runs each worker in its own tiny cloud VM so one compromised compose file can't affect any other worker or the commander itself.

### Rollback

Two steps, in either order:

```bash
# Rebuild without the build-arg (default FALSE).
fly deploy --app <your-app>

# Turn privileged mode off on the Machine.
fly machine update <machine-id> --vm-privileged=false --app <your-app>
```

Nothing on the `hydra_data` volume is touched by the flip. Workers that relied on `docker` inside the cloud commander will now fail with a clear `command not found`, and `worker-test-discovery` can annotate the procedure as "container-required, not executable on this commander."

### Self-test

An opt-in self-test case `cloud-worker-docker-available` exists in [`self-test/golden-cases.example.json`](../self-test/golden-cases.example.json). It SKIPs by default; run with:

```bash
HYDRA_TEST_CLOUD_DOCKER=1 ./self-test/run.sh --case cloud-worker-docker-available
```

Requires a local `docker` + `--privileged` to execute. Not run in CI; this is an on-demand verification for operators who've just enabled DinD on their own image.

## Troubleshooting

### First-run troubleshooting

Before you SSH into the Machine and start reading raw logs, run the doctor.
It's the single diagnostic that covers 90% of "why isn't my install working."
It runs locally, on a VPS, or inside the Fly Machine without modification.

```bash
# Local laptop
./hydra doctor

# Inside the Fly Machine
fly ssh console --app <app> -C '/hydra/hydra doctor'
```

Every ✗ / ⚠ now ships with an actionable hint line right below it, prefixed
one of:

| Prefix | Meaning |
|---|---|
| `fix:` | Safe command the doctor can run for you (chmod +x, mkdir -p). Offered by `--fix`. |
| `run:` | Command you should run yourself — usually a package install or a `./setup.sh`. Doctor never auto-runs these. |
| `manual:` | Edit-a-file instruction — usually a config tweak. No command to run. |

Example output on a broken install:

```
✗ jq on PATH — not found
    run: brew install jq    # or apt-get install jq on Linux
✗ state/repos.json exists — missing
    run: ./setup.sh    # then edit state/repos.json to list your repos
⚠ logs/ exists — missing
    fix: mkdir -p '/hydra/logs'
```

For the interactive walkthrough, add `--fix`:

```bash
./hydra doctor --fix
```

For each fixable issue, doctor prompts:

```
  [1/3] ⚠ logs/ exists
        fix: mkdir -p '/hydra/logs'
        ▸ _
```

- `y` → run the fix command.
- `n` → skip this one.
- `s` → show the exact command that would run, then re-prompt.
- `q` → quit the walkthrough; remaining items are untouched.

`--fix` only auto-runs narrowly safe commands (chmod +x on a script that lost
its bit, mkdir -p on missing directories). Doctor deliberately does NOT
auto-install binaries (`brew install jq`), re-auth to GitHub (`gh auth login`),
or edit your JSON config files — those print as `run:` / `manual:` hints
instead. The guardrail is there so operators keep control of anything with a
real blast radius.

`--fix` requires an interactive terminal. In CI or scripted contexts, use
`--fix-safe` instead — it applies the same narrow set of fixes without
prompting.

Spec: [`docs/specs/2026-04-17-doctor-fix-mode.md`](specs/2026-04-17-doctor-fix-mode.md) · Ticket: [#104](https://github.com/tonychang04/hydra/issues/104).

### Common symptoms

| Symptom | Check |
|---|---|
| Machine won't start, logs show `Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set` | `fly secrets list --app <app>` — re-run `fly secrets set` for the missing var. |
| `/health` returns 503 | `fly logs` — the entrypoint failed before the Python server bound :8080. Usually an auth-env issue. |
| `tmux attach` shows an empty pane | Commander exited; `fly logs` shows why. Most likely cause: bad OAuth token or rate limit. |
| Deploy hangs on "Waiting for healthy status" | `grace_period` in `fly.toml` is 30s — commander takes longer than that on first boot on slow links. Retry `fly deploy`; subsequent boots are faster. |
| Lost state after deploy | Verify the volume is still attached: `fly volumes list --app <app>`. If the volume is gone, you created a new app without re-attaching — don't `fly apps destroy` without first `fly volumes snapshot`. |
| Doctor reports a ✗ with no hint below it | File a bug — every ✗ should have a hint. The `doctor-fix-smoke` self-test case is the regression gate. |

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

## Wiring GitHub webhooks

Phase 1 of webhook-based ticket triggering: GitHub `issues.assigned` events POST to `https://<app>.fly.dev/webhook/github`, the receiver validates HMAC-SHA256, and drops a sentinel file at `state/webhook-triggers/<ts>-<owner>-<repo>-<issue>.json`. A follow-up ticket wires Commander's autopickup tick to short-circuit the timer when sentinels are present; until then the receiver runs additively alongside the 30-min poll. Spec: [`docs/specs/2026-04-17-github-webhook-receiver.md`](specs/2026-04-17-github-webhook-receiver.md) · Ticket: [#41](https://github.com/tonychang04/hydra/issues/41).

This section is **deliberately additive**. The receiver and `[[services]]` stanza in `infra/fly.toml` ship in this PR, but the Fly machine does **not** auto-launch the receiver yet — `infra/entrypoint.sh` integration is a separate ticket (the spec calls it out explicitly to keep this PR's blast radius small). Until that wiring lands, you can launch the receiver manually inside the Fly machine for early testing.

### Step 1 — Generate the webhook secret

```bash
openssl rand -hex 32
```

Copy the output (a 64-char hex string). This is the shared secret you'll register on both the GitHub side (so it can sign deliveries) and the Hydra side (so the receiver can validate them).

### Step 2 — Register the secret with Hydra

```bash
fly secrets set HYDRA_WEBHOOK_SECRET=<paste-secret-here> --app <your-app>
```

The receiver refuses to start without this secret set (no fallback to "unauthenticated" mode — that would let anyone on the internet drop a sentinel file and bypass tier classification).

### Step 3 — Register the webhook on GitHub

For each repo you want webhook delivery from:

```bash
gh api --method POST /repos/<owner>/<repo>/hooks \
  -f name=web \
  -f active=true \
  -F events[]=issues \
  -f config[url]=https://<your-app>.fly.dev/webhook/github \
  -f config[content_type]=json \
  -f config[secret]=<paste-secret-here> \
  -f config[insecure_ssl]=0
```

Phase 1 subscribes only to `issues` events. The receiver further filters server-side to `action == "assigned"` — other `issues` actions (opened, labeled, closed, etc.) are acknowledged with 204 but produce no sentinel.

If you have `gh` configured against a different account than the one that should own the webhook, prefix with `GH_TOKEN=<token>` or use `--repo <owner>/<repo>`.

### Step 4 — Launch the receiver (manual until the entrypoint integration lands)

SSH into the Fly Machine and start the receiver in a tmux window:

```bash
fly ssh console --app <your-app>
# inside the VM:
$ tmux new-window -t commander -n webhook 'python3 /hydra/scripts/hydra-webhook-receiver.py --bind 0.0.0.0 --port 8766'
```

(The launcher runs as PID 1's child via the same tmux session as commander; it dies when the Machine stops, restarts on the next deploy.)

Verify it bound:

```bash
fly ssh console --app <your-app> -C 'curl -sf http://127.0.0.1:8766/'
# → "hydra-webhook-receiver: POST /webhook/github"
```

### Step 5 — Verify a real delivery

In GitHub: Settings → Webhooks → click the webhook you just created → Recent Deliveries → click the latest → Redeliver. You should see:

- Response 200 (matched event) or 204 (acknowledged but filtered out — anything other than `issues.assigned`)
- `fly logs --app <app>` shows one line per delivery: `event=issues action=<X> result=<Y>`
- For an `issues.assigned` event, a sentinel appears: `fly ssh console --app <app> -C 'ls -la /hydra/data/state/webhook-triggers/'`

### Local development (no Fly)

For testing on a laptop, run the receiver locally and tunnel via [ngrok](https://ngrok.com) or [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/):

```bash
# terminal 1
export HYDRA_WEBHOOK_SECRET=<paste-secret-here>
python3 scripts/hydra-webhook-receiver.py --port 8766

# terminal 2
ngrok http 8766
# Use the resulting https://<random>.ngrok-free.app/webhook/github URL when
# registering the webhook on GitHub.
```

The receiver defaults to binding `127.0.0.1:8766` — perfect for tunnel-based local dev.

### Rotating the secret

```bash
NEW=$(openssl rand -hex 32)
fly secrets set HYDRA_WEBHOOK_SECRET=$NEW --app <your-app>
# Update each registered webhook with the new secret:
gh api --method PATCH /repos/<owner>/<repo>/hooks/<hook-id> -f config[secret]=$NEW
```

There's a brief window where in-flight deliveries signed with the old secret will return 401 — GitHub auto-retries failed deliveries, so they'll succeed once the operator finishes both updates.

### Disabling

Two options, in either order:

- Disable on GitHub: Settings → Webhooks → uncheck Active. Hydra's receiver keeps running but receives nothing.
- Disable on Hydra: `fly secrets set HYDRA_WEBHOOK_ENABLED=0 --app <app>`. The follow-up entrypoint integration (separate ticket) honors this flag to skip launching the receiver. Until that lands, kill the tmux window manually.

Polling-based pickup continues regardless — `state/autopickup.json` is unchanged by webhook setup.

### Security notes

- **Secret never touches disk on the receiver side.** Read from env var only. Never logged. The self-test `webhook-receiver-hmac` (in `self-test/golden-cases.example.json`) asserts this.
- **Request body never logged.** Webhook payloads contain issue body text which may be proprietary. Stderr lines log only event type + action + result verb, never the raw JSON.
- **HMAC compare is constant-time.** Uses `hmac.compare_digest()` — no timing oracle on signature mismatch. 401 responses are opaque ("signature verification failed") with no hint about which half mismatched.
- **TLS termination at Fly's edge only.** Plaintext port 8766 is bound inside the VM but never exposed publicly. The `[[services]]` stanza in `infra/fly.toml` deliberately omits a plaintext handler.
- **Body-size cap (1 MiB).** Larger POSTs are 400'd before HMAC compute. GitHub issue payloads are ~100 KiB worst-case so the cap leaves headroom for label-heavy repos.
- **Per-repo webhook secrets** are NOT supported in Phase 1 — one global `HYDRA_WEBHOOK_SECRET` covers every registered repo. If an operator needs per-repo secret isolation, file a follow-up.

### Troubleshooting

| Symptom | Check |
|---|---|
| Every delivery returns 401 | Secret mismatch. Re-run `fly secrets set HYDRA_WEBHOOK_SECRET=...` and `gh api --method PATCH /repos/<o>/<r>/hooks/<id> -f config[secret]=...` with the SAME value. |
| Every delivery returns 204, sentinel never appears | Wrong event subscription. Webhook must be subscribed to `issues` events (not `issue` singular, not `issue_comment`). Re-run the registration `gh api` command above with `-F events[]=issues`. |
| `fly ssh console -C 'ls /hydra/data/state/webhook-triggers/'` is empty after a successful 200 | The sentinel directory may not exist yet. Receiver auto-creates it on first write — confirm with a `mkdir -p /hydra/data/state/webhook-triggers` and retry. |
| Receiver refuses to start with `HYDRA_WEBHOOK_SECRET env var is not set` | Secret was unset by a typo'd `fly secrets set`. List secrets with `fly secrets list --app <app>` and confirm `HYDRA_WEBHOOK_SECRET` is present. |
| Connection refused from GitHub side | The `[[services]]` block in `infra/fly.toml` didn't take effect — re-run `fly deploy --app <app>` and check `fly status --app <app>` shows port 8766 in the services list. |

### Self-test

```bash
./self-test/run.sh --case webhook-receiver-hmac
```

Runs offline (no GitHub, no network) — boots the receiver on a random free port, exercises HMAC good/bad/missing, event-filter good/bad, and asserts the body-leak + secret-leak guards. Spec: [`docs/specs/2026-04-17-github-webhook-receiver.md`](specs/2026-04-17-github-webhook-receiver.md).

## Wiring up an external MCP agent (OpenClaw, Discord bridge, your own Claude)

Once the commander is live with `./hydra mcp serve` booted by `infra/entrypoint.sh`, the MCP surface refuses every request until at least one authorized agent has a real bearer-token hash in `state/connectors/mcp.json`. The `./hydra mcp register-agent` command is the one-step recipe. Spec: [`docs/specs/2026-04-17-mcp-register-agent.md`](specs/2026-04-17-mcp-register-agent.md) · Ticket: [#84](https://github.com/tonychang04/hydra/issues/84).

### 3-step recipe

**1. Generate a token for the client agent (run on the commander):**

```bash
fly ssh console --app <app> -C './hydra mcp register-agent openclaw'
```

You'll see something like:

```
HQxVndgBkWFivV0SsT0AmWrYd6Z0bvzIg3P8+sEH0tI=

⚠ This is the only time this token will be shown.
  Copy it into the consuming agent's config NOW.

  registered agent-id=openclaw
  scope=[read] — widen by editing the config if needed
  Hash stored in /hydra/data/state/connectors/mcp.json
✓ done
```

The first line (before the blank) is the raw token — that's stdout. Everything else is stderr (the warning banner). Copy the token immediately; re-running `register-agent` without `--rotate` won't reveal it again (by design — only the SHA-256 hash is persisted).

The new entry is scoped `["read"]` by default. To grant `spawn`, `merge`, or `admin` scope, edit `state/connectors/mcp.json` on the commander volume by hand:

```bash
fly ssh console --app <app>
# inside the VM:
vi /hydra/data/state/connectors/mcp.json
# add "spawn" to the entry's scope array, save, exit
# no restart needed — the server reads the config on each request
```

**2. Paste the token into the consuming agent's config.**

The exact place depends on the client. For OpenClaw, Hermes, Codex, Cursor, or any HTTP-speaking agent, it goes in whatever env var or config field that agent reads for its MCP bearer — typically `HYDRA_MCP_TOKEN` or similar. The consumer presents it in an `Authorization: Bearer <token>` header on every JSON-RPC POST to `https://<app>.fly.dev/mcp` (or the local equivalent if you haven't put TLS in front yet — see `state/connectors/mcp.json:server.bind_address` for the caveat about never binding `0.0.0.0` without a reverse proxy).

**3. Verify the handshake:**

```bash
curl -s -X POST "https://<app>.fly.dev/mcp" \
  -H "Authorization: Bearer <token-from-step-1>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | jq '.result.tools | length'
# → 13
```

A `401` means a bad token; a `403` means the token is valid but the scope doesn't cover the tool being called. The commander writes one audit line per call to `logs/mcp-audit.jsonl` — tail it to see who's calling what.

### Rotating a token

```bash
fly ssh console --app <app> -C './hydra mcp register-agent openclaw --rotate'
```

`--rotate` replaces `token_hash` only — the entry's `id` and `scope` are preserved. The old token becomes invalid the moment the `mv` completes (atomic config swap). Paste the new token into the consumer's config; no commander restart needed.

### De-authorizing an agent

No dedicated CLI for this (intentionally — deletion is less common than rotation and the file is small). Edit `state/connectors/mcp.json` on the commander and remove the entry from `authorized_agents`:

```bash
fly ssh console --app <app>
vi /hydra/data/state/connectors/mcp.json
# remove the {"id": "openclaw", …} object from authorized_agents[]
# save, exit
```

The next request from that agent returns `401`. No restart needed.

### What `register-agent` does NOT do

- **Does not push to `fly secrets`.** Follow-up work: a `--fly-secret NAME` flag. For now, copy the token manually. Non-goal called out in the spec.
- **Does not edit `scope`.** The CLI only creates (`["read"]` default) or rotates (`token_hash` only). Scope changes are always hand-edits — deliberately, because widening to `"merge"` or `"admin"` warrants a moment of thought.
- **Does not reveal old tokens.** Re-running without `--rotate` on an existing id returns exit 1. The only way to get back a usable token is to rotate.
- **Does not work interactively.** There's no prompt for the agent-id or a paste flow — it's non-interactive on purpose (so a token never sits in a readline buffer that could end up in `.bash_history` on some shells).

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

## Configuring the Codex backend

Hydra supports spawning OpenAI's `codex` CLI as an implementation worker backend alongside the default Claude Code worker. Dual-backend gives commander rate-limit resilience (Claude quota exhaustion → Codex keeps shipping), cost/speed arbitrage, and a primitive for future second-opinion spawning. The infrastructure lives in two places:

- [`.claude/agents/worker-codex-implementation.md`](../.claude/agents/worker-codex-implementation.md) — subagent definition that orchestrates `codex exec` for code-gen while keeping commander-handshake logic in Claude.
- [`scripts/hydra-codex-exec.sh`](../scripts/hydra-codex-exec.sh) — thin wrapper (≤250 LOC) that invokes `codex exec` against a given worktree + task prompt, detects diff / no-diff / unavailable, and returns a deterministic exit code.

Spec: [`docs/specs/2026-04-17-codex-worker-backend.md`](specs/2026-04-17-codex-worker-backend.md).

### Prerequisites

| Need | How |
|---|---|
| `codex` CLI on `$PATH` inside the runtime env | Install per [Codex CLI docs](https://github.com/openai/codex) — either in your local shell (legacy direct-drive) or baked into `infra/Dockerfile` for the Fly Machine (Phase 2). |
| One of: `OPENAI_API_KEY` **or** a valid ChatGPT session that supports `gpt-5.2-codex` | See "Auth modes" below. |
| `./hydra doctor` green | Runs `scripts/hydra-codex-exec.sh --check` transitively once the doctor's codex-category check lands. For now you can invoke `scripts/hydra-codex-exec.sh --check` directly — exit 0 means the wrapper sees codex; exit 1 means codex isn't on PATH; exit 4 means codex is present but auth/model is broken. |

### Auth modes

The wrapper prefers API-key auth when present and falls back to whatever `codex login` has persisted on the host. Concretely:

1. **`OPENAI_API_KEY` set in the environment.** Preferred. Works with any account tier that has API access. On Fly, set it as a secret: `fly secrets set OPENAI_API_KEY=sk-...`. On a local laptop, export it from your shell rc or an `.envrc`. The wrapper pipes the task prompt via stdin and never echoes the key.
2. **ChatGPT-session auth** (persisted under `~/.codex/` after `codex login`). Works if your account tier supports `gpt-5.2-codex`. Known-broken on ChatGPT Plus today — see "Known blocker" below.

You do **not** need both. The wrapper picks whichever one is present; API-key wins on ties.

### Flipping a repo to the Codex backend

Once `codex` is installed and auth works, opt a specific repo in by editing [`state/repos.json`](../state/repos.example.json) and setting `preferred_backend`:

```json
{
  "repos": [
    {
      "owner": "your-org",
      "name": "your-repo",
      "local_path": "/absolute/path/to/clone",
      "enabled": true,
      "ticket_trigger": "assignee",
      "preferred_backend": "codex"
    }
  ]
}
```

Valid values:

| Value | Meaning |
|---|---|
| `claude` (default if absent) | `worker-implementation` (the Claude Code subagent). Current behavior, no change. |
| `codex` | `worker-codex-implementation` (the Codex-backed subagent). Only honored once ticket [#97](https://github.com/tonychang04/hydra/issues/97) wires the router; until then commander still spawns Claude, but the field is valid and documented for forward-compat. |
| `auto` | Future rate-limit-aware routing (ticket [#97]). Currently treated as `claude`. |

The field is additive: leaving it absent is explicitly supported and means "use Claude." Run `./hydra status` (or `scripts/validate-state.sh state/repos.json`) to sanity-check the change parses.

### Known blocker (operator side)

Some operators on a ChatGPT Plus account hit this when invoking `codex exec`:

```
gpt-5.2-codex model is not supported when using Codex with a ChatGPT account
```

**This is not a Hydra bug.** It's an OpenAI account-tier constraint around which models a ChatGPT-session-authenticated CLI can invoke. Two fixes:

1. **Switch to API-key auth.** Get an API key from the OpenAI dashboard, `export OPENAI_API_KEY=sk-...`, re-run `scripts/hydra-codex-exec.sh --check`. Most common resolution.
2. **Upgrade your account.** A tier that supports `gpt-5.2-codex` under ChatGPT-session auth fixes it without an API key.

The wrapper detects this error and returns exit code 4 (`codex-unavailable`), which commander surfaces as `commander-stuck` with a clear "codex-unavailable: model-not-supported" reason — it does **not** silently fall back to Claude. Silent fallback would hide the signal that drives future routing in [#97].

### Troubleshooting

| Symptom | Check |
|---|---|
| `./scripts/hydra-codex-exec.sh --check` exits 1 "codex CLI not on PATH" | Install the Codex CLI per upstream docs; re-run. On Fly, add the install step to `infra/Dockerfile` and redeploy. |
| `--check` exits 4 "codex-unavailable" | Auth problem. Run `codex --version` by hand to see the raw error; then either set `OPENAI_API_KEY` or run `codex login`. |
| A ticket PR opens as `worker-implementation` even though `preferred_backend: codex` | Expected until [#97] lands. Until then, `preferred_backend` is persisted and validated but not yet routed on. |
| Wrapper reports "codex exec completed with exit 0 but produced no changes" | Codex accepted the prompt but refused to edit anything — usually means the task prompt was too vague or asked Codex to touch a disallowed path. Check the worker's commit log for the task prompt it sent. |
| Prompt text appears in commander logs | File a security bug. The wrapper pipes via stdin and scrubs stderr; any leak is a regression. The `codex-worker-fixture` self-test asserts this invariant. |

### Self-test

```bash
./self-test/run.sh --case codex-worker-fixture
```

Runs the wrapper against four stubbed `codex` binaries (success / no-change / model-not-supported / rate-limit), verifying every exit code and the prompt-leak security invariant. Runs on CI (script-kind). Set `HYDRA_TEST_CODEX_E2E=1` to additionally smoke-check against a real `codex` install on your host.

## Using a dedicated bot account

Hydra's `assignee` trigger polls `@me` by default — Commander picks up issues assigned to whoever owns the `GITHUB_TOKEN` it's authenticated with. In practice, that's the operator's own GitHub user, and the same user they use for their own in-progress work. Two meanings collide: "I'm working on this myself" and "Commander should take this".

The fix is to route tickets Commander should take to a **dedicated bot account** — e.g. a free GitHub user `hydra-bot-<your-handle>` — and configure the repo to poll that bot instead of `@me`. Your own self-assigned tickets stay clear of Commander.

This is **phase 1** of the bot-account story: the bot is the polling identity only. Commander still opens PRs and posts comments under whatever `GITHUB_TOKEN` is configured (typically the operator's). Bot-authored PRs, bot-posted review comments, and a dedicated bot-token file are follow-up tickets — see the "What this does not cover" subsection below.

Spec: [`docs/specs/2026-04-17-assignee-override.md`](specs/2026-04-17-assignee-override.md) · Ticket: [#26](https://github.com/tonychang04/hydra/issues/26).

### When to enable

You probably want this if:

- Multiple people share the repo and everyone's self-assigned tickets leak into Commander's view.
- You self-assign tickets as your own "working on this" marker and want a bright line between those and "Commander, take this" tickets.
- You run multiple Hydra operators against the same repo (each operator's bot can poll disjoint slices).

You probably don't want this if:

- You're the only person in the repo and you don't self-assign personal work — `@me` is simpler and already works.
- The repo uses the `label` trigger (`commander-ready`) — bot mode only affects the `assignee` trigger; `label` is already unambiguous.

### Step 1 — Create the bot GitHub user

1. Sign out of GitHub (or use an incognito window).
2. Create a new free GitHub account. Suggested login: `hydra-bot-<your-handle>` (e.g. `hydra-bot-alice`). Any valid login works; the schema accepts `^[A-Za-z0-9-]+(\[bot\])?$`.
3. Accept the email verification.
4. Add the bot as a collaborator on each repo you want Hydra to poll (Settings → Collaborators). Scope the bot to only the repos in `state/repos.json` — it doesn't need org-wide access.

This is a **human step** and intentionally so. Hydra doesn't create GitHub accounts; you do.

### Step 2 — Set `assignee_override` per repo

Easiest path: use the CLI.

```bash
./hydra add-repo your-org/your-repo \
  --local-path ~/projects/your-repo \
  --trigger assignee \
  --assignee hydra-bot-alice \
  --non-interactive
```

Or, for a repo that's already in `state/repos.json`, re-run with `--force`:

```bash
./hydra add-repo your-org/your-repo \
  --local-path ~/projects/your-repo \
  --trigger assignee \
  --assignee hydra-bot-alice \
  --force \
  --non-interactive
```

Or edit `state/repos.json` by hand — add the field to the relevant entry:

```json
{
  "owner": "your-org",
  "name": "your-repo",
  "local_path": "/absolute/path",
  "enabled": true,
  "ticket_trigger": "assignee",
  "assignee_override": "hydra-bot-alice"
}
```

Validation: `scripts/validate-state.sh state/repos.json` — rejects invalid login shapes and empty strings with a clear error. Commander's preflight also runs this on every tick.

### Step 3 — Assign tickets to the bot

From GitHub's UI (or via `gh`):

```bash
gh issue edit 42 --add-assignee hydra-bot-alice --repo your-org/your-repo
```

On the next Commander tick, `gh issue list --assignee hydra-bot-alice --state open` is what gets polled instead of `@me`.

### Step 4 — Verify

```bash
# Local sanity check: what would Commander poll?
jq -r '.repos[] | "\(.owner)/\(.name): assignee=\(.assignee_override // "@me") trigger=\(.ticket_trigger)"' state/repos.json
```

Expected output for the configured repo:

```
your-org/your-repo: assignee=hydra-bot-alice trigger=assignee
```

Any repo you didn't touch still says `assignee=@me` — absent override = legacy behavior.

### What this does NOT cover (separate tickets)

Phase 1 is deliberately small. The following are explicit non-goals of this PR; each warrants its own ticket:

- **Bot-token storage.** The bot account currently doesn't log into Hydra — Commander still polls via the operator's own `GITHUB_TOKEN`. That works fine as long as the operator's token has read access to the bot's assigned issues (which it does for any repo they collaborate on). A future ticket wires up a separate `~/.hydra/bot-token` so Commander can authenticate AS the bot for polling. Needed if/when you want the bot account to also own the PR / comment traffic.
- **Bot-authored PRs, comments, labels, and review postings.** Requires the bot-token layer.
- **Auto-pause on bot-token expiry / revocation.** Requires the bot-token layer.
- **GitHub App registration.** Future (phase 2 / enterprise). Apps get a stable identity with richer auth, at the cost of a registration step.
- **Team mode (multiple operators sharing one bot).** Considered but deferred — for now, one bot per operator keeps the mental model simple.
- **Linear analogue.** Linear has its own assignee model; a future ticket can add `assignee_override` semantics for `ticket_trigger: linear` if / when there's demand.

### Rollback

Remove the `assignee_override` field from the relevant `state/repos.json` entry — either by hand-editing or by `./hydra add-repo <slug> --force` without `--assignee`. Commander is back to `@me` on the next tick. No data loss, no schema migration.

## Non-Fly operators (Hetzner, DO, bare VPS)

Use `infra/systemd/hydra.service` instead of Fly. The install steps are documented in-file at the top of that unit. Same `infra/entrypoint.sh` runs in both paths, so the operational muscle memory (attach, logs, deploy) carries over via `journalctl -u hydra.service -f` and `sudo -iu hydra tmux attach -t commander`.
