# Wire ensure-repo-cloned.sh + hydra-slack-bot into infra/entrypoint.sh

- **Status:** proposed
- **Ticket:** #80 (follow-up to #73 / #74)
- **Tier:** T2 (edits cloud boot path)
- **Related specs:**
  - `docs/specs/2026-04-17-cloud-repo-clone.md` (#73 — shipped `scripts/ensure-repo-cloned.sh`)
  - `docs/specs/2026-04-17-slack-bot.md` (#74 — shipped `bin/hydra-slack-bot`)
  - `docs/specs/2026-04-17-mcp-server-binary.md` (#72 — last to edit `entrypoint.sh`)

## Problem

PRs #78 (#73) and #79 (#74) shipped `scripts/ensure-repo-cloned.sh` and `bin/hydra-slack-bot`, but both workers deliberately deferred `infra/entrypoint.sh` edits to avoid conflicting with PR #76 (#72), which was simultaneously landing the MCP server launch block in the same file. All three PRs merged cleanly, but the integration steps never happened, so:

1. **Cloud Commander can't run workers.** Nothing on the Fly machine ever calls `scripts/ensure-repo-cloned.sh`, so the first `worker-implementation` spawn on cloud fails with "repo not found at cloud_local_path" because the Fly volume has no clones.
2. **Slack bot never launches.** `entrypoint.sh` never invokes `./bin/hydra-slack-bot`, so the DM surface stays dark even when the operator populated `state/connectors/slack.json` with real tokens.

Both are boot-time wiring gaps, not feature work. The code exists; the glue is missing.

## Goals

- Clone every `enabled=true` repo in `state/repos.json` to its cloud-local path on boot, using the existing `scripts/ensure-repo-cloned.sh` contract. Idempotent — re-boots re-fetch, they don't re-clone.
- Launch `bin/hydra-slack-bot` as a background process when (and only when) `state/connectors/slack.json` exists and has `enabled=true`. Gracefully skip otherwise.
- Do NOT bring the commander down on a single repo-clone failure or a slack bot crash. Core commander boot must keep going — these two surfaces are additive to the commander loop, not prerequisites for it.
- Provide a `HYDRA_DRY_RUN=1` mode that logs what the new stanzas WOULD do and exits before `tmux new-session`, for use in self-tests and in operator pre-deploy sanity.

## Non-goals

- Cloning repos on every worker spawn (boot-clone is sufficient for Phase 1; a per-spawn refresh is a separate optimization).
- Process supervision for the slack bot. If it crashes, it stays dead until the next boot. Acceptable for Phase 1.
- Refactoring `entrypoint.sh`'s existing structure. This PR only adds two new stanzas and a dry-run short-circuit.
- Exposing any new Fly port, mount, or secret. Slack socket mode is outbound-only; repo clones land inside the existing `/hydra/data` volume.
- Touching `CLAUDE.md` docs. A follow-up can document these stanzas once the shape is proven in production.

## Proposed approach

### Placement

Both new stanzas land AFTER the MCP server launch block (section 5, which ends at the current `fi` around line 210) and BEFORE the `tmux new-session` call (currently at line 224). This ordering matters:

- **Repo-clone loop runs BEFORE tmux** so that when commander starts inside tmux and a worker is spawned, the clone is already on disk.
- **Slack bot launches BEFORE tmux** so it's up and auditing by the time commander starts processing DMs. It runs as a background daemon (`&`) — the tmux commander session owns the foreground.

The MCP server already runs `&` in the background; the two new stanzas follow that same supervision pattern (backgrounded processes, pid tracked, cleaned up in the existing trap).

### Stanza 1 — clone all enabled repos

```bash
# ---------- 5b. Clone all enabled repos on boot ----------
REPOS_JSON_PATH="${HYDRA_ROOT}/state/repos.json"
if [[ -f "${REPOS_JSON_PATH}" ]]; then
  log "Cloning enabled repos from state/repos.json"
  # jq -r '.repos[] | select(.enabled == true) | "\(.owner)/\(.name)"'
  # produces one "owner/name" slug per line. Loop over them, calling
  # ensure-repo-cloned.sh. Per-repo failure is logged and skipped — do NOT
  # fail the entrypoint, since commander is still able to boot and serve a
  # single-repo operator if one of the others breaks.
  enabled_slugs="$(jq -r '.repos[]? | select(.enabled == true) | "\(.owner)/\(.name)"' "${REPOS_JSON_PATH}" 2>/dev/null || true)"
  if [[ -z "${enabled_slugs}" ]]; then
    log "No enabled repos — skipping clone loop"
  else
    while IFS= read -r slug; do
      [[ -z "${slug}" ]] && continue
      if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
        log "DRY RUN: would clone ${slug}"
      else
        log "ensure-repo-cloned: ${slug}"
        if ! "${HYDRA_ROOT}/scripts/ensure-repo-cloned.sh" "${slug}" >>"${HYDRA_ROOT}/logs/ensure-repo-cloned.log" 2>&1; then
          log "ensure-repo-cloned: ${slug} FAILED — continuing (worker will retry on spawn)"
        fi
      fi
    done <<<"${enabled_slugs}"
  fi
else
  log "state/repos.json absent — skipping repo-clone loop"
fi
```

### Stanza 2 — launch slack bot if configured

```bash
# ---------- 5c. Launch Slack bot if configured ----------
SLACK_CFG="${HYDRA_ROOT}/state/connectors/slack.json"
SLACK_PID=""
if [[ -f "${SLACK_CFG}" ]] && [[ "$(jq -r .enabled "${SLACK_CFG}" 2>/dev/null)" == "true" ]]; then
  if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
    log "DRY RUN: would launch hydra-slack-bot"
  else
    log "Starting hydra-slack-bot (socket mode, outbound only)"
    ( cd "${HYDRA_ROOT}" && ./bin/hydra-slack-bot >>"${HYDRA_ROOT}/logs/slack-bot.log" 2>&1 ) &
    SLACK_PID=$!
    log "hydra-slack-bot pid=${SLACK_PID}"
  fi
else
  log "Slack bot: state/connectors/slack.json missing or enabled=false — skipping"
fi
```

The bot already enforces its own refuse-to-start gate (missing tokens, bad config → exit 1 immediately; `enabled=false` → exit 0 cleanly). So even a malformed real `slack.json` leads to at worst a background process exiting in a few hundred ms; commander keeps running.

### Dry-run mode

`HYDRA_DRY_RUN=1 infra/entrypoint.sh` logs the two new stanzas' intended actions and then short-circuits **after** section 5c, **before** tmux. This matches the minimal invariant the self-test needs: prove the conditional logic routes correctly without actually cloning or launching anything.

Implementation:

- At the very top of section 6 (the tmux block), add:
  ```bash
  if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
    log "HYDRA_DRY_RUN=1 — exiting after stanza 5c (pre-tmux) for self-test"
    exit 0
  fi
  ```
- The existing env-verification, volume-rewire, health-server, and MCP gates all still run — dry-run is not "skip everything", it's "skip the unrecoverable-cost side effects (tmux pane + claude launch)". Stanzas 5b / 5c use their own inner `HYDRA_DRY_RUN` branch to avoid side-effecting (no clone, no bot launch) but still log the decisions.
- The health server is already backgrounded by the time we hit the dry-run exit; we don't bother killing it — `exit 0` tears down the process group.

### Trap update

The existing shutdown trap at line 241 already kills the MCP server's pid. We add `SLACK_PID` to the same list so SIGTERM during a real boot is clean:

```bash
trap '
  log "shutdown signal received"
  tmux kill-session -t '"${HYDRA_TMUX_SESSION}"' 2>/dev/null || true
  [[ -n "${MCP_PID}" ]] && kill "${MCP_PID}" 2>/dev/null || true
  [[ -n "${SLACK_PID}" ]] && kill "${SLACK_PID}" 2>/dev/null || true
  kill '"${HEALTH_PID}"' 2>/dev/null || true
  exit 0
' TERM INT
```

Health-server-died branch at the bottom (line 262) gets the same one-line addition. Slack bot is NOT in the `wait` set — a Slack outage should never kill Commander.

## Alternatives considered

1. **Systemd / supervisord.** Overkill. `entrypoint.sh` is already the "tiny PID 1" file by design; adding a process supervisor swap contradicts the README's "keep the image simple" rationale.
2. **Clone on first worker spawn, not on boot.** Shifts the latency into the first ticket pickup (several seconds of clone time before the worker even starts), and means a rare operator might never see the failure mode until the first spawn — worse signal-to-noise for debugging. Boot-clone is predictable and observable in `fly logs`.
3. **Run slack bot inside tmux alongside commander.** Forces the operator to attach to tmux to restart the bot. Background process with pid tracking is closer to how the MCP server already works; uniform supervision is less surprising.
4. **Make stanza failures fatal.** Would harden the "everything up or nothing up" invariant at the cost of single-repo outages turning into commander-down incidents. The ticket explicitly calls out "single repo-clone failure doesn't brick boot" — log + continue is the right tradeoff for Phase 1.

## Test plan

**New self-test case (`entrypoint-dry-run-integrations`, T1, script-only):**

Each step uses a temporary worktree-like directory with known-shape fixtures so the test is hermetic. The test:

1. Prepares a fixture `state/repos.json` with one enabled and one disabled repo.
2. Runs `HYDRA_DRY_RUN=1 HYDRA_ROOT=<fixture> CLAUDE_CODE_OAUTH_TOKEN=stub GITHUB_TOKEN=stub HYDRA_MCP_ENABLED=0 infra/entrypoint.sh` and asserts:
   - Exit code 0.
   - stdout contains `DRY RUN: would clone your-org/enabled-repo`.
   - stdout does NOT contain the disabled repo's slug.
   - stdout contains `Slack bot: state/connectors/slack.json missing or enabled=false — skipping` (since fixture omits `slack.json`).
3. With a `slack.json` fixture that has `enabled=true` and stub tokens, re-runs and asserts `DRY RUN: would launch hydra-slack-bot`.
4. With a `slack.json` fixture that has `enabled=false`, asserts the skip message still appears.
5. `bash -n infra/entrypoint.sh` is clean (covered by the existing `entrypoint-idempotent` case, but we re-assert here to keep this case self-contained).

**Manual smoke on Fly:**

- `fly ssh console` into the live commander machine.
- `cat /hydra/state/repos.json` — confirm `enabled:true` entry present.
- Trigger a boot (`fly machine restart` or `fly deploy`).
- Watch `fly logs` for:
  - `ensure-repo-cloned: <owner>/<name>` followed by `[ensure-repo-cloned ...] cloned at /hydra/data/repos/...`.
  - If `slack.json` is present: `hydra-slack-bot pid=<n>` followed by bot startup log in `logs/slack-bot.log`.
  - If `slack.json` is absent: `Slack bot: state/connectors/slack.json missing or enabled=false — skipping`.
- `ls /hydra/data/repos/<owner>/<name>/.git` — confirm the clone actually landed.
- Send a DM from the allowlisted Slack user → confirm the bot replies.

**Existing self-tests that must still pass:**

- `entrypoint-idempotent` (unchanged — still covers `--help`, env guard, `bash -n`).
- `slack-config-example-valid` (unchanged — we don't touch the example).
- `scripts/test-cloud-config.sh` (`bash -n` on all scripts, shellcheck where available).

## Risks / rollback

- **Risk:** a slow or hanging `git clone` stalls boot. Mitigation: `ensure-repo-cloned.sh` uses `--depth 50` (already), and entrypoint moves on if the script hangs past a `&` — actually no, we run it synchronously so a true hang would block. Accepting this risk in Phase 1; the script has `set -euo pipefail` plus network exit-2 codes, so silent infinite hangs are unlikely. Longer-term mitigation is a `timeout 60s` wrapper; out of scope here.
- **Risk:** slack bot process leak (bot dies, but pid is stale). Trap handles clean shutdown. If the bot crashes mid-boot the SLACK_PID still gets cleaned up because `wait` only gates on `HEALTH_PID`; the reaped-zombie case is handled by the kernel.
- **Risk:** a malformed `state/repos.json` JSON kills the `jq` pipeline. Mitigation: `jq ... 2>/dev/null || true` + the `[[ -z ]]` guard means we skip the loop rather than propagate the error.

**Rollback:** single-commit revert removes both stanzas and the dry-run branch. No state-file schema changes, no Fly config changes, no new secrets. Re-entering the old state is `git revert <sha>` + `fly deploy`.
