# Installing Hydra

Full reference. For the TL;DR one-liner see [README.md §Install](README.md#install).

## Prerequisites

You need these installed and working in your `PATH`:

| Tool | Why | How to get it |
|---|---|---|
| **Claude Code** | Hydra runs as a Claude Code session | https://claude.com/claude-code |
| **git** | Worktrees are the core safety primitive | Usually pre-installed on macOS/Linux |
| **GitHub CLI (`gh`)** | Reading issues + opening PRs | `brew install gh` (macOS) or see https://cli.github.com/ |
| **jq** (optional but recommended) | Small state file manipulation in shell | `brew install jq` |

Authenticate GitHub CLI once:
```bash
gh auth login
gh auth status   # should confirm you're logged in
```

Without `gh auth`, Hydra's workers cannot open PRs.

## Three install paths

Pick the one that matches how you want to drive Hydra:

| Option | Mode | Who drives Hydra | When to pick it |
|---|---|---|---|
| **A — cloud + MCP** | Cloud | Another agent (your Main Agent / a supervisor bot), over MCP | You want Commander headless on Fly.io so it keeps ticking while your laptop's closed. **Recommended for any operator who wants 24/7 commander.** |
| **B — one-liner local (dev mode)** | Local | You, in a terminal chat with Commander | You want the fastest way to try Hydra on your laptop before committing to cloud. |
| **C — manual local (dev mode)** | Local | You, in a terminal chat with Commander | Same end-state as B, but you prefer reading each step before it runs. |

Cloud commander (Option A) is the supported primary mode as of 2026-04-17. Options B / C still work and are fully supported — use them for offline work, CI fixtures, or if you haven't set up a Fly.io account yet. You can **migrate from local to cloud later** with a single command (`scripts/hydra-migrate-to-cloud.sh`) without losing memory or state.

## Option A — cloud + MCP (recommended)

Commander runs on a cheap Fly.io Machine. Flat-rate OAuth billing covers Claude Code Max **and** Codex (no metered API bills). Another agent (your Main Agent / a custom supervisor) calls `hydra.*` tools over MCP to dispatch work.

### Prerequisites

- **Fly.io account.** Free tier + credit card on file. See [fly.io/docs/hands-on/install-flyctl](https://fly.io/docs/hands-on/install-flyctl/) + `fly auth login`.
- **Claude Code Max subscription** (preferred auth) OR `ANTHROPIC_API_KEY`. Either unlocks commander's reasoning.
- **Optional: Codex CLI auth** (`OPENAI_API_KEY` or `codex login` session). Lets commander route some repos to the Codex backend per `state/repos.json:preferred_backend` — see `docs/phase2-vps-runbook.md` "Configuring the Codex backend".
- **GitHub personal access token** with `repo` + `workflow` scope. `gh auth token` prints yours.

### First-time deploy (fresh install, no local copy yet)

```bash
git clone https://github.com/tonychang04/hydra.git
cd hydra
./setup.sh                              # bootstrap state files + ./hydra launcher
./scripts/deploy-vps.sh                 # one-command Fly.io deploy
```

`deploy-vps.sh` prompts for Fly app name, region, `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`), and `GITHUB_TOKEN`, then runs `fly launch --copy-config`, stages the secrets, creates a persistent volume, and deploys.

**Full walkthrough, cost estimates, rollback, monitoring, security notes:** [`docs/phase2-vps-runbook.md`](docs/phase2-vps-runbook.md).

### Already have local commander? Migrate to cloud

If you've been running Hydra locally (Option B or C below) and want to move to cloud without losing memory / state / learnings:

```bash
./scripts/hydra-migrate-to-cloud.sh --dry-run     # rehearse
./scripts/hydra-migrate-to-cloud.sh               # the real thing
```

The script walks you through: generate both OAuth tokens → push to `fly secrets` → generate MCP bearer for your main agent → deploy + health-check. Dry-run mode executes no side effects.

See [`docs/phase2-vps-runbook.md` → "Migrating from local to cloud"](docs/phase2-vps-runbook.md#migrating-from-local-to-cloud) for the full walkthrough + rollback.

### Connect your main agent via MCP

Once commander is live on Fly, your **main agent** (your own Claude Code session, a custom supervisor bot, OpenClaw, Hermes, etc.) connects as an MCP client and calls `hydra.*` tools to dispatch work.

For per-client recipes (Claude Code, Cursor, Zed, OpenClaw, generic MCP) with copy-pasteable config, sanity checks, and common-failure troubleshooting, see **[docs/connecting-your-agent/](docs/connecting-your-agent/)**. The steps below are the manual primitive the `./hydra pair-agent` wrapper automates.

1. **Generate a bearer token for the main agent** (run on the commander):
   ```bash
   fly ssh console --app <your-app> -C './hydra mcp register-agent main-agent'
   ```
   Prints a 44-char base64 token to stdout **exactly once** — copy it immediately.
2. **Paste the token into your main agent's config.** Typically an env var like `HYDRA_MCP_TOKEN`, presented as `Authorization: Bearer <token>` on JSON-RPC POSTs to `https://<your-app>.fly.dev/mcp`.
3. **Your main agent now has `hydra.*` tools available** — no direct chat with Commander. Example tool calls:
   ```
   hydra.pick_up({count: 3})
   hydra.get_status({})
   hydra.merge_pr({pr_num: 501, caller_agent_id: "main-agent"})
   ```
4. **Commander runs headless.** Escalations (worker `QUESTION:` blocks that don't match memory) flow **outbound** via `supervisor.resolve_question` — Hydra calls the supervisor agent, which decides whether to answer autonomously or loop a human through its own channel.

Full MCP tool surface + auth model + rotation docs: [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md), [`docs/phase2-vps-runbook.md`](docs/phase2-vps-runbook.md).

### Legacy and agent-driven coexist

Migration is reversible. Cloud commander on Fly and laptop commander (`./hydra` locally) can run side by side — turn one off with `autopickup off` on whichever you want idle. Migration doesn't disable local mode.

## Option B — one-liner local install (dev mode)

Run Commander on your laptop in a terminal chat. Fastest way to try Hydra before committing to cloud. Works offline, no Fly account required.

```bash
curl -fsSL https://raw.githubusercontent.com/tonychang04/hydra/main/install.sh | bash
```

What this does:
1. Verifies prereqs
2. Clones `tonychang04/hydra` to `~/hydra` (override with `HYDRA_INSTALL_DIR=...` before the curl)
3. Runs `./setup.sh` interactively
4. Prints next steps

If you're uncomfortable piping curl to bash, use Option C.

## Option C — manual local install (dev mode)

```bash
git clone https://github.com/tonychang04/hydra.git
cd hydra
./setup.sh
```

`setup.sh` is idempotent. Safe to re-run anytime.

Options B and C are both **legacy / direct-drive mode**: an operator sits in a terminal and types `pick up 2` to Commander. Fully supported — this is how most installs ran in 2026-04-16, and how most operators still develop + test framework changes. When you're ready for 24/7 cloud commander, migrate with `./scripts/hydra-migrate-to-cloud.sh` (see Option A).

## MCP surface reference (for Option A)

The **agent-only interface** replaces the terminal-chat surface with an MCP (Model Context Protocol) server. Another agent — the operator's main Claude Code session, a custom supervisor agent, a dashboard bot — connects as a client and calls `hydra.*` tools. Commander runs headless. No human types at a Commander prompt.

### End-state flow (MCP server is live as of 2026-04-17)

1. Operator runs Hydra (on laptop or VPS) in MCP-server mode:
   ```bash
   ./hydra mcp serve
   ```
   On cloud, `infra/entrypoint.sh` launches it automatically when `state/connectors/mcp.json` exists with authorized agents. Commander boots, reads `state/connectors/mcp.json`, binds the configured transport (stdio or http), and waits.
2. Operator's main agent (Claude Code, custom supervisor, whatever speaks MCP) connects:
   ```bash
   claude mcp add hydra <stdio-command-or-http-url>
   ```
   For stdio, the command is `ssh operator@vps ./hydra mcp serve` (or a local equivalent). For http, the URL is `https://your-hydra-host:8765/mcp`.
3. The main agent now has `hydra.*` tools available — no direct chat with Commander. It sends commands the same way it sends any tool call:
   ```
   hydra.pick_up({count: 3})
   hydra.get_status({})
   hydra.merge_pr({pr_num: 501, caller_agent_id: "supervisor-main"})
   ```
4. Commander stays headless. Escalations (worker `QUESTION:` blocks that don't match memory) flow **outbound** via `supervisor.resolve_question` — Hydra calls the supervisor agent, the supervisor agent decides whether to answer autonomously or loop a human through its own channel.

### What to read next

- `mcp/hydra-tools.json` — every tool you'll be able to call, with JSON Schema.
- `docs/mcp-tool-contract.md` — the prose version: use cases, tradeoffs, scope boundaries per tool.
- `state/connectors/mcp.json.example` — copy to `state/connectors/mcp.json` and pre-configure your authorized agents + upstream supervisor. The MCP server reads this file on each request (see `./hydra mcp serve` and `./hydra mcp register-agent`).
- `docs/specs/2026-04-16-mcp-agent-interface.md` — the why and the scope decisions.

### Auth model (four scope levels)

Tokens for each authorized agent are declared in `state/connectors/mcp.json:authorized_agents[]`. Every entry carries:
- `id`: free-form label you choose.
- `token_hash`: SHA-256 hex digest of the bearer token. **Never commit the raw token** — only its hash.
- `scope`: an array of `["read", "spawn", "merge", "admin"]`.

Scope semantics are documented in `docs/mcp-tool-contract.md`. The tier policy (`policy.md`) is enforced below the scope check — an `admin` + `merge` token still cannot merge a T3 PR through MCP.

### Legacy and agent-driven coexist

Running `./hydra mcp serve` does NOT disable the terminal-chat path — they're both valid surfaces on the same Commander. Most operators will use one or the other; the two surfaces exist to cover different deployment shapes (single-operator laptop vs. cloud-hosted headless).

## What `setup.sh` does

1. Verifies `claude`, `gh`, and `gh auth status` all green
2. Asks ONE question: where should external operational memory live?
   - Default `~/.hydra/memory/` (recommended)
   - External memory = per-target-repo learnings about the codebases you point Hydra at. Deliberately outside the cloned hydra repo so it never leaks into a framework PR.
3. Creates `.claude/settings.local.json` from the committed template, filling in your absolute paths
4. Creates `state/repos.json` from the template (you edit this next)
5. Initializes empty runtime state files in `state/`
6. Writes `.hydra.env` with your configured paths (gitignored)
7. Generates `./hydra` — the launcher script that sources the env and runs `claude` (gitignored)

All written files except `.claude/settings.local.json` and `state/repos.json` are either gitignored or come from committed templates. Nothing you touch is at risk of being committed to the framework repo.

## Configure which repos Hydra works on

Open `state/repos.json`. The template includes:
- A `tonychang04/hydra` entry (dogfood — Hydra working on Hydra; disabled by default)
- Example entries for your own repos
- An infra-repo example (disabled; shows the pattern for always-Tier-3 repos)

Edit it:

```json
{
  "repos": [
    {
      "owner": "tonychang04",
      "name": "hydra",
      "local_path": "/Users/you/hydra",
      "enabled": true,
      "ticket_trigger": "assignee"
    },
    {
      "owner": "your-org",
      "name": "your-repo",
      "local_path": "/Users/you/code/your-repo",
      "enabled": true,
      "ticket_trigger": "assignee"
    }
  ]
}
```

- `local_path` is the absolute path to where you've cloned that repo. Hydra creates git worktrees from this path.
- `ticket_trigger` is either `"assignee"` (Hydra picks up anything assigned to you on that repo) or `"label"` (Hydra picks up anything labeled `commander-ready`).
- `enabled: false` temporarily excludes a repo without deleting the entry.

## (Optional) Linear

If tickets live in Linear, Hydra can pick them up via the Linear MCP server instead of (or alongside) GitHub Issues. **Status:** the Linear path is scaffolded and fixture-tested; end-to-end validation against a live Linear workspace is still pending — see `docs/linear-tool-contract.md` for the exact tool surface Hydra assumes and the operator validation checklist at the bottom.

### 1. Install the Linear MCP server

```bash
claude mcp add linear
```

What to expect at the prompts:
- It asks which scope (`user` vs `project`) — pick `user` if you want Linear available across all your Claude Code sessions.
- It opens a browser OAuth flow to `https://linear.app/oauth/...`. Authenticate as the Linear user whose tickets Hydra should see.
- On success, `claude mcp list` shows `linear` as a registered server.

Verify:
```bash
claude mcp list | grep -i linear     # should print the linear server entry
```

### 2. Copy the config template and fill it in

```bash
cp state/linear.example.json state/linear.json
```

Minimum fields to edit:

| Field | What to put |
|---|---|
| `enabled` | Flip to `true` once everything below is filled |
| `teams[0].team_id` | Your Linear team's internal UUID. Find via: Linear Web → Settings → Teams → click your team → the URL has `/team/ABC-123/...` where `ABC` is the team key; the UUID appears in `Settings → API → Team ID`. |
| `teams[0].team_name` | Human-readable name (for your own reference; Hydra logs it) |
| `teams[0].trigger.type` | One of: `assignee` (pick up issues assigned to you), `state` (pick up issues in a named state), `label` (pick up issues with a specific label) |
| `teams[0].trigger.value` | `me` for assignee; the state name (e.g. `Ready for Hydra`) for state; the label name for label |
| `teams[0].repo_mapping` | Replace `your-org/your-repo` with the GitHub repo(s) this Linear team's tickets correspond to. Hydra needs this to know which local clone to worktree from. |
| `state_transitions.*` | Leave defaults unless your team uses custom state names. If so, ALSO populate `teams[0].state_name_mapping` to map Hydra's logical names to yours. |
| `rate_limit_per_hour` | Defaults to 60. Lower it if your workspace has tight API limits. |

Then in `state/repos.json`, set `"ticket_trigger": "linear"` on each repo whose Linear tickets Hydra should pick up.

### 3. Smoke-test the wiring WITHOUT hitting Linear

Hydra ships a fixture-mode poll script so you can verify your install can parse a realistic Linear response before trusting it against live data:

```bash
scripts/linear-poll.sh --fixture self-test/fixtures/linear/mock-list-issues-response.json
```

Expected output: a normalized JSON blob with `"source": "fixture"`, `"count": 3`, and three ENG-xxx issues. If this fails, `jq` is missing or the script can't find the fixture.

### 4. Validate against your live Linear workspace

Work through the checklist in `docs/linear-tool-contract.md`. In short:

```bash
# Live poll your assigned issues:
scripts/linear-poll.sh --team <your-team-uuid> --trigger-type assignee --trigger-value me
```

If it returns your actual open Linear issues, the integration is live. If it returns an auth error or "Linear MCP server not installed", re-run step 1.

### Troubleshooting Linear

| Symptom | Fix |
|---|---|
| `Linear MCP server ('linear') not installed` | Run `claude mcp add linear`. Verify with `claude mcp list`. |
| `Linear MCP auth failed` / 401 / 403 | Re-run `claude mcp add linear` — the OAuth token has likely expired. If you previously authed as the wrong Linear user, remove first: `claude mcp remove linear`. |
| `Linear MCP rate-limited` | Back off; retry in an hour. Lower `rate_limit_per_hour` in `state/linear.json` to prevent future hits. |
| "Linear state 'In Review' not found on team..." | Your team uses custom state names. Populate `teams[0].state_name_mapping` in `state/linear.json` to map Hydra's logical names (`In Review`, `Done`, etc.) to your actual state names. |
| Tool names differ from `docs/linear-tool-contract.md` | Override with env vars (e.g. `HYDRA_LINEAR_TOOL_LIST=list_issues`) and open a PR to correct the tool contract doc — that's the single source of truth. |
| Can't find the team ID | Linear Web → Settings → API → "Team ID" (or in the URL: `linear.app/<org>/team/<KEY>/...` — the full UUID is in Settings, the short key is in the URL). |

## Launch

```bash
cd /path/to/your/hydra
./hydra
```

The `./hydra` launcher sources `.hydra.env`, preflight-checks, then runs `claude` in this directory. Claude Code auto-loads `CLAUDE.md` as the system prompt and becomes the Commander.

You'll see:
```
Hydra online. 0 tickets ready across 2 repos. 0 heads active. Today: 0 done, 0 failed, 0 min wall-clock. Pause: off.
```

Type:
- `show me 5 ready tickets` — inspect without spawning
- `pick up 2` — spawn 2 worker heads in parallel
- `status` — current state

Full command reference in [USING.md](USING.md).

## Phase 2 (optional): Deploy Commander to Fly.io

Run commander on a cheap Linux VPS instead of (or in addition to) your laptop. Keeps it up while you sleep, works from your phone over Slack/SSH, same Max subscription — no metered API bills.

**TL;DR one command:**
```bash
./scripts/deploy-vps.sh
```

The script prompts for the Fly app name, region, your `CLAUDE_CODE_OAUTH_TOKEN` (generate with `claude setup-token` on a host where you're already signed into Claude Code Max), and your `GITHUB_TOKEN`. It then runs `fly launch --copy-config`, stages the secrets, creates a persistent volume for state/memory/logs, and deploys.

**Full walkthrough, cost estimates, rollback, monitoring, security notes:** [`docs/phase2-vps-runbook.md`](docs/phase2-vps-runbook.md).

**Decision record / architecture:** [`docs/specs/2026-04-16-vps-deployment.md`](docs/specs/2026-04-16-vps-deployment.md).

**Non-Fly operators** (Hetzner, Digital Ocean, bare Debian): use `infra/systemd/hydra.service` — install steps are in the comments at the top of that file.

Scope note: this ships the core deploy artifacts (Dockerfile, `fly.toml`, entrypoint, deploy script, docs). The webhook receiver (GitHub/Linear) and Slack bot are separate follow-ups — track in [#40](https://github.com/tonychang04/hydra/issues/40), [#41](https://github.com/tonychang04/hydra/issues/41), [#42](https://github.com/tonychang04/hydra/issues/42).

## Phase 2 — cloud knowledge store (optional)

Phase 1 keeps every learned pattern, every log, and every piece of runtime state on the operator's Mac. Phase 2 moves the heavy stuff to AWS so multiple commander instances can share memory and a commander running on a cloud VM keeps working after a laptop dies.

**Read first:** `docs/phase2-s3-knowledge-store.md` (the why / what-lives-where design) and `docs/specs/2026-04-16-s3-knowledge-store.md` (the implementation notes for this adapter).

**This is an operator-led migration.** Hydra ships the adapters; the operator provisions the AWS resources. Nothing below is automated — every step below produces a real resource in your AWS account.

### 1. Provision the bucket + tables

Create these in the region you want Hydra to live in:

- **S3 bucket** — one per commander instance, e.g. `my-commander-knowledge-<instance>`.
  - Enable **versioning** (so memory edits are recoverable).
  - Enable **SSE-KMS** with an operator-owned CMK (not the AWS-managed `aws/s3` key). Memory files can contain internal ticket bodies.
- **DynamoDB tables** (PAY_PER_REQUEST is fine; each table is a single row):
  - `commander-active` — in-flight workers
  - `commander-budget` — daily counters
  - `commander-memory-citations` — citation leaderboard
  - All three use partition key `id` (string).

### 2. Create an IAM role with scoped permissions

The role the commander VM (or your local laptop, via `aws sso login` / profile assume) assumes needs:

```
s3:ListBucket                on arn:aws:s3:::<bucket>
s3:GetObject, s3:PutObject,
s3:DeleteObject              on arn:aws:s3:::<bucket>/<prefix>/*
dynamodb:GetItem, PutItem,
dynamodb:UpdateItem          on arn:aws:dynamodb:<region>:<acct>:table/commander-active
                                 arn:aws:dynamodb:<region>:<acct>:table/commander-budget
                                 arn:aws:dynamodb:<region>:<acct>:table/commander-memory-citations
kms:Decrypt, kms:GenerateDataKey
                              on the CMK used for the bucket (via key policy grant)
```

Keep this role scoped to the single prefix and the three tables. No `*:*`.

### 3. Install `mount-s3`

Mountpoint-for-Amazon-S3 is AWS's POSIX-ish layer over a bucket. Hydra does not bundle it.

```bash
# macOS
brew install --cask mountpoint-s3

# Linux — see https://github.com/awslabs/mountpoint-s3/blob/main/doc/INSTALL.md

mount-s3 --version   # confirm install
```

### 4. Configure env

```bash
cp .env.hydra-phase2.example .env.hydra-phase2
$EDITOR .env.hydra-phase2   # fill in bucket, prefix, region
```

Source it in whichever shell runs `./hydra`:
```bash
set -a; source .env.hydra-phase2; set +a
```

The file is gitignored — never commits.

### 5. Mount and validate

```bash
./scripts/memory-mount.sh
# → mounts s3://<bucket>/<prefix>/ at $HYDRA_EXTERNAL_MEMORY_DIR

ls "$HYDRA_EXTERNAL_MEMORY_DIR"/memory/       # framework + per-instance files
ls "$HYDRA_EXTERNAL_MEMORY_DIR"/logs/         # per-ticket logs

./scripts/state-get.sh --key active           # reads active.json from DynamoDB
```

Unmount when finished (macOS: `umount $HYDRA_EXTERNAL_MEMORY_DIR`; Linux: `fusermount -u $HYDRA_EXTERNAL_MEMORY_DIR`).

### 6. Rolling back

Remove or unset `HYDRA_STATE_BACKEND` (or set it to `local`). Hydra's scripts revert to local JSON files with no other changes. The S3 bucket + DynamoDB rows are left intact so you can re-flip later.

### Caveats — what's NOT automated

- Bucket / table / IAM / KMS provisioning (by design — these are your account, not Hydra's).
- Automatic migration of existing local memory into S3. Do that with `aws s3 sync memory/ s3://<bucket>/<prefix>/memory/` once, then delete the local copy.
- mount-s3 supervision. If it dies, Hydra will see an empty `memory/` and escalate. Restart the mount.

## Updating Hydra

```bash
cd /path/to/your/hydra
git pull --ff-only
./setup.sh    # idempotent; will leave your config untouched
```

Nothing destructive happens on pull. Your `state/`, `.claude/settings.local.json`, and `memory/learnings-*.md` are all gitignored, so a framework update never touches your config or operational memory.

## Uninstalling

```bash
rm -rf /path/to/your/hydra              # remove the clone
rm -rf ~/.hydra                          # remove external operational memory (ONLY if you're sure)
# Optionally: gh label delete commander-ready --repo <each of your repos>
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Symptom unclear | `./hydra doctor` — runs the full install sanity-check and addresses most misconfigurations. Pass `--verbose` for more detail or `--fix-safe` to auto-repair safe issues (chmod +x, mkdir -p). |
| `./hydra: claude: command not found` | Install Claude Code and ensure it's in PATH |
| `gh auth status` fails | `gh auth login` |
| Setup complains about `.claude/` being globally gitignored | Expected if your `~/.gitignore` has `.claude`. Force-adding framework files in the hydra repo is handled by the repo's own `.gitignore` rules via explicit commits; nothing for you to do. |
| Commander says "0 repos enabled" | Edit `state/repos.json` — set at least one `"enabled": true` |
| Workers immediately hit `commander-stuck` on every ticket | Check `$HYDRA_EXTERNAL_MEMORY_DIR` exists and is writable. Run `./setup.sh` again — it's idempotent. |
| `state/repos.json:local_path` wrong → worker can't find repo | `gh auth status` + verify the path is an absolute path to a git clone of that repo |
