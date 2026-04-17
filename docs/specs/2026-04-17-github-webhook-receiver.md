---
status: draft
date: 2026-04-17
author: hydra worker (ticket #41)
---

# GitHub webhook receiver (Phase 1 — issue-assigned trigger only)

## Problem

Autopickup polls `gh issue list --assignee @me` every 30 min (see CLAUDE.md "Scheduled autopickup"). Worst-case a ticket assigned at 09:01 doesn't get picked up until 09:30. That 30-min ceiling is the difference between "Commander reacts while the operator is still looking at the screen" and "Commander catches up on the next coffee break."

Polling also wastes quota — every tick wakes Commander even when nothing changed, counts against the GitHub rate limit, and (on Fly with `auto_stop_machines = "suspend"`) unnecessarily spins the machine back up on empty ticks.

Ticket [#41](https://github.com/tonychang04/hydra/issues/41) is the Phase 1 slice of webhook-based triggering. The full ticket approach (issues + PR closed + Linear parity + CLI wizard) is too broad for one PR; this spec narrows to the smallest useful wedge: `issues.assigned` only, validated HMAC, sentinel file drop that autopickup's preflight already knows how to short-circuit on.

## Goals / non-goals

**Goals:**

1. `scripts/hydra-webhook-receiver.py` — Python stdlib HTTP server (same pattern as `scripts/hydra-mcp-server.py` from ticket #72). Listens on `/webhook/github`, validates `X-Hub-Signature-256` HMAC with constant-time compare, filters for `issues` event with `assigned` action.
2. On a valid matching event: drops a sentinel file at `state/webhook-triggers/<ts>-<repo>-<issue>.json` containing a minimal envelope (`{ts, repo, issue_num, event, action, assignee}`). **No** issue body content is persisted (security: #41 explicitly calls this out).
3. `infra/fly.toml` adds a dedicated `[[services]]` stanza routing port 443 → internal 8766 (the webhook receiver), alongside the existing `/health` on 8080 and `/mcp` on 8765. Fly only permits one `[http_service]` per config; the webhook block uses the same `[[services]]` primitive that MCP uses for the same reason.
4. `docs/phase2-vps-runbook.md` gains a "Wiring GitHub webhooks" section: generate secret, register webhook on GitHub, `fly secrets set HYDRA_WEBHOOK_SECRET_<REPO>=...`, verify handshake.
5. Self-test: `webhook-receiver-hmac` (script-kind) — spins the receiver on a free port, sends a signed request, sends an unsigned request, asserts sentinel shape + 401 on bad signature.

Commander's autopickup tick changes — `state/webhook-triggers/` detection to short-circuit the timer — are **out of scope** for this PR and documented in the spec's Non-goals. The sentinel format is designed so the follow-up wiring is a pure read-side addition.

**Non-goals (explicit):**

- PR events, comment events, label events, or any non-`issues.assigned` payload. (Ticket #41 core scope: "Phase 1 is assignment-only.")
- Linear webhooks. (Tracked separately — see CLAUDE.md's Linear MCP path.)
- Replacing the autopickup polling loop. Polling stays as the fallback for missed deliveries (network blip, secret rotation window, etc.). Webhooks are **additive**, not a replacement.
- Queue durability beyond the sentinel file. A dropped sentinel file on disk is good enough for Phase 1. Phase 2 may revisit with SQS / Redis if operators hit delivery-loss incidents.
- Rate limiting on the webhook endpoint. Ticket mentions "100 req/min per IP" under Security notes; Phase 1 relies on the `Content-Length` cap + HMAC rejection as the first line of defense. Explicit rate limiting is a follow-up.
- Launch wiring in `infra/entrypoint.sh`. The ticket explicitly calls out: "Don't touch entrypoint.sh (separate ticket can wire the receiver launch)." This PR ships the daemon + config; the launch integration is its own review surface.
- `./hydra setup-webhook <repo>` CLI wizard. Out of scope for this PR; the runbook documents the manual `gh api` + `fly secrets set` flow.
- Per-IP rate limiting / 429 backoff. First line of defense is HMAC rejection + 64KB body cap.

## Proposed approach

### Receiver (`scripts/hydra-webhook-receiver.py`)

Same skeleton as `scripts/hydra-mcp-server.py`:

- `http.server.BaseHTTPRequestHandler` subclass, threaded, loopback-default bind.
- Single route: `POST /webhook/github`. Everything else → 404.
- `GET /webhook/github` → 405 (GitHub never sends GET). `GET /` → 200 "hydra-webhook-receiver: POST /webhook/github".
- Body size cap: 1 MiB (GitHub issue payloads max out around 100 KiB but we leave headroom for label-heavy repos; MCP's 64 KiB is too tight here).
- Auth: HMAC-SHA256 of raw body against `X-Hub-Signature-256: sha256=<hex>`. Secret read from env var `HYDRA_WEBHOOK_SECRET` (single secret, not per-repo in Phase 1 — simpler; per-repo override in a follow-up). `hmac.compare_digest()` for constant-time compare — no timing oracle.
- Event filter: the `X-GitHub-Event` header MUST equal `"issues"` AND the parsed body's `action` MUST equal `"assigned"`. Anything else → 204 No Content (not 400; GitHub's delivery UI treats 2xx as acknowledged). This keeps the receiver forgiving on event types GitHub adds later and avoids "delivery failed" noise in the webhook history UI.
- Sentinel drop: on a matching event, `state/webhook-triggers/<ISO8601>-<owner>-<repo>-<issue_num>.json` with `{ts, repo: "owner/name", issue_num, event, action, assignee: {login}, source: "github-webhook"}`. Directory auto-created. File perms 0o600 (matches the MCP audit log precedent).
- Logging: single stderr line per request with method + path + event + action + result (200/401/204). **Never log** the request body — it contains issue body text which may be proprietary (ticket #41 Security notes).
- CLI: `hydra-webhook-receiver.py --port 8766 [--bind 127.0.0.1] [--check]`. `--check` validates config (env var present) and exits 0 without binding — useful for CI.

### fly.toml stanza

New `[[services]]` block, port 443 → internal_port 8766, TLS termination at Fly's edge. Mirrors the MCP `[[services]]` shape exactly — no new Fly primitives. Plaintext :8766 is **not** exposed to the public internet (HMAC travels in cleartext-able header, but GitHub supplies it over TLS; we enforce that by only opening the TLS handler).

### Runbook section

Step-by-step in `docs/phase2-vps-runbook.md`:

1. Generate a 32-byte secret: `openssl rand -hex 32`.
2. `fly secrets set HYDRA_WEBHOOK_SECRET=... --app <app>`.
3. Register the webhook via `gh api` (one command, copy-paste-ready with placeholders for owner/repo/URL).
4. Verify with GitHub's "Recent Deliveries" UI or a local `curl` smoke-test.
5. Troubleshooting table for the three common failure modes: 401 (signature mismatch), 204 on every delivery (wrong event type), sentinel not appearing (volume not mounted).

### Self-test

`self-test/fixtures/webhook-receiver/run.sh` follows the exact shape of `self-test/fixtures/mcp-server/run.sh`:

1. Pick a random free port.
2. Write a fixture secret into env.
3. Start the receiver in the background.
4. Craft a signed request body (Python one-liner for HMAC), POST it, assert 200 + sentinel file appears.
5. POST the same body with a bad signature, assert 401.
6. POST an `issues` event with `action: "opened"` (not assigned), assert 204 + NO sentinel written (filter correctness).
7. POST a non-`issues` event (e.g. `"pull_request"`), assert 204 + NO sentinel.
8. Cleanup: kill server, rm tmpdir. Print PASS.

Golden case `webhook-receiver-hmac` in `self-test/golden-cases.example.json` — kind `script`, mirrors `mcp-server-starts`.

### Alternatives considered

- **Alternative A: webhook receiver runs inside the existing MCP server process.** Tempting (one Python process, one port). Rejected because it conflates two different authn models (bearer token vs HMAC), two different body-size budgets (64 KiB vs 1 MiB), and two different logging policies (audit-every-call vs never-log-body). Separate processes = separate blast radiuses if either is misused.

- **Alternative B: durable queue (SQS / Redis / SQLite WAL) instead of sentinel files.** Rejected for Phase 1. A file on disk under `/hydra/data/state/webhook-triggers/` already survives restarts (persistent volume), is trivially inspectable with `ls`, and the operator can debug a stuck delivery by reading the JSON. Queue durability becomes interesting only once we see real delivery-loss incidents — YAGNI for now.

- **Alternative C: per-repo webhook secrets in `state/webhooks.json`.** The ticket body sketches this. Rejected for Phase 1 to keep the first iteration small: one `HYDRA_WEBHOOK_SECRET` env var, one operator rotation step. A follow-up can add per-repo secrets (and the `./hydra setup-webhook` wizard) once the base path is merged and exercised.

- **Alternative D: webhook → autopickup tick (no sentinel file, in-memory trigger).** Would require the receiver and Commander to share a process (or an IPC). The sentinel-file design lets Commander be a completely separate process that just polls a directory; the webhook receiver has no dependency on Commander being alive at the moment of delivery. Good fit for Fly's auto-stop / auto-start lifecycle.

## Test plan

1. **`webhook-receiver-hmac` golden case** — the runtime verification. Passes locally + in CI. Would have failed before this PR (receiver doesn't exist); passes after.
2. **`python3 -c 'import ast; ast.parse(open("scripts/hydra-webhook-receiver.py").read())'`** — syntax gate, runs in the `syntax` CI workflow.
3. **`self-test/run.sh --case webhook-receiver-hmac`** — end-to-end: server boots, HMAC good/bad, filter good/bad, sentinel shape valid JSON matching the documented envelope.
4. **Manual smoke** (documented in runbook): `curl -X POST` a signed fixture payload against a locally-running receiver, see the sentinel file appear at `state/webhook-triggers/`.
5. **Spec-presence CI gate** (`.github/workflows/spec-presence-check.sh`) — this spec file satisfies the gate for PRs touching `scripts/hydra-webhook-receiver.py`.

## Risks / rollback

**Risks:**

- **Secret misconfigured → every delivery 401s.** Mitigated by the runbook's "Troubleshooting" section and by surfacing 401s distinctly in stderr (clear log line). Operator sees them in `fly logs`.
- **Fly routing misconfigured → GitHub sees every delivery as failed.** Mitigated by the runbook's `curl` smoke-test before registering the webhook on GitHub.
- **Sentinel files accumulate on disk.** Phase 1 does not include cleanup. A follow-up ticket wires autopickup to delete sentinels on pickup. In the interim, the 1 GB persistent volume has headroom for years of sentinels (each is ~200 bytes).
- **Secret leakage into logs.** Explicitly prevented by never logging the request body and never logging the secret itself (only the boolean result of the compare). Self-test asserts "no body content in stderr" as a regression guard.
- **DoS via unauthenticated POSTs.** Body size capped at 1 MiB; HMAC compare is the cheap path (single SHA-256); 401s don't write sentinels. Worst case attacker forces 1 MiB compares at their outbound rate limit — benign.

**Rollback:**

- Revert the PR (the receiver + fly.toml + runbook are one unit).
- On Fly: `fly secrets unset HYDRA_WEBHOOK_SECRET`, `fly deploy` to drop the service stanza.
- On GitHub: disable the webhook on the repo's Settings → Webhooks page. Commander falls back cleanly to the existing 30-min polling (no code change needed — autopickup is the source of truth).
- The sentinel directory can be left in place safely; nothing reads it yet (this PR only produces sentinels; the consumer is a separate ticket).

## Implementation notes

(Fill in after the PR lands.)
