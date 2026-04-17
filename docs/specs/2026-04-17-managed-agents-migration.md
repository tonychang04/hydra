---
status: draft
date: 2026-04-17
author: hydra worker (issue #126)
---

# Cloud-commander always-on default + Managed Agents migration path

Implements: ticket [#126](https://github.com/tonychang04/hydra/issues/126) (T2 for
the fly.toml flip; T1 for this spec). Successor to the Phase 2 work tracked
under ticket [#40](https://github.com/tonychang04/hydra/issues/40) (cloud
commander umbrella).

## Problem

[`CLAUDE.md`](../../CLAUDE.md#your-identity-non-negotiable) commits to a
Phase 2 future where _"commander itself migrates to cloud"_ and _"each
worker runs in a managed cloud sandbox that can stand up the service
end-to-end."_ Today's shipped path is Fly Machines with
`auto_stop_machines = "suspend"` and `min_machines_running = 0`. That
minimises cost (~$3/mo — see `docs/phase2-vps-runbook.md` "Cost
expectations") but the machine sleeps whenever there's no inbound
traffic.

This sleep behaviour silently breaks commander's **"runs while the operator
sleeps"** guarantee along two axes:

1. **Autopickup ticks don't fire on a suspended machine.** The `/loop`
   skill is driven by the in-process scheduler inside commander — a
   suspended VM has no process to loop. The next tick runs only after
   something wakes the machine.
2. **New tickets assigned at 3am are invisible.** On the default config,
   the machine wakes from an HTTP request. The only inbound-HTTP path is
   the webhook receiver (ticket #41 / `docs/specs/2026-04-17-github-webhook-receiver.md`).
   If the webhook isn't wired, or if the trigger is `assignee` rather
   than a webhook-capable event, tickets sit untouched until the operator
   SSHes in and manually pokes the machine.

Two forward-looking questions fall out of this:

1. **Short-term:** should the default ship as always-on or suspend-on-idle?
2. **Long-term:** when Anthropic's Managed Agents lands, what does the
   migration path look like? Managed Agents covers natively what we
   currently patch in code (stream-timeout watchdog for #45, concurrency
   caps in `budget.json`, per-worker sandboxing that #77's DinD layer
   approximates). Every line of that code is Commander work we'll want to
   delete.

This spec answers both. The fly.toml default flip ships now; the Managed
Agents migration is documentation-only here — code follows when the
upstream product is stable enough to depend on.

## Goals

1. **Default the Fly deploy to always-on.** Flip `infra/fly.toml` so the
   Machine runs continuously (`min_machines_running = 1`,
   `auto_stop_machines = "off"`). Document the ~$5-10/mo cost trade-off
   versus the ~$3/mo suspend-on-idle default we're replacing. Operator
   override via `HYDRA_FLY_SUSPEND=1` (documented; the actual flip is a
   `fly.toml` edit — the env var is a *signal* in docs, not wired into
   deploy automation).
2. **Doctor surfaces runtime mode.** `scripts/hydra-doctor.sh` reads the
   committed `infra/fly.toml` and reports whether the deploy is configured
   as `always-on`, `suspend`, or `unknown` (file missing / malformed).
   Runs in the existing `config` category.
3. **Runbook section.** Add an "Always-on vs suspend-on-idle — when to pick
   which" section to `docs/phase2-vps-runbook.md` so operators understand
   the trade-off before rolling back.
4. **Self-test `fly-toml-always-on`.** Asserts the committed `infra/fly.toml`
   has `min_machines_running = 1` and `auto_stop_machines = "off"` on the
   primary `[http_service]` block — so a subsequent revert to the old
   defaults is caught by CI before it ships.
5. **Lay groundwork for Managed Agents.** Document when the product is
   expected, what state/config moves where, what breaks vs what improves,
   and a phased rollover plan. No code lands in this spec.

## Non-goals

- **Implementing any Managed Agents code.** This spec is forward-looking
  documentation only. When the product is GA and stable, a follow-up
  ticket (successor to #40) will carry the code change.
- **Deleting the suspend-mode config path.** Suspend-on-idle is still a
  valid choice for operators who have webhooks wired, don't run
  autopickup, and want to minimise cost. We're flipping the *default*,
  not removing the option.
- **Wiring `HYDRA_FLY_SUSPEND=1` into deploy automation.** The env var is
  a documented hint — the operator still edits `infra/fly.toml` to flip
  back. Full auto-flip from env var would require `scripts/deploy-vps.sh`
  to rewrite fly.toml at deploy time, which is out of scope for this
  ticket (the current deploy path is `git commit + fly deploy`, not a
  script that mutates the committed file).
- **Changing `scripts/deploy-vps.sh` or `setup.sh`.** Scope-locked: setup
  is under active change by ticket #130, and cloud-worker docker / repo
  clone work is under active change by #77 / #102. This ticket changes
  only `infra/fly.toml`, `scripts/hydra-doctor.sh`, `docs/phase2-vps-runbook.md`,
  the self-test golden cases, and this spec.
- **Managed Agents self-test fixtures.** Would require mocking an API
  that doesn't exist yet — pointless until the product is GA.
- **Rewriting the worker timeout watchdog (#45 / #75).** It stays in
  place even after Managed Agents lands; the watchdog is an application-
  level safety net and Managed Agents' native stream-handling just makes
  it fire less frequently. (CLAUDE.md already notes this under "Worker
  timeout watchdog" → "Relationship to Managed Agents".)

## Proposed approach

### Part 1 — Flip `infra/fly.toml` default (ships in this PR)

**Current state** (abridged):

```toml
[http_service]
  internal_port        = 8080
  auto_stop_machines   = "suspend"    # idle cost savings
  auto_start_machines  = true
  min_machines_running = 0            # operator: set to 1 if you want autopickup to tick
```

**New state:**

```toml
[http_service]
  internal_port        = 8080
  # Always-on by default (ticket #126). Trade-off: ~$5-10/mo vs
  # ~$3/mo with suspend-mode, but autopickup ticks 24/7 without an
  # external wake trigger. Suspend-mode is still supported — set
  # auto_stop_machines = "suspend" and min_machines_running = 0
  # below. Operator hint: HYDRA_FLY_SUSPEND=1 in your .hydra.env is
  # a documented signal (not automated); follow the runbook's
  # "Always-on vs suspend-on-idle" section for the manual flip.
  auto_stop_machines   = "off"
  auto_start_machines  = true
  min_machines_running = 1
```

The two secondary `[[services]]` blocks (MCP on 8765, webhook on 8766) keep
their existing `auto_stop_machines = "suspend"` / `min_machines_running = 0`
settings. The primary `[http_service]` block controls the machine's run
state; the secondary blocks' suspend settings are overridden by the primary
when a single Machine hosts all three ports. Leaving them as-is means a
suspend-mode operator only needs to flip the primary block. Keeping the
two definitions in lockstep (always-on everywhere) would be cleaner but
requires three edits instead of one on operator override and surfaces no
behavioural difference — the Machine is the unit, not the port.

### Part 2 — Doctor check for runtime mode

Add a new check to `scripts/hydra-doctor.sh` in the existing `config`
category. Parses `infra/fly.toml` using the same approach the doctor
already uses for other TOML-like config (bash + `grep`/`sed` — no new
dependency on a TOML parser; the values we care about are single-line
`key = value` pairs in a deterministic schema).

Logic:

```
read infra/fly.toml
find the [http_service] block
extract min_machines_running and auto_stop_machines
  min=1  AND auto_stop=off      → "always-on"
  min=0  AND auto_stop=suspend  → "suspend"
  min=1  AND auto_stop=suspend  → "mixed"  (warn: inconsistent)
  anything else                 → "unknown" (warn: file malformed or
                                             block missing)
```

Output format matches the existing `check_pass` / `check_warn` lines:

```
  ✓ Commander runtime mode: always-on (infra/fly.toml)
  ⚠ Commander runtime mode: suspend — autopickup won't tick while idle (HYDRA_FLY_SUSPEND=1 hint)
  ⚠ Commander runtime mode: unknown — infra/fly.toml missing or malformed
```

Never FAIL the doctor on the mode check — either explicit mode is valid;
we just surface which is live.

Spec precedent for the parsing style: `scripts/hydra-doctor.sh` already
uses `grep -F`/`jq` to poke config files without bringing in new parsers.

### Part 3 — Runbook section

Add section to `docs/phase2-vps-runbook.md` between the existing "Cost
expectations" and "Security" sections:

```markdown
## Always-on vs suspend-on-idle — when to pick which

Hydra ships with `infra/fly.toml` configured for **always-on**
(`min_machines_running = 1`, `auto_stop_machines = "off"`). This is the
default because autopickup can tick 24/7 without waiting for an external
wake trigger.

**Pick always-on** (the default) if:
- Autopickup is your main tick source (no webhook, no cron, no external
  pokes).
- Operator assigns tickets at arbitrary hours and expects them picked up
  within an autopickup interval.
- You're OK with ~$5-10/mo in Fly usage.

**Flip to suspend-on-idle** if:
- You've wired GitHub webhooks (see "Wiring GitHub webhooks" above) and
  every ticket reaches you via `issues.assigned`.
- You run Hydra against low-volume repos where ≥12h gaps between tickets
  are normal and you'd rather pay cents.
- Your Fly budget is tight.

### How to flip

1. Edit `infra/fly.toml`. In the `[http_service]` block set:
   ```toml
   min_machines_running = 0
   auto_stop_machines   = "suspend"
   ```
2. `fly deploy`.
3. Run `scripts/hydra-doctor.sh --category=config` — the "Commander
   runtime mode" check should now read `suspend`.
4. (Optional) Document the choice for future-you: `echo 'export
   HYDRA_FLY_SUSPEND=1' >> .hydra.env`. The env var is a signal for docs
   and future automation — it's not wired into deploy today.

### Reverting back to always-on

Symmetric:

1. Edit `infra/fly.toml`. `min_machines_running = 1`,
   `auto_stop_machines = "off"`.
2. `fly deploy`.
3. `scripts/hydra-doctor.sh --category=config` → `always-on`.
4. Unset HYDRA_FLY_SUSPEND in `.hydra.env` if you'd set it.
```

### Part 4 — Self-test `fly-toml-always-on`

Add a new `kind: script` case to
`self-test/golden-cases.example.json`. Uses the existing harness pattern
(exit code + `expected_stdout_jq` / `expected_stderr_contains`). No
fixtures needed — it reads the real committed `infra/fly.toml`.

```json
{
  "id": "fly-toml-always-on",
  "_description": "Assert infra/fly.toml default is always-on per ticket #126...",
  "kind": "script",
  "worker_type": null,
  "tier": "T1",
  "steps": [
    { "name": "infra/fly.toml exists",
      "cmd": "test -f infra/fly.toml && echo OK",
      "expected_exit": 0 },
    { "name": "primary [http_service] has min_machines_running = 1",
      "cmd": "awk '/^\\[http_service\\]/,/^\\[/' infra/fly.toml | grep -E '^\\s*min_machines_running\\s*=\\s*1\\b'",
      "expected_exit": 0 },
    { "name": "primary [http_service] has auto_stop_machines = off",
      "cmd": "awk '/^\\[http_service\\]/,/^\\[/' infra/fly.toml | grep -E \"^\\s*auto_stop_machines\\s*=\\s*['\\\"]off['\\\"]\"",
      "expected_exit": 0 }
  ]
}
```

The scoped `awk '/^\[http_service\]/,/^\[/'` extraction ensures we're
reading the primary block and not one of the secondary `[[services]]`
blocks (which still use suspend settings per "Part 1" above — that's
deliberate, and CI should not fail on those).

Exit-only assertions are sufficient: the `grep -E` returns 0 iff the
line matches, 1 otherwise. The harness checks `expected_exit = 0`.

### Part 5 — Managed Agents migration path (docs-only)

Covers phases 1-4 of a future migration. Drops into
`docs/phase2-vps-runbook.md` under a new "Migrating to Managed Agents"
section when/if the product is GA. Not adding that section now — we'd be
documenting speculation against an unreleased API.

#### 5a. GA-status monitoring

Success criteria for "Managed Agents is ready to migrate to":

- Public GA announcement from Anthropic (blog post, SDK release, not just
  closed beta).
- Published pricing and rate-limit model that we can reason about against
  our `budget.json` caps.
- Native support for long-running agents (our workers can run 18+ minutes;
  short-lived serverless-style APIs won't fit).
- Concurrency primitives (per-operator sandboxing) at least equivalent to
  what Fly Machines give us today.
- Secret store that supports "per-operator secrets, not commingled across
  operators."

Track GA signal in `memory/escalation-faq.md` under a new entry
"Managed Agents: is it GA yet?" updated when operators see the
announcement. We don't want to silently miss the switch-over window.

#### 5b. Migration procedure (sketch)

**State volume → Managed Agents storage.**

Today: `/hydra/data` is a Fly persistent volume mounted at
`/hydra/data` (see `[[mounts]]` in `infra/fly.toml`). Contains
`state/*.json`, `memory/**`, `logs/*.json`.

Future: whatever persistence primitive Managed Agents exposes — likely a
durable KV or object store keyed by operator + deployment. The migration
script walks `/hydra/data`, snapshots each file, and ingests it into the
Managed Agents store. File-level granularity matters because commander's
state files (`state/active.json`, `state/memory-citations.json`) mutate
independently — a single-blob backup would serialise them.

Estimated ingest size: ~1 GB on a long-running commander (the default
Fly volume size). Most of that is `logs/` and `memory/archive/`.

**Fly secrets → Managed Agents secret store.**

Today: `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`,
`HYDRA_WEBHOOK_SECRET`, `HYDRA_SUPERVISOR_TOKEN` live in `fly secrets`.

Future: Managed Agents' secret store. Migration is a one-time `fly
secrets list` → copy over. The Anthropic/Claude credentials become
redundant once Managed Agents handles auth natively; keep GitHub +
webhook + supervisor tokens as-is.

Operator experience: a `scripts/migrate-to-managed-agents.sh` script
(future ticket) runs locally against both Fly and the new API, confirms
parity, then flips DNS / MCP endpoint. `./hydra doctor` grows a "Managed
Agents" category that verifies the migration landed cleanly.

#### 5c. What breaks vs improves

**Improvements (code we can delete):**

- **Worker stream-timeout watchdog** (ticket #45, spec
  `docs/specs/2026-04-16-worker-timeout-watchdog.md`): Managed Agents
  handles stream idle-timeouts natively. We keep `scripts/rescue-worker.sh`
  as a belt-and-suspenders safety net (see CLAUDE.md "Worker timeout
  watchdog" → "Relationship to Managed Agents") but the trigger rate
  drops to ~zero.
- **Concurrency caps in `budget.json`.** Managed Agents enforces these
  upstream. We keep the file as a docs-of-record but stop gating on it —
  the upstream limit is authoritative.
- **Worker docker DinD image** (ticket #77 / spec `cloud-worker-docker.md`).
  Managed Agents' sandbox spec covers docker natively. The
  `ENABLE_DOCKER=true` build-arg goes away.
- **Fly-specific deploy scripts** (`scripts/deploy-vps.sh`). Replaced by
  `scripts/deploy-managed-agents.sh` (future).
- **`infra/fly.toml`, `infra/Dockerfile`, `infra/entrypoint.sh`.** Fly
  becomes one deploy target; Managed Agents is the other. We'll probably
  keep Fly as the "run locally / run on your own VPS" option — it's still
  the cheapest/most-portable baseline.

**Risks + breakage:**

- **OAuth flow changes.** Claude Code today uses a long-lived OAuth token
  (`CLAUDE_CODE_OAUTH_TOKEN`). Managed Agents likely mints ephemeral
  tokens internally. The env var still exists for Fly-mode operators.
- **Tool permissions model.** Our `.claude/settings.local.json` allow/deny
  lists are Claude Code conventions. Managed Agents may have its own
  permission primitives that don't 1:1 map. Migration will need a
  translation pass — possibly automated via a helper that reads
  `settings.local.json` and emits the Managed Agents equivalent.
- **Supervisor escalation path.** `scripts/hydra-supervisor-escalate.py`
  hits an MCP server we defined in
  `docs/specs/2026-04-16-mcp-agent-interface.md`. If Managed Agents has
  its own supervisor-style escalation primitive, we re-target the script
  to speak that instead. The envelope shape stays constant — operator
  UX doesn't change.
- **Self-test harness.** `self-test/run.sh --kind=script` is fine
  (pure bash). The `worker-implementation` / `commander-self` kinds all
  currently SKIP; when the Managed Agents executor lands, those kinds
  get a concrete runner for the first time. This is net improvement, but
  the fixtures need rewiring.
- **Cost model.** Fly is flat ~$5/mo usage-billed. Managed Agents is
  likely per-run + per-token metered. Operator-facing cost report in
  `quota` command has to learn the new model.

#### 5d. Phased rollover plan

Ordered — each phase assumes previous phases are GA and self-testing:

1. **Phase 0 (today, this PR).** Always-on Fly default + doctor check +
   this spec. No Managed Agents code touched.
2. **Phase 1 (Managed Agents GA signal).** Add `docs/managed-agents-readiness.md`
   tracking the GA criteria above. No code. Update
   `memory/escalation-faq.md` when operators see the announcement.
3. **Phase 2 (first migration on a test deploy).** New
   `scripts/migrate-to-managed-agents.sh` (dry-run by default). Tested
   against a throwaway Fly deploy first. Validates that state survives
   the ingest and workers spawn correctly under the new transport.
4. **Phase 3 (operator opt-in migration).** Documented migration in
   the runbook. `scripts/deploy-managed-agents.sh` ships. Fly remains
   supported — new operators get a choice, not a forced flip. Doctor
   grows a Managed Agents category.
5. **Phase 4 (Fly demoted to secondary).** Only if Managed Agents
   uptake is high enough that Fly-specific maintenance is dead weight.
   No hard date — the decision is data-driven from operator logs.

Timeline: Phase 0 lands with this PR. Phase 1+ is gated on the Anthropic
product, not on us. If the product never ships, phases 1-4 are
permanently deferred — that's fine, Fly + always-on is a perfectly
respectable commander runtime and the rest of Hydra doesn't depend on
them.

## Test plan

**Phase 0 (this PR):**

- Self-test `fly-toml-always-on` passes on the new `infra/fly.toml` —
  runs via `./self-test/run.sh --case=fly-toml-always-on`.
- Self-test `hydra-doctor-runs-clean` still passes (no regression from
  the new config check).
- Manual: `scripts/hydra-doctor.sh --category=config` prints `✓
  Commander runtime mode: always-on` on the new default.
- Manual: flip `min_machines_running = 0` and `auto_stop_machines =
  "suspend"` locally; doctor should now warn with
  `⚠ Commander runtime mode: suspend`. Revert before committing.
- Manual: verify `bash -n scripts/hydra-doctor.sh` exits 0.
- Manual: verify runbook renders correctly (no markdown syntax errors)
  via GitHub's rendered view on the PR.

**Phases 1-4 (future):** out of scope for this PR's test plan.

## Risks / rollback

**Deploy cost risk.** An operator unknowingly upgrading from
suspend-mode to always-on will see their monthly Fly bill rise from
~$3 to ~$5-10. Mitigation:

- The runbook section documents the cost trade-off *before* the operator
  decides.
- Doctor surfaces the mode — an operator running `hydra doctor` after an
  update sees the new mode explicitly.
- The CHANGELOG entry for this PR calls the flip out as a **default
  change**, not a silent bump.
- Rollback is a two-line edit + `fly deploy` — low friction.

**Self-test false-positive risk.** If an operator deliberately runs
suspend-mode, `self-test/run.sh` would fail the `fly-toml-always-on`
case. Acceptable: they're ALREADY off the default and their self-test
suite is expected to surface the difference. The case doc-comment makes
this explicit ("_asserts the shipped default — suspend-mode operators
skip or patch this case_"). A follow-up nice-to-have is `--skip=<case>`
support in `run.sh`, but that's orthogonal.

**Managed Agents speculation risk.** Every claim about the future
product in §5 is speculative. Mitigation: this spec is versioned in git,
dated, and flagged `status: draft`. When Managed Agents actually GAs,
the first real spec (successor ticket) compares this doc to reality and
retires whichever claims don't hold.

**Scope creep risk.** The ticket's intent is narrow (flip a default +
doctor check + spec). Expanding to "implement the migration script" or
"rewrite deploy-vps.sh" in the same PR would balloon the review surface
and step on #77 / #130 / #102. The Non-goals section above locks this
in.

## References

- Ticket [#126](https://github.com/tonychang04/hydra/issues/126) — this work
- Ticket [#40](https://github.com/tonychang04/hydra/issues/40) — Phase 2
  cloud commander umbrella
- Ticket [#41](https://github.com/tonychang04/hydra/issues/41) — webhook
  receiver (complementary wake path)
- Ticket [#45](https://github.com/tonychang04/hydra/issues/45) — stream
  timeout watchdog (stays after Managed Agents migration)
- Ticket [#77](https://github.com/tonychang04/hydra/issues/77) — cloud
  worker docker (replaced by Managed Agents native sandbox)
- Ticket [#43](https://github.com/tonychang04/hydra/issues/43) — original
  Managed Agents tracking issue
- Runbook: `docs/phase2-vps-runbook.md`
- Doctor: `scripts/hydra-doctor.sh` · spec
  `docs/specs/2026-04-16-hydra-doctor.md`
- Self-test harness: `self-test/run.sh` · spec
  `docs/specs/2026-04-16-self-test-runner.md`
