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

If tickets live in Linear:

```bash
claude mcp add linear
# Follow the prompts to authenticate
```

Then `cp state/linear.example.json state/linear.json` and fill in your team ID, trigger type, and repo mapping.

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
