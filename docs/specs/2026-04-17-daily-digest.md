---
status: approved
date: 2026-04-17
author: hydra commander
ticket: 144
---

# Daily Status Digest — 1-paragraph push to operator's channel of choice

## Problem

Operator has to **pull** status (`./hydra status`, grep logs) to find out what
the machine did. For a run-while-the-operator-sleeps tool, this inverts the
autonomy principle: the human is still the driver of observability.

Hydra should **push** a compact digest — one paragraph, once a day, over
whatever channel the operator wired — so the operator wakes up, reads one
paragraph on their phone, and knows the state of the machine without opening
a terminal.

P1 (observability) is the weakest pillar today; this ticket moves the needle.

## Goals

- `./hydra connect digest <channel>` subscribes a channel. Channels:
  `stdout`, `slack`, `webhook`, `email`. Default `stdout`.
- `stdout` channel writes the paragraph to `memory/digests/YYYY-MM-DD.md`
  (one file per day, overwrite on re-run). Operators without slack/webhook
  set up still get a daily archive.
- Commander emits a daily rollup at a configured time (default `09:00`
  local). Single operator, single local clock — same semantic as the Monday
  retro check in `docs/specs/2026-04-17-scheduled-retro.md`.
- Paragraph is ≤500 chars. Over-cap = truncate + append `… full: ./hydra status`.
- Schema at `state/schemas/digests.schema.json`, idempotency field
  `last_digest_run` on `state/digests.json` (mirrors the `last_retro_run`
  pattern on `state/autopickup.json`).
- Spec here; CLAUDE.md gets **one line** pointer only (bloat rule).

## Non-goals

- **Not** a real SMTP / Slack send. `slack` / `webhook` / `email` channels
  write the payload to `logs/digest-out.jsonl` and rely on the existing
  Slack bot (`bin/hydra-slack-bot`) / webhook receiver
  (`scripts/hydra-webhook-receiver.py`) / operator's own cron to do the
  transport. Phase 1 ships the **composer + scheduler + channel routing
  surface**; channel transport (actual HTTP POST, SMTP) is a follow-up ticket.
- **Not** multi-channel. One channel per install. Operator who wants both
  slack and email runs `connect digest` twice — most recent write wins.
- **Not** a fancy template engine. The paragraph shape is hardcoded in
  `scripts/build-daily-digest.sh`. Operator who wants a different shape
  edits the script; a config flag is a follow-up.
- **Not** a rich history browser. The `memory/digests/` directory is the
  archive; operator greps it.
- **Not** new cron infrastructure. Rides the existing `/loop`-driven
  autopickup tick, same as scheduled retro.

## Proposed approach

### Components

1. **`scripts/build-daily-digest.sh`** — Pure composer. Reads
   `logs/*.json` (last 24h), `state/active.json`,
   `state/budget-used.json`, `state/autopickup.json`,
   `memory/retros/*.md` (most recent). Emits the paragraph to stdout.
   Output capped at 500 chars; over-cap truncates + appends the full-status
   pointer.

2. **`scripts/hydra-connect.sh` → `connect_digest`** — New sub-function
   in the existing connector wizard. Prompts for:
   - `enabled` (bool, default false)
   - `channel` (`stdout` | `slack` | `webhook` | `email`, default `stdout`)
   - `time` (HH:MM local, default `09:00`; validated against `^[0-2][0-9]:[0-5][0-9]$`)
   - `destination` — channel-specific:
     - `stdout` → path prefix, default `memory/digests/`
     - `slack` → channel ID (reuses `state/connectors/slack.json:default_channel` if not overridden)
     - `webhook` → URL env-var name (tokens never in-file)
     - `email` → address
   Writes `state/digests.json` atomically after schema validation.
   Re-run is idempotent (existing values become prompt defaults).
   Adds `digest` row to `--list` and `--status` tables.

3. **`state/digests.json`** (gitignored, `.example` committed). Schema at
   `state/schemas/digests.schema.json`.

4. **`state/schemas/digests.schema.json`** — Draft-07. Required fields:
   `enabled`, `channel`, `time`, `destination`, `last_digest_run`.
   `additionalProperties: true` (forward compat).

5. **Autopickup tick integration** — CLAUDE.md "Scheduled autopickup →
   Tick procedure" gets a **step 1.6** pointer line (one sentence) that
   says: after the Monday retro check, if `state/digests.json:enabled ==
   true` and `now_local >= time` on a day `last_digest_run` hasn't
   covered, run `scripts/build-daily-digest.sh`, route via the configured
   channel, set `last_digest_run`. Idempotency reuses the same lexical
   ISO-8601 comparison pattern used for retros.

6. **Launcher wiring** — `./hydra connect digest` already works the
   moment `hydra-connect.sh` recognizes the subcommand; setup.sh
   launcher help-text gets a one-line mention. `./hydra connect --list`
   and `./hydra connect --status` learn about the new connector via
   its sub-function.

### Channel routing (Phase 1)

Each channel writes to a deterministic, testable sink. Actual transport
is a follow-up because:
- Slack transport requires the Slack bot to be running; wiring this in
  would couple two specs.
- Webhook / email need secrets; Phase 1 should not own secret handling.

| Channel  | Phase 1 sink                             | Phase 2 transport                    |
|----------|------------------------------------------|--------------------------------------|
| stdout   | `memory/digests/YYYY-MM-DD.md` + stdout  | (none — already final)               |
| slack    | `logs/digest-out.jsonl` + stdout         | Slack bot reads, posts to channel    |
| webhook  | `logs/digest-out.jsonl` + stdout         | Separate cron POSTs to URL           |
| email    | `logs/digest-out.jsonl` + stdout         | Separate cron SMTPs                  |

`logs/digest-out.jsonl` entries have shape
`{ts, channel, destination, paragraph, char_count}` — one line per emit.
Follow-up tickets consume this file for real transport.

### Paragraph shape

```
Overnight: shipped <N> PRs (<auto> auto-merged, <pending> pending your review → <refs>),
<stuck_count> worker(s) stuck on <refs>, autopickup picked <picked> tickets,
<rl_hits> rate-limit hit(s). Retro <retro_status>. Full: ./hydra status.
```

Where:
- `shipped` = completed logs in last 24h with `result in ("merged","pr_opened")`
- `auto_merged` = `result == "merged"`
- `pending` = `result == "pr_opened"`
- `stuck_count` = active.json workers with `status in ("paused-on-question","failed")`
- `picked` = sum of `last_picked_count` over last 24h of autopickup ticks (best-effort: current value)
- `rl_hits` = `autopickup.json:consecutive_rate_limit_hits` snapshot
- `retro_status` = `queued for Monday` / `written <date>` based on
  most recent `memory/retros/*.md` mtime

If any source file is missing → that number is `0` / that clause is omitted.
If the final paragraph exceeds 500 chars, we truncate at the nearest word
boundary ≤ 490 and append ` … full: ./hydra status`.

### Alternatives considered

- **A: New `scripts/hydra-digest.sh` runner instead of folding into
  `hydra-connect.sh`.** Cleaner separation but doubles the CLI surface
  the operator needs to learn. The connector wizard is already the
  single entry point for "wire a channel"; folding in matches that
  pattern. Rejected.
- **B: Separate scheduler from autopickup tick.** More robust if
  autopickup is paused. Rejected — one scheduler pattern per Phase 1
  (see retro spec). When autopickup is off, the digest is off; the
  operator who's paused the machine probably doesn't need a digest.
- **C: In-Slack-bot compose, no separate script.** Tight coupling
  between Slack and the digest composer. Rejected — stdout channel must
  work with zero external connectors.
- **D (picked):** Standalone composer script + wizard integration +
  tick-driven trigger + channel-sink JSONL for transport fan-out.

## Test plan

1. **Fixture: composer with full log set.**
   `self-test/fixtures/daily-digest/` holds N log files mimicking a full
   24h. Running `build-daily-digest.sh --logs-dir … --state-dir …`
   emits a paragraph matching a regex (`^Overnight: shipped \d+ PRs.*Full: ./hydra status`)
   and whose char count ≤ 500.
2. **Fixture: truncation path.**
   Log set produces an over-cap paragraph; composer truncates and
   appends the pointer. Result matches `\.\.\. full: \./hydra status$`
   and ≤ 500 chars.
3. **Fixture: everything zero.**
   Empty logs/, empty state/. Composer emits a minimal-but-valid
   paragraph (`Overnight: quiet. Full: ./hydra status`) — no crash, no
   divide-by-zero, `jq` tolerates missing files.
4. **Wizard: schema validation on write.**
   `HYDRA_CONNECT_DIGEST_FILE=/tmp/x.json ./hydra connect digest
   --non-interactive --dry-run` passes schema validation. Corrupting
   the schema validator (by injecting an invalid `time` value) makes
   the wizard refuse to write.
5. **Wizard: `--list` and `--status` include the digest row.**
   Smoke test asserts each table now has a `digest` line.
6. **Schema round-trip.**
   `scripts/validate-state.sh --schema
   state/schemas/digests.schema.json state/digests.example.json` exits 0.
7. **Tick idempotency (manual).**
   Run composer → write `last_digest_run = today T09:00`. Second run on
   same day → tick-side check would no-op. Covered by the
   documented step-1.6 in CLAUDE.md; runtime behavior is parallel to
   scheduled retro (whose idempotency test is the reference).

## Risks / rollback

- **Risk:** Composer reads sensitive log payloads and surfaces them in
  the paragraph. **Mitigation:** composer reads only scalar counts and
  PR refs; never `surprises`, `logs`, or raw QUESTION bodies. Char cap
  limits blast radius.
- **Risk:** Tick runs composer every tick instead of once per day.
  **Mitigation:** idempotency via `last_digest_run` — same pattern
  as retro.
- **Risk:** Slack / webhook / email channel silently drops paragraphs
  because Phase 1 only writes to JSONL. **Mitigation:** `./hydra
  connect --status` surfaces "digest enabled (channel=slack, transport
  is JSONL-only in Phase 1; see spec)" so the operator knows.
- **Rollback:** set `state/digests.json:enabled = false`. Tick check
  no-ops. Memory files already written stay in `memory/digests/`;
  harmless. Removing the step 1.6 line from CLAUDE.md reverts the
  scheduler.

## Implementation notes

Lands in the PR closing #144. Files touched:

- `scripts/build-daily-digest.sh` — new. Bash + jq. Honors
  `--logs-dir`, `--state-dir`, `--memory-dir` overrides for tests.
- `scripts/hydra-connect.sh` — new `connect_digest` sub-function;
  `--list` / `--status` tables extended; dispatch case extended.
  Honors `HYDRA_CONNECT_DIGEST_FILE` for tests.
- `state/digests.example.json` — committed template; `state/digests.json` gitignored.
- `state/schemas/digests.schema.json` — new.
- `.gitignore` — `state/digests.json`, `logs/digest-out.jsonl`,
  `memory/digests/` runtime artifacts.
- `CLAUDE.md` — **one-line** addition in the Scheduled autopickup
  paragraph, noting the digest step-1.6. No inline procedure.
- `setup.sh` — launcher help-text gains one line for `connect digest`.
- `self-test/fixtures/daily-digest/` — composer smoke fixtures (full, truncation, zero).

MEMORY_CITED reuses: connector wizard pattern
(`learnings-hydra.md`#connector-wizard-atomic-write-pattern), `/loop`
tick pattern (spec pointer), retro idempotency (spec pointer).
