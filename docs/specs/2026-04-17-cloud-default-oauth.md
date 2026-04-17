---
status: draft
date: 2026-04-17
author: hydra worker (issue #106)
---

# Cloud-default commander with dual OAuth (Claude + Codex)

**Ticket:** [#106](https://github.com/tonychang04/hydra/issues/106)
**Tier:** T2 — coordinator ticket. Docs + one new script + small additive `infra/entrypoint.sh` tweak. No code inside commander's flow itself.

## Problem

Cloud commander has been live on Fly (`hydra-commander-<operator>.fly.dev`) since PRs #54 / #76 / #89 landed — the MCP server binary, repo-clone-on-boot, the Slack bot, and the entrypoint wire are all in place. The pieces work independently, but the "local-to-cloud" switchover is still a multi-hour ritual that forks across five documents (`INSTALL.md` Option C, `docs/phase2-vps-runbook.md`, the MCP `register-agent` subsection, the Slack setup walk-through, the dual-mode memory spec). There is no single command that flips an operator from local commander to cloud commander.

Meanwhile, the dual-backend story has shifted. `worker-codex-implementation` (ticket #96) is now the supported second backend, but `infra/entrypoint.sh` only checks for Claude credentials (`CLAUDE_CODE_OAUTH_TOKEN` **or** `ANTHROPIC_API_KEY`). If an operator wants a Codex-only Fly deploy (because they burned through Claude Max quota and keep Codex API key in reserve), the entrypoint hard-fails at boot — "Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set" — even though commander doesn't actually need Claude auth to route all its tickets to `preferred_backend: codex` repos.

The operator's stated direction, reaffirmed 2026-04-17: **"the infrastructure should eventually be to cloud right... currently it's still local. although i still want to use the oauth token for both claude code and codex."** Flat-rate OAuth billing is the economic reason to prefer cloud at all — metered API usage in a headless loop gets expensive fast. The migration ritual has to preserve OAuth for BOTH providers, not just Claude.

Three concrete gaps this spec closes:

1. **No migration command.** Operators who have a working local install today have no guided path to move their auth to `fly secrets` + generate an MCP bearer + print a usable config snippet for their main agent. They stitch it together from five docs, skip the dual-mode memory step, and end up with a cloud commander that works but doesn't share memory with their laptop.
2. **Entrypoint rejects Codex-only auth.** `infra/entrypoint.sh` treats Claude creds as mandatory. A pure-Codex deploy (valid future state if the operator moves all repos to `preferred_backend: codex`) can't boot. The fix is one-line: accept Codex auth as a third option alongside Claude OAuth / API-key.
3. **INSTALL.md still leads with local.** Options A + B (one-liner + manual local) are primary; Option C (cloud + MCP) is last and framed as Phase 2 direction. The operator's preference has flipped — cloud is now the recommended primary mode for anyone who wants 24/7 commander. Local stays documented as dev / offline mode.

## Goals / non-goals

**Goals:**

1. **One-shot migration command** (`scripts/hydra-migrate-to-cloud.sh`) that walks the operator through: detect local auth state → generate Claude OAuth (`claude setup-token`) if missing → generate/locate Codex OAuth if missing → push either or both to `fly secrets` → generate MCP bearer via `./hydra mcp register-agent` → print the MCP URL + bearer snippet for their main-agent config → optional follow-up commands (dual-mode memory, Slack bot, autopickup disable on laptop).
2. **Entrypoint accepts either provider, not both required.** `infra/entrypoint.sh` keeps its hard-fail (no auth at all), but unblocks "Codex-only" by adding a third branch: if `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` are both empty, accept `$HYDRA_CODEX_AUTH_ENV` (default `CODEX_SESSION_TOKEN`) or `OPENAI_API_KEY` as sufficient.
3. **INSTALL.md reorder.** Option C (cloud) becomes the primary recommended path. Option A/B (local) demote to "Dev mode: run commander on your laptop" subsections under a "Local install" umbrella.
4. **Runbook migration section.** `docs/phase2-vps-runbook.md` gains a "Migrating from local to cloud" section that references the new script and covers rollback.
5. **OAuth rotation docs.** Document what we know (Claude 1-year) and what we don't (Codex — varies by auth mode). Add the rotation procedure + a note that weekly retro should surface the reminder when rotation's due.
6. **Self-test case.** `migrate-to-cloud-dry-run` (kind: script) — runs `scripts/hydra-migrate-to-cloud.sh --dry-run` against a tmpdir. Asserts: script is bash-syntax-clean, `--help` prints usage, `--dry-run` does not shell out to `fly secrets set` / `./hydra mcp register-agent` / `claude setup-token`, and the dry-run summary lists the exact Fly secrets that WOULD be staged.

**Non-goals:**

- **Implementing the Codex OAuth client itself.** That's Codex-CLI's concern (whether it reads `OPENAI_API_KEY`, `CODEX_SESSION_TOKEN`, or something else is upstream). Hydra is a pass-through: we document the env-var convention, make it configurable via `HYDRA_CODEX_AUTH_ENV`, and push whichever token the operator has into `fly secrets`.
- **Removing API-key fallback.** `ANTHROPIC_API_KEY` (metered) still works. `OPENAI_API_KEY` still works for Codex. The goal is to make OAuth the default-documented path, not to remove the metered escape hatch.
- **Multi-account OAuth.** Single-operator, single-Claude-account, single-Codex-account for v1. Multi-tenancy (several operators sharing one cloud) is a future ticket.
- **Auto-rotation.** Rotation is still manual — re-run the migration script with fresh tokens when Claude OAuth hits its 1-year wall. Auto-rotation would require a webhook from Anthropic / OpenAI that doesn't exist.
- **Webhook receiver changes** (tickets #40 / #41). The migration script documents that webhook secrets are separate `fly secrets` but doesn't set them.
- **`./hydra migrate-to-cloud` subcommand wiring.** For this ticket, the entrypoint is `scripts/hydra-migrate-to-cloud.sh` invoked directly. Wiring a `./hydra migrate-to-cloud` dispatch into the `setup.sh` heredoc is follow-up work — kept out of scope so we don't destabilize the launcher contract (per `memory/learnings-hydra.md` 2026-04-17 #84).

## Proposed approach

### New script: `scripts/hydra-migrate-to-cloud.sh`

Interactive bash, ANSI-colored prompts, idempotent. Mirrors `setup.sh` style: auto-detect what's already installed / what's missing, ask at most one question per section, accept `--non-interactive` + env-var inputs for scripted runs, respect `HYDRA_NON_INTERACTIVE` + `CI=true`, and provide a `--dry-run` mode that executes no side effects.

**Sections (each a labeled stanza):**

1. **Preflight.** Check `flyctl` + `fly auth whoami`, the target `<fly-app>` name (prompt or env var `HYDRA_FLY_APP`), and that `infra/fly.toml` exists. Refuse to run on a host missing `claude`, `gh`, or `jq`. Same hard-fail pattern as `setup.sh`.
2. **Auth inventory.** Report what the operator currently has locally:
   - Claude Max session (`claude /status` or env detection) → already-logged-in or not.
   - `CLAUDE_CODE_OAUTH_TOKEN` in current env → present or absent.
   - `OPENAI_API_KEY` in current env → present or absent.
   - `$HYDRA_CODEX_AUTH_ENV` (default `CODEX_SESSION_TOKEN`) → present or absent.
   - `~/.codex/` exists (codex-CLI login state) → present or absent.
   The goal is to frame the next prompts around what's missing rather than asking for every credential unconditionally.
3. **Claude OAuth generation.** If the operator doesn't have `CLAUDE_CODE_OAUTH_TOKEN` set in their env, offer to run `claude setup-token` (the canonical generation command). Token goes into a shell-local variable only — never a file. If they decline, skip and note: you'll need `ANTHROPIC_API_KEY` at fly-secrets time.
4. **Codex OAuth generation.** Same shape: if nothing Codex-auth-shaped is found, offer to run `codex login` (or the operator's local equivalent). Document the fallback: `OPENAI_API_KEY` via `export`.
5. **Fly secrets push.** Stage whichever of `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, `$HYDRA_CODEX_AUTH_ENV`, `OPENAI_API_KEY`, and `GITHUB_TOKEN` are set, via `fly secrets set --stage` with `--app $HYDRA_FLY_APP`. Stage, don't apply — let the operator `fly deploy` at the end so the order-of-operations is explicit.
6. **MCP bearer.** Run `fly ssh console --app $HYDRA_FLY_APP -C './hydra mcp register-agent <main-agent-id>'` to produce a bearer token for the operator's main agent. Print the raw token ONCE to stdout, plus a copy-paste config snippet (the bearer token + `https://$HYDRA_FLY_APP.fly.dev/mcp` URL + the exact env-var name the consuming agent reads).
7. **Deploy + verify.** Prompt to run `fly deploy --app $HYDRA_FLY_APP --config infra/fly.toml`. On success, curl `/health` and report uptime. Print the attach / logs / next-steps block that mirrors `scripts/deploy-vps.sh`.
8. **Next steps.** Suggest (optional): `autopickup off` on laptop commander (so only cloud ticks), enable dual-mode memory (`HYDRA_MEMORY_BACKEND=s3`), enable Slack bot. Don't do these automatically — they're per-operator preference.

**Dry-run mode (`--dry-run`):** every side effect becomes a log line prefixed `DRY RUN:`. No `fly secrets set`, no `fly deploy`, no `fly ssh console`, no `claude setup-token`. The script exits 0 and prints the list of secrets it WOULD stage. This is what the self-test exercises.

**Security invariants:**
- Raw tokens NEVER written to a file (same pattern as `scripts/hydra-mcp-register-agent.sh`).
- Token values are passed to `fly secrets set` via `fly secrets set --stage KEY=value` — `fly` reads the value from argv, which shows up in `ps` briefly. This is a pre-existing Fly CLI behavior that `scripts/deploy-vps.sh` already accepts; we don't make it worse.
- `--dry-run` prints only the set of secret NAMES it would stage, never the values.
- Bearer tokens from `./hydra mcp register-agent` are printed to stdout exactly once (inherited from that script's own security contract).

### `infra/entrypoint.sh` — dual-OAuth acceptance

The current check (lines 77-84 of `infra/entrypoint.sh`) hard-fails if neither `CLAUDE_CODE_OAUTH_TOKEN` nor `ANTHROPIC_API_KEY` is set. This spec adds Codex auth vars to the "accept" set. New check:

```
CODEX_AUTH_ENV="${HYDRA_CODEX_AUTH_ENV:-CODEX_SESSION_TOKEN}"
# Dereference the named env var.
CODEX_AUTH_VAL="${!CODEX_AUTH_ENV:-}"

have_claude=0
have_codex=0
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" || -n "${ANTHROPIC_API_KEY:-}" ]] && have_claude=1
[[ -n "${CODEX_AUTH_VAL}" || -n "${OPENAI_API_KEY:-}" ]] && have_codex=1

if [[ "${have_claude}" -eq 0 && "${have_codex}" -eq 0 ]]; then
  fail "No provider auth set. Set at least one: CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY (Claude) or ${CODEX_AUTH_ENV} / OPENAI_API_KEY (Codex)."
fi
```

Commander still detects per-spawn which backend to use (via `state/repos.json:preferred_backend` — ticket #96's wiring, re-routed by ticket #97 when that lands). If an operator has Codex-only auth and a ticket needs Claude, the worker fails at spawn time with a clear "Claude auth not present" error — that's a ticket-level concern, not an entrypoint one. Mixing the two on a tier level is correct and safe.

**What this deliberately does not do:**
- Does not add a default `HYDRA_CODEX_AUTH_ENV` value to `fly.toml`. The env var is only needed when an operator chooses a non-default name; staying absent is correct.
- Does not break backward compat. If an operator has `CLAUDE_CODE_OAUTH_TOKEN` set (today's default), the new check accepts it via `have_claude=1` and skips the Codex branch entirely.
- Does not log which codex env var was present. Just reports "Auth: Codex provider detected" / "Auth: Claude provider detected" / "Auth: both providers detected" — never the var name, never the value.

### Codex env var convention

Codex CLI's canonical env var for OAuth isn't stable as of 2026-04-17. Upstream is still evolving. Hydra's convention:

| Priority | Env var | Mode |
|---|---|---|
| 1 | `OPENAI_API_KEY` | API-key auth (headless, preferred on Fly) |
| 2 | `$HYDRA_CODEX_AUTH_ENV` (default `CODEX_SESSION_TOKEN`) | ChatGPT-session OAuth (for operators on a tier that supports `gpt-5.2-codex` under session auth) |

`HYDRA_CODEX_AUTH_ENV` lets operators override the env var name if upstream Codex-CLI settles on something different (e.g. `CODEX_AUTH_TOKEN`, `OPENAI_SESSION_TOKEN`). Set it in `fly secrets set HYDRA_CODEX_AUTH_ENV=<name>` AND `fly secrets set <name>=<value>` if you want to use a non-default.

We document this in `docs/phase2-vps-runbook.md` "Migrating from local to cloud" with a caveat: **if Codex-CLI settles on a different canonical name, update `HYDRA_CODEX_AUTH_ENV` or submit a PR to change the Hydra default.**

### INSTALL.md reorder

Currently:
1. Option A (one-liner local) — "Most operators start here."
2. Option B (manual local) — same end-state as A.
3. Option C (cloud + MCP) — "contract + config only in this release" (stale).

Reordered to:
1. **Option A — cloud + MCP (recommended).** Promoted + rewritten: cloud commander is the supported primary mode. Points at `docs/phase2-vps-runbook.md` and the new migration script.
2. **Option B — one-liner local (dev mode).** Same current Option A, demoted. "If you want to try Hydra on your laptop first."
3. **Option C — manual local (dev mode).** Same current Option B, demoted.

The comparison table at the top stays; the "when to pick it" column flips so cloud is the default, local is the dev/offline mode.

**Backward compat:** we do NOT remove Option B / C content. Operators on local still find their walk-through. We just don't lead with it.

### `docs/phase2-vps-runbook.md` — new section

Add "Migrating from local to cloud" after "First-time deploy":

1. One-paragraph intro: who should migrate, what it preserves (memory, learnings, citations via dual-mode memory optional), what it does not (operator GitHub identity — `GITHUB_TOKEN` is still the operator's own PAT).
2. Pre-flight checklist: laptop commander running cleanly, all repos committed, no in-flight worker in `state/active.json`.
3. The command: `./scripts/hydra-migrate-to-cloud.sh` (with `--dry-run` first).
4. Rollback: un-stage the Fly secrets, `./hydra` on laptop keeps working identically — cloud and laptop can coexist; migration only shifts where ticket pickup happens.
5. OAuth rotation table:
   - Claude: `sk-ant-oat-...`, 1-year validity, rotate via `claude setup-token` + `fly secrets set CLAUDE_CODE_OAUTH_TOKEN=...`.
   - Codex (API-key mode): `sk-...`, validity depends on OpenAI dashboard settings, rotate via dashboard + `fly secrets set OPENAI_API_KEY=...`.
   - Codex (session mode): validity NOT documented by upstream Codex-CLI as of this writing. Operators should verify after re-deploy with a smoke ticket.
6. Weekly retro hook: the retro template already has a `## Proposed edits` section. Document that commander should add an "OAuth rotation reminder" here starting 11 months after the most recent migration. That's per the existing retro self-discipline — no new template work needed.

### Alternatives considered

- **Alternative A: One big `./hydra migrate-to-cloud` subcommand wired into `setup.sh`'s heredoc launcher.** Nicer UX, but touches the launcher contract flagged in `memory/learnings-hydra.md` 2026-04-17 #84 ("reflowing or restructuring breaks the launcher contract"). Deferred; follow-up ticket can add it once `setup.sh` is stable enough to absorb an additional dispatch arm.
- **Alternative B: Require both Claude + Codex auth at entrypoint.** Simpler detection logic, but breaks the Codex-only deploy case (valid future state). Rejected — the whole point of dual-backend is partial availability.
- **Alternative C: Write the migration as a skill (under `skills/hydra-operator/`) rather than a script.** Skills are for operator-facing guidance in a Claude session, not for shell side effects. The migration is fundamentally a bash ritual (fly CLI calls, file writes, process spawns), so a script is the right surface. Skills can still reference the script.
- **Alternative D: Put all three auth-var branches in `fly.toml` instead of `entrypoint.sh`.** Fly env-var defaults in `fly.toml` are static — they can't express "accept either X or Y". The check has to live in shell.

## Test plan

1. **Spec-presence CI** (existing) — `docs/specs/2026-04-17-cloud-default-oauth.md` exists, YAML frontmatter parses. Covered by the ci spec-presence check.
2. **Script syntax** (self-test, kind=script): `bash -n scripts/hydra-migrate-to-cloud.sh` exits 0 and echoes OK.
3. **`--help` prints usage** (self-test): `NO_COLOR=1 scripts/hydra-migrate-to-cloud.sh --help` exits 0 and stdout contains `Usage:` + `--dry-run`.
4. **`--dry-run` is side-effect-free** (self-test, the self-test-runner case the ticket named): run against a tmpdir where `fly`, `claude`, and `gh` are stubbed binaries that emit tracking lines; assert that no `fly secrets set`, no `fly deploy`, no `claude setup-token`, and no `./hydra mcp register-agent` line is emitted by the stubs. Assert stdout includes `DRY RUN:` and an explicit list of secret-var names that would be staged.
5. **Entrypoint accepts dual auth** (inline shell test in the existing `entrypoint-dry-run` golden case): simulate three env states — Claude-only, Codex-only, both. Each should let the entrypoint proceed past the auth check. Fourth state (neither) must still fail with the new error message. Covered by bolting onto the existing `entrypoint-dry-run` case rather than a new one.
6. **INSTALL.md manual read-through** (human): operator reviews the re-ordered INSTALL.md and confirms Option A (cloud) is unambiguous and Options B/C (local) still have enough content for a first-time operator who wants local.

## Risks / rollback

- **Risk: the new entrypoint auth check rejects an operator who had a working Claude-only deploy before.** Low — the new check is strictly a superset of the old one. If `CLAUDE_CODE_OAUTH_TOKEN` OR `ANTHROPIC_API_KEY` was set before, `have_claude=1` today; it still is tomorrow. Regression would be a typo. Mitigated by the entrypoint-dry-run self-test. Rollback: revert `infra/entrypoint.sh` to the previous check in one edit.
- **Risk: operators follow the reordered INSTALL.md, try cloud first without a Fly account, get confused.** Mitigated by the "Prerequisites" block at the top of Option A (cloud) that says: "Requires a Fly.io account. For your first taste of Hydra without any cloud setup, jump to Option B (local)." Rollback: revert the INSTALL.md reorder; text is additive and reordering is reversible.
- **Risk: the migration script's dry-run leaks secret values into a log file the operator shares when debugging.** The script writes only to stdout; the operator can redirect to a file, but the secret values are never *printed* in dry-run (only NAMES). Real-run mode prints the MCP bearer token once. Same security posture as `./hydra mcp register-agent` today.
- **Risk: operators who follow the migration and then `autopickup off` on their laptop lose their local ticket-clearing muscle memory.** Not a safety issue — just a habit shift. Documented in the runbook section.
- **Risk: `HYDRA_CODEX_AUTH_ENV` lets a malicious config file override the auth env var name, pointing entrypoint.sh at an attacker-controlled var.** The operator controls their own env, so this is self-inflicted. `entrypoint.sh` dereferences via `${!VAR}` which is explicit about the indirection. Not a cross-operator attack surface.
- **Rollback path if this ticket lands and breaks something:** revert the PR. All three artifacts (script, entrypoint edit, INSTALL.md reorder) are additive or small-delta edits. No schema change, no migration, no data touched.

## Implementation notes

(To be filled after the PR lands.)
