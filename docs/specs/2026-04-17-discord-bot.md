---
status: draft
date: 2026-04-17
author: hydra worker (issue #125)
---

# Discord bot: DM-based chat surface for cloud commander (mirror of #74)

Implements: ticket [#125](https://github.com/tonychang04/hydra/issues/125) (T2).

## Problem

Slack bot #74 / PR #79 shipped a single-operator DM + proactive notification surface for Commander. Slack is a natural default for teams and work-adjacent operators; Discord is the natural default for solo, indie, and OSS-leaning operators — it's the #2 most-requested chat surface in the initial operator feedback window. Without a Discord counterpart, phone-friendly commander operation is Slack-only.

The shape is already known (see [`docs/specs/2026-04-17-slack-bot.md`](2026-04-17-slack-bot.md)): single allowlisted user, two hard-wired commands (`status`, `pickup [N]`), one proactive notification trigger (PR gets `commander-review-clean`), refuse-to-start invariants, JSONL audit log with envelope-only hashing, and `PHASE1-FALLBACK` markers for the post-#72 MCP swap. This ticket reuses all of those patterns — the ticket explicitly says "different platform, same shape" — and adds **nothing new** about chat-surface semantics.

The open design question is platform plumbing only: Discord has no socket-mode-equivalent marketing term, but the gateway WebSocket connection is the exact same shape (outbound-only, no public HTTP endpoint). Picking the right Discord SDK matters for maintenance; everything else is verbatim from #74.

## Goals

Identical to [`docs/specs/2026-04-17-slack-bot.md`](2026-04-17-slack-bot.md) with Slack ↔ Discord substitutions. Enumerated for cross-referencing:

- **G1 — Single-operator DM surface.** Bot listens for DMs from exactly one allowlisted Discord user ID (snowflake). No guild channels, no multi-user, no broadcast.
- **G2 — Two commands hard-wired.** `status` (Commander snapshot) and `pickup [N]` (N ∈ [1, 20], default 1). Every other verb is a `NotImplemented` stub with a polite "coming in follow-up" reply.
- **G3 — One proactive notification trigger.** PR picks up the `commander-review-clean` label → bot DMs a one-line notice with PR link + tier.
- **G4 — Refuse-to-start safety.** Missing config, `enabled: false`, or missing token env var → process exits 1 with a clear log line (or 0 on `enabled: false`, matching Slack). Never boot a half-configured bot.
- **G5 — Audit log.** Every inbound DM + every outbound reply + every proactive notification appends one JSON line to `logs/discord-audit.jsonl`. No raw text — hash with SHA-256 and persist the 16-char prefix.
- **G6 — Clean MCP swap point.** Every direct-state read or file-based dispatch is tagged with an inline `# PHASE1-FALLBACK` comment so the post-#72 swap is mechanical. Same marker convention as the Slack bot.

## Non-goals

- **Slash commands** (`/hydra-status` at the guild level). DM text parsing only. Out of scope per the ticket body.
- **Role-based ACLs.** Single operator snowflake allowlist only.
- **Multi-server broadcast.** Bot doesn't need to be installed to a guild at all for DM-only operation. Out of scope.
- **Rich embeds / buttons / slash command UI.** Plain text replies (Discord Markdown subset is fine — bold with `**`, inline code with backticks).
- **Other chat platforms.** Slack lives in #74. SMS / Teams / Matrix are each their own ticket.
- **Editing `bin/hydra-slack-bot` or `state/connectors/slack.json.example`.** Explicit scope constraint: reuse patterns, don't refactor. If a factored-out shared module would make sense later, that's a follow-up (see "Implementation notes" below).
- **Editing `CLAUDE.md` or `infra/entrypoint.sh`.** Explicit scope constraint. Follow-up integration checklist at the bottom.
- **Webhook-driven notifications.** Phase 1 polls `commander-review-clean` PRs every 60s. Webhook-driven is a follow-up (issue [#40](https://github.com/tonychang04/hydra/issues/40)).

## Proposed approach

### Library: `discord.py` (gateway client)

`discord.py` is the long-standing, API-stable Python SDK for Discord. Version 2.x supports Python 3.8+, has full gateway / intents support, and is MIT-licensed. `py-cord` exists as an active fork but splits the ecosystem — `discord.py` is the more conservative choice for a single-purpose launcher that only needs DMs. Alternatives considered below.

The gateway client opens an outbound WebSocket to Discord — the same outbound-only posture as Slack's socket mode. No public HTTP endpoint, no URL to register, no firewall hole. This matches the Fly `auto_stop = suspend` pattern.

One env-var token is required:

- `bot_token_env` → Discord bot token from the [Discord Developer Portal](https://discord.com/developers/applications). Tokens are a single string (not OAuth + app-level, unlike Slack); that's why the config has one `_env` pointer instead of two.

The token is loaded at startup via the env-var-name pointer in `state/connectors/discord.json` — never inlined in the config file.

### Required gateway intents

Discord gates certain events behind declared intents. For DM-only operation, the bot needs:

- `Intents.direct_messages` — fires `on_message` for DMs
- `Intents.message_content` — required to read the `content` field of DM messages (Discord's 2022 privileged-intents change)

The `message_content` intent is **privileged** and must be enabled in the Discord Developer Portal's Bot tab before Discord will deliver message bodies. The runbook documents this as Step 1.4.

### Config: `state/connectors/discord.json.example`

```jsonc
{
  "_description": "Copy to state/connectors/discord.json and fill in. Controls the Hydra Discord bot (bin/hydra-discord-bot). Single-operator DM bridge; mirrors the Slack bot shape from ticket #74. state/connectors/*.json (except *.example.json) is gitignored.",
  "_canonical_term": "discord bot",
  "_related_docs": [
    "docs/specs/2026-04-17-discord-bot.md",
    "docs/specs/2026-04-17-slack-bot.md",
    "docs/phase2-vps-runbook.md"
  ],
  "enabled": false,
  "_enabled_note": "Set to true to let bin/hydra-discord-bot start. Default false so a missing/incomplete config is inert — bot exits 0 with a clear log line if this is false.",
  "bot_token_env": "HYDRA_DISCORD_BOT_TOKEN",
  "_bot_token_env_note": "Name of the env var holding the Discord bot token from the Discord Developer Portal. Do NOT paste the token into this file. On Fly: `fly secrets set HYDRA_DISCORD_BOT_TOKEN=...`.",
  "allowed_user_id": "000000000000000000",
  "_allowed_user_id_note": "Exactly ONE Discord user ID (snowflake — 17-20 digit integer). NOT the username#tag, NOT the display name. Enable Developer Mode in Discord (Settings → Advanced → Developer Mode), then right-click your own name → Copy User ID. DMs from any other user are silently ignored and audit-logged as refused-unauthorized-user.",
  "default_channel": "000000000000000000",
  "_default_channel_note": "Fallback channel ID — usually the DM channel ID between allowed_user_id and the bot — used if direct user DM fails (user blocked the bot, etc.). Find by right-clicking the DM in Discord's sidebar → Copy Channel ID (Developer Mode required).",
  "notification_poll_interval_sec": 60,
  "_notification_poll_interval_sec_note": "How often to poll for newly-labeled commander-review-clean PRs. Default 60s. Minimum enforced in code is 30s (tighter hits GitHub rate limits).",
  "repos": [
    "tonychang04/hydra"
  ],
  "_repos_note": "Which repos to poll for the commander-review-clean label. Phase 1: must be listed explicitly (mirrors Slack bot Phase 1 behavior). Phase 2 (after #72 lands): bot becomes an MCP client and pulls this list from Commander.",
  "seen_prs_state_path": "state/discord-notified-prs.json",
  "_seen_prs_state_path_note": "Where to persist the set of PR IDs the bot has already notified about. Persisting means a bot restart doesn't re-notify. File is capped at 500 entries via LRU eviction."
}
```

**Why `_env` suffix convention:** matches `slack.json.example`, `mcp.json.example:upstream_supervisor.auth_token_env`. Consistent with how Commander already handles secrets — the config names an env var, the operator sets the env var, the config file stays safe to commit into a password manager / backup.

**Why `allowed_user_id` is a string, not an integer:** Discord snowflakes are 64-bit integers that exceed JavaScript's `Number.MAX_SAFE_INTEGER` and are conventionally stored as strings across Discord's own API. Following their convention keeps copy-paste from the Discord client round-tripping without precision loss. At runtime the bot compares as strings too.

### Launcher: `bin/hydra-discord-bot`

Single Python script, ~300 LOC, mirroring `bin/hydra-slack-bot`. Responsibilities (verbatim from #74 with Discord plumbing):

1. **Startup refusal loop.** Read `state/connectors/discord.json`. Refuse to start if:
   - File is missing (exit 1, log: "config not found at state/connectors/discord.json")
   - `enabled: false` (exit 0, log: "discord bot disabled in config; exiting cleanly")
   - Required env var (named by `bot_token_env`) is unset (exit 1, log: "env var $NAME unset")
   - `allowed_user_id` is not a numeric snowflake string (exit 1, log: "allowed_user_id must be a numeric Discord snowflake; got <value>")
   - `repos` is not a list of `owner/name` strings (exit 1)
2. **Message handler (inbound).** Register an `on_message` listener gated on `message.channel.type == discord.ChannelType.private` (i.e. DMs) AND `str(message.author.id) == allowed_user_id`. If no, log one audit line (`action: refused-unauthorized-user`) and silently return. If yes, parse first token as command:
   - `status` → Commander snapshot (same implementation as Slack handler)
   - `pickup` or `pickup N` → queue a dispatch request (same implementation as Slack)
   - `merge`, `reject`, `retry`, `pause`, `resume`, `kill` → polite "coming in follow-up" reply, log `action: not-implemented`
   - Anything else → "unrecognized command. supported today: `status`, `pickup [N]`"
3. **Notification loop (outbound).** Background thread, polls every `notification_poll_interval_sec`. For each repo in config, runs `gh pr list --repo <repo> --label commander-review-clean --state open --json number,title,labels,url`. For each PR not seen before (tracked in `state/discord-notified-prs.json`), DM the operator and append to the seen-set. Persisted, LRU-bounded at 500 — same pattern as Slack's `SeenPRsCache`.
4. **Audit logging.** Every DM-in, DM-out, proactive notification appends one JSON line to `logs/discord-audit.jsonl` — `{ts, direction, user_id, text_sha256, action, worker_ids?}`. SHA-256 prefix identical to Slack.
5. **Graceful shutdown.** `SIGTERM` / `SIGINT` closes the gateway connection, flushes the audit log, exits 0. `discord.Client.close()` is an awaitable that drains the WebSocket cleanly — important because ungraceful shutdown triggers Discord's resume-session logic and can cause duplicate event delivery.

### Sharing vs. duplicating with `bin/hydra-slack-bot`

The ticket explicitly says **do not refactor Slack**. Two structural choices:

1. **Copy the core handlers and Commander-state helpers verbatim into `bin/hydra-discord-bot`.** Each script stays self-contained; a future refactor can extract shared code into `scripts/hydra-chat-core.py` once both bots are stable and a third surface (SMS / Teams) is on the roadmap.
2. **Import helpers from `bin/hydra-slack-bot` by file path.** Rejected: Slack bot isn't importable as a module (no `.py` extension, so `importlib.util.spec_from_file_location` returns a `None` loader — see `memory/learnings-hydra.md` entry from #74). Working around this requires the `SourceFileLoader` dance, which would make the Discord bot's imports load and execute the Slack bot's top-level code (including `slack-bolt`), defeating the refuse-to-start invariant and creating an import-time dependency on `slack-bolt` even for Discord-only operators.

Choice: **(1) duplicate deliberately.** The shared code is ~80 LOC of pure-functions (`_utcnow_iso`, `_sha256_prefix`, `load_config` sans platform validation, `_read_json`, `get_commander_status`, `request_pickup`, `SeenPRsCache`, `poll_review_clean_prs`, `parse_command`, audit logger). Copying is explicit and reviewable; a future "pull out a shared module" ticket owns the refactor decision.

To keep drift detectable, the self-test for `bin/hydra-discord-bot` asserts the same PHASE1-FALLBACK count + the same audit-log field shape as the Slack self-test. If either drifts, we'll see it on the next self-test run.

### PHASE1-FALLBACK pattern

Exactly as in #74. Every direct state read or file-based dispatch (`state/active.json`, `state/budget-used.json`, `state/autopickup.json`, `state/pending-dispatches.json`, `commander/PAUSE`) gets an inline `# PHASE1-FALLBACK: swap to mcp_client.call('hydra.<tool>') after #72 lands` comment. The self-test asserts ≥3 such markers are present so a careless refactor can't silently remove them.

### Audit log shape

`logs/discord-audit.jsonl` — same shape as `slack-audit.jsonl`:

```jsonc
// inbound DM
{"ts": "2026-04-17T10:00:00Z", "direction": "in", "user_id": "12345...", "text_sha256": "abc123...", "action": "command-status", "parsed_cmd": "status"}

// outbound reply
{"ts": "2026-04-17T10:00:01Z", "direction": "out", "user_id": "12345...", "text_sha256": "def456...", "action": "reply-status"}

// unauthorized
{"ts": "2026-04-17T10:00:02Z", "direction": "in", "user_id": "99999...", "text_sha256": "...", "action": "refused-unauthorized-user"}

// proactive notification
{"ts": "2026-04-17T10:01:00Z", "direction": "out", "user_id": "12345...", "text_sha256": "...", "action": "notify-review-clean", "pr_num": 501, "repo": "owner/repo"}
```

Never log `text` itself — DMs can contain tokens, PR bodies can contain customer data.

### Alternatives considered

- **`py-cord` instead of `discord.py`.** Rejected. `py-cord` is an active fork, but `discord.py` is the longest-lived, most-documented, and is explicitly maintained (it returned from hiatus in 2022). For a minimal launcher that only needs `on_message` + `DMChannel.send`, the library stability matters more than slash-command ergonomics (which we don't use).
- **`hikari` (async-native Discord library).** Rejected. Smaller community, fewer operator-facing resources. `discord.py` is what most runbooks assume.
- **Bun + `discord.js`.** Rejected. The ticket says "python or bun — pick whichever is cleaner". Python is already in the runtime (Slack bot, `scripts/*.py`, `requirements.txt`) — adding bun as a second runtime for one more chat bot doubles the infrastructure surface (package manager, lockfile, runtime install) with no benefit. Stay with Python for operational consistency.
- **Discord Interactions HTTP endpoint (webhook-based).** Rejected. Discord's interactions endpoint needs a public HTTPS URL with request-signature verification. Conflicts with Fly's `auto_stop = suspend` pattern. Gateway WebSocket is the equivalent of Slack socket mode.
- **Register the bot as an MCP client eagerly (before #72 lands).** Rejected. Same reason as #74 — Phase-gate with `PHASE1-FALLBACK` is cleaner.
- **Share handlers with the Slack bot via a shared Python module.** Rejected in Phase 1 — explicit ticket scope constraint. Noted as a follow-up in the implementation checklist below.

## Test plan

- **Self-test: `discord-config-example-valid` (kind: script).** jq-validates `state/connectors/discord.json.example` exposes every field `bin/hydra-discord-bot` reads at startup: `enabled`, `bot_token_env`, `allowed_user_id` (numeric snowflake string), `default_channel` (numeric snowflake string), `notification_poll_interval_sec` (≥30), `repos` (non-empty `owner/name` array), `seen_prs_state_path`. Also smoke-tests the launcher's refuse-to-start paths: missing config → exit 1; `enabled: false` → exit 0 with clean log; missing env-var token → exit 1. Parses the script as valid Python (`ast.parse`). Counts `PHASE1-FALLBACK` markers (≥3). Same shape as `slack-config-example-valid` in `self-test/golden-cases.example.json`. No live Discord API test — that would need a real dev application + bot invite.
- **Manual smoke test (documented in runbook).** Create a Discord dev application + bot, enable Message Content intent, invite to a personal guild (or use DM-only), set `enabled: true` + real token in env, run `./bin/hydra-discord-bot` locally, DM it `status`, verify response.
- **Negative-path manual tests.** Same local setup: (a) wrong user ID DMs the bot → bot silently ignores + logs `refused-unauthorized-user`; (b) unset `HYDRA_DISCORD_BOT_TOKEN` → bot exits 1 with clear log line; (c) `enabled: false` in config → bot exits 0 with clear log line.
- **Notification loop unit smoke.** Run the polling thread against a fake `gh pr list` output (mock via `PATH` shim or a fixture) once, verify it produces one DM per unseen PR, verify the seen-set persists across restart.

The self-test is what CI gates on. The manual smoke + negative-path checks are what the merging operator runs before flipping `enabled: true` in production config.

## Risks / rollback

- **Credential exposure in audit logs.** Mitigated by never logging raw text — only SHA-256 prefixes. If this contract is ever relaxed, the `_description` block in `discord.json.example` calls it out. Same guarantee as Slack.
- **Discord API outage silently disables notifications.** Bot keeps running but stops delivering. Mitigation: every poll-loop iteration emits a heartbeat log line; if the operator sees no heartbeat for N minutes in `fly logs`, they know.
- **Duplicate notifications on bot restart.** Mitigated by `state/discord-notified-prs.json` persisting the seen-set. Bounded at 500 entries (LRU) so the file stays small.
- **Rate limiting from polling too aggressively.** Mitigated: `notification_poll_interval_sec` has a 30s floor enforced in code, and `gh pr list --label commander-review-clean` is O(repos), not O(PRs).
- **Bot becomes the accidental merge path.** Mitigated by deliberate `NotImplemented` stubs for `merge` / `reject` / `retry`. Follow-up tickets have to go through the commander review gate + MCP scope check.
- **Discord privileged-intent regression.** If the Message Content intent is not enabled in the Developer Portal, DMs arrive with empty `content`. Mitigated by the runbook explicitly calling it out (Step 1.4) and the bot logging a `WARNING` on every empty-content DM from the allowlisted user. First-deploy failure mode, not a runtime one.
- **Drift from Slack bot patterns.** Phase 1 has two duplicated launchers. Mitigated by a post-landing follow-up ticket to extract `scripts/hydra-chat-core.py` once both bots ship and a third surface is on the roadmap.
- **Rollback.** Flip `enabled: false` in `state/connectors/discord.json` → bot exits cleanly on next restart. No schema migration, no state cleanup. To fully remove: delete the config file, `logs/discord-audit.jsonl`, and `state/discord-notified-prs.json`.

## Implementation notes

### Post-landing integration checklist

The following follow-ups are intentionally deferred out of this PR:

1. **`infra/entrypoint.sh`** — add a stanza mirroring the Slack one:
   ```bash
   if [ -f state/connectors/discord.json ] && [ "$(jq -r .enabled state/connectors/discord.json 2>/dev/null)" = "true" ]; then
     ./bin/hydra-discord-bot &
   fi
   ```
   File into a separate ticket after #72 lands; the Slack follow-up hasn't merged yet either.
2. **`infra/Dockerfile`** — add `discord.py>=2.3,<3` via `requirements.txt` (done in this PR) and ensure `pip install -r requirements.txt` is part of the image build. Current Dockerfile already does this for the Slack bot, so no Dockerfile change is needed.
3. **`CLAUDE.md`** — intentionally not edited. Once the code is proven in production for ~1 week, a follow-up PR can add a one-line "Discord bot" reference to match whatever the Slack bot gets.
4. **Commander MCP swap (#72 follow-up).** Every `# PHASE1-FALLBACK` comment becomes one MCP call. File a follow-up issue ("discord bot: migrate fallbacks to MCP") at the time this PR opens, mirroring the Slack MCP-swap follow-up.
5. **Shared chat core** (optional). Once both Slack and Discord bots have been running stably for ~1 month, a follow-up ticket can extract a `scripts/hydra-chat-core.py` module with `_utcnow_iso`, `_sha256_prefix`, `_read_json`, `get_commander_status`, `request_pickup`, `SeenPRsCache`, `poll_review_clean_prs`. Leaving this for later so the two launchers can evolve independently while the patterns are still new.

### Why this ships identically-shaped to Slack

The ticket's tightest constraint is "mirror of #74, different platform". Deliberately copying 80 LOC of helper code is cheaper than introducing a cross-launcher shared module before the second launcher has landed once — that's classic YAGNI on the abstraction. If a third launcher (SMS / Teams / Matrix) ever files as a ticket, the first order of business for that worker is to land the shared module.

### Why the runbook section is adjacent to the Slack section

`docs/phase2-vps-runbook.md` already has "Setting up Slack" at line 718. The new "Setting up Discord" section goes immediately after it (before "Configuring the Codex backend" at line 845). Both are operator-facing onboarding flows for alternate chat surfaces; keeping them contiguous lets the operator comparison-shop at skim.
