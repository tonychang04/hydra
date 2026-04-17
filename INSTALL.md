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

## Option A — one-liner install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/tonychang04/hydra/main/install.sh | bash
```

What this does:
1. Verifies prereqs
2. Clones `tonychang04/hydra` to `~/hydra` (override with `HYDRA_INSTALL_DIR=...` before the curl)
3. Runs `./setup.sh` interactively
4. Prints next steps

If you're uncomfortable piping curl to bash, use Option B.

## Option B — manual install

```bash
git clone https://github.com/tonychang04/hydra.git
cd hydra
./setup.sh
```

`setup.sh` is idempotent. Safe to re-run anytime.

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
| `./hydra: claude: command not found` | Install Claude Code and ensure it's in PATH |
| `gh auth status` fails | `gh auth login` |
| Setup complains about `.claude/` being globally gitignored | Expected if your `~/.gitignore` has `.claude`. Force-adding framework files in the hydra repo is handled by the repo's own `.gitignore` rules via explicit commits; nothing for you to do. |
| Commander says "0 repos enabled" | Edit `state/repos.json` — set at least one `"enabled": true` |
| Workers immediately hit `commander-stuck` on every ticket | Check `$HYDRA_EXTERNAL_MEMORY_DIR` exists and is writable. Run `./setup.sh` again — it's idempotent. |
| `state/repos.json:local_path` wrong → worker can't find repo | `gh auth status` + verify the path is an absolute path to a git clone of that repo |
