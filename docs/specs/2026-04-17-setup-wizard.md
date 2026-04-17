---
status: draft
date: 2026-04-17
author: hydra worker (ticket #152)
---

# `./hydra setup` — gstack-style first-run wizard

Implements: ticket #152 ("Interactive setup wizard: gstack-style `./setup` that makes first-run 'just work'").

## Problem

Hydra already has a `setup.sh` (spec: `2026-04-17-interactive-setup.md`, ticket #102) that writes `.hydra.env`, stages `state/*.json` from `.example` templates, and regenerates `./hydra`. It is idempotent and CI-safe. What it does NOT do today:

- Prompt for repos to track. The operator runs `setup.sh`, then has to go find the `./hydra add-repo` docs and type a second command per repo. That's the scavenger hunt the ticket calls out.
- Prompt for autopickup config. `state/autopickup.json` is staged with defaults (`interval_min=30`, `auto_enable_on_session_start=true`) and the operator never sees them.
- Acknowledge connectors. Linear / Slack / Supervisor MCP are wired via `./hydra connect` (ticket #139, now merged). `setup.sh` doesn't mention that command; a first-run operator never learns it exists.
- Record that setup completed. Nothing distinguishes first-run from steady-state — the session greeting can't reason about it.

The goal is a single `./hydra setup` invocation that takes the operator from `git clone` to "Commander session picking up a ticket" in under 2 minutes, with one guided flow, then leaves a fingerprint so the launcher knows setup is done.

## Goals / non-goals

**Goals:**

1. `./hydra setup` dispatches to a new `scripts/hydra-setup.sh` wrapper that wraps the existing `setup.sh` and layers on: repo picker → autopickup config → connector hint (deferred to `./hydra connect`) → `state/setup-complete.json` fingerprint.
2. Keep `setup.sh` on disk and keep its launcher-regen contract intact. `./hydra setup` calls it internally (via `bash "$ROOT/setup.sh" "$@"`) so everything the existing script does — prereq check, `.hydra.env` write, launcher regen — happens exactly once, unchanged, and existing CI flows (`scripts/test-local-config.sh`, self-test `autopickup-default-on-smoke`) keep passing byte-for-byte.
3. Non-interactive mode: `./hydra setup --non-interactive --repos=tonychang04/hydra,tonychang04/other --autopickup-interval=30` produces identical state to a fully-answered interactive run, with no prompts. `--non-interactive` implied when stdin is not a TTY (matching `setup.sh`'s existing rule).
4. Idempotent re-run: on re-entry, the wrapper reads `state/setup-complete.json` + `state/repos.json` + `state/autopickup.json`, prints the current config, and offers "update" (single-answer: `[u]pdate / [r]otate / [q]uit`, default `q`). No clobber without explicit consent.
5. Schema-validates every state write via `scripts/validate-state.sh <file>` against `state/schemas/<name>.schema.json`. `state/setup-complete.json` is new — this spec also defines `state/schemas/setup-complete.schema.json`.
6. Connector prompts DEFER. The wizard prints a one-line hint (`Connectors (Linear / Slack / Supervisor): run ./hydra connect <name> when you're ready.`) and exits without sub-wizards. No attempt to reimplement `./hydra connect` inside setup — it's a separate already-merged tool.
7. First-run fingerprint: `state/setup-complete.json` with `{version, completed_at, mode}`. `version` is the hydra launcher marker (same 8-hex from `scripts/launcher-marker.sh`). `completed_at` is ISO-8601 UTC. `mode` is one of `interactive` / `non-interactive`. Commander's session greeting can `jq -e` this file to decide whether to print a "finish setup" hint.
8. CLAUDE.md gets **one line** (bloat rule). README "Try it in 60 seconds" gains one line pointing at `./hydra setup` instead of the two-step `./setup.sh` + `./hydra add-repo` flow.

**Non-goals:**

- Rewriting the existing `setup.sh` prereq-check block. It already auto-detects claude / gh / docker / aws / flyctl / jq with the correct green-yellow-red taxonomy. Reusing it verbatim is the lowest-risk move.
- Renaming `setup.sh` to `scripts/hydra-setup.sh` in place. The ticket allows either; the wrapper approach avoids touching `setup.sh`'s launcher heredoc and its 640-line test surface. Rename is a followup if operators stop calling `./setup.sh` directly.
- Building a connector wizard inside setup. `./hydra connect` exists (ticket #139); duplicating it would break the single-source-of-truth rule. Setup prints a hint and exits.
- Docker / cloud install modes. Phase 2 territory.
- Language i18n, TUI widgets, runtime deps beyond bash + jq + claude + gh.
- Auto-running `./hydra doctor` at end of setup. `setup.sh` already prereq-checks; doctor is a separate post-install diagnostic the operator can run explicitly.

## Proposed approach

### File layout

- New: `scripts/hydra-setup.sh` — the wrapper. ~250 lines: parse flags, call `setup.sh`, repo picker, autopickup config, connector hint, write fingerprint.
- New: `state/schemas/setup-complete.schema.json` — Draft-07 schema for the fingerprint file.
- Modified: `setup.sh` — no behavioral changes. Only change is the **embedded `./hydra` launcher heredoc** gains a `setup)` case that dispatches to `scripts/hydra-setup.sh`. That's two lines inside the heredoc: a help-text line + a case arm, identical structure to the existing `add-repo` / `doctor` / `connect` dispatches.
- Modified: `README.md` — one line in the getting-started section.
- Modified: `CLAUDE.md` — one line under "Commands you understand" (per bloat rule).
- Not modified: `scripts/hydra-connect.sh` (we only call it by name if the operator types yes — but the ticket says punt sub-wizards, so we don't even call it; just print the hint).

### Wrapper flow (happy path, interactive TTY)

```
$ ./hydra setup
▸ Hydra setup at /Users/foo/hydra

  [1/4] Environment check
    (delegates to ./setup.sh — same output as before)
  ✓ Claude Code 1.2.3
  ✓ GitHub CLI — signed in as foo
  ...
  ✓ .hydra.env
  ✓ ./hydra launcher (version a1b2c3d4)

  [2/4] Add repos to track
    One per line as owner/name. Blank line to finish.
    You can always add more later with ./hydra add-repo.
  > tonychang04/hydra
  ✓ tonychang04/hydra added
  > InsForge/InsForge
  ✓ InsForge/InsForge added
  > (blank)
  ✓ 2 repos in state/repos.json

  [3/4] Configure autopickup
    Autopickup polls your repos at a fixed interval and spawns workers.
    Interval (5–120 minutes) [30]: (enter)
    Auto-enable on session start? [Y/n]: (enter)
  ✓ state/autopickup.json written

  [4/4] Connectors (optional)
    Linear, Slack, and upstream Supervisor MCP wire up via ./hydra connect.
    Skipped for now — run `./hydra connect <linear|slack|supervisor>` later.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Setup complete.

Next:
  ./hydra              Launch the commander
  ./hydra list-repos   Show tracked repos
  ./hydra doctor       Re-run the install sanity-check
```

### Non-interactive flow

```
$ ./hydra setup --non-interactive \
    --repos=tonychang04/hydra,InsForge/InsForge \
    --autopickup-interval=30 \
    --autopickup-auto-enable=true
```

All prompts skipped. Missing required flag (e.g. `--repos` on a fresh install) → exit 2 with a pointer. On existing installs, all flags optional (re-run keeps current config).

### Idempotent re-run

```
$ ./hydra setup
▸ Hydra setup at /Users/foo/hydra

Setup already completed on 2026-04-17T14:23:09Z (interactive, version a1b2c3d4).

Current config:
  Repos (2):
    ✓ tonychang04/hydra (enabled, trigger=assignee)
    ✓ InsForge/InsForge (enabled, trigger=assignee)
  Autopickup: enabled=false (auto_enable_on_session_start=true), interval=30min

What now? [u]pdate repos / [r]otate autopickup / [q]uit [q]: q
```

Re-run with `--non-interactive` and no repo/autopickup flags → print status, exit 0 (no changes). With flags → apply and rewrite fingerprint.

### `state/setup-complete.json` schema

```json
{
  "version": "a1b2c3d4",
  "completed_at": "2026-04-17T14:23:09Z",
  "mode": "interactive"
}
```

`version` is the 8-hex launcher marker (from `scripts/launcher-marker.sh compute hydra`), so `setup-complete` records the launcher contract revision the setup matched. If the operator upgrades hydra and the launcher marker changes, Commander can detect that setup may be stale and print an optional re-run hint (out of scope for this ticket — just data available for a follow-up).

`mode` documents how setup was run, mostly for logs. `non-interactive` is interesting because it implies a scripted install; Commander may want to skip certain interactive-only nudges for such operators (again, follow-up).

The schema lives at `state/schemas/setup-complete.schema.json`, Draft-07, `required: [version, completed_at, mode]`, `additionalProperties: false`. Validated via `scripts/validate-state.sh state/setup-complete.json` before writing.

### Atomicity

All state writes go tmp + mv, matching `hydra-add-repo.sh`:

```
tmp="$(mktemp "${file}.XXXXXX")"
printf '%s' "$payload" | jq . > "$tmp"
scripts/validate-state.sh "$tmp"  # schema-validate BEFORE moving
mv "$tmp" "$file"
```

### Dispatch wiring in `./hydra`

Inside `setup.sh`'s embedded launcher heredoc, add:

```bash
  setup)        shift; hydra_exec_helper scripts/hydra-setup.sh "$@" ;;
```

…next to `add-repo`, and a corresponding help-text line:

```
  setup [--non-interactive] [--repos=A,B] [--autopickup-interval=N]
                               First-run wizard: env check + repo picker + autopickup.
                               Safe to re-run (idempotent; shows current config).
```

The launcher regen logic (setup.sh → launcher-marker.sh → backup + replace) already handles version-marker mismatch on re-run, so adding the `setup)` case bumps the marker once and the next `./setup.sh` invocation on an existing install cleanly regenerates with a `hydra.bak-<ts>` of the old launcher.

## Test plan

**Existing tests to keep green:**
- `scripts/test-local-config.sh` — pipes `<TMP_MEM>\n\n` through stdin; re-run after wiring must still pass (setup.sh body unchanged).
- self-test case `autopickup-default-on-smoke` — pipes `<<<''` through `./setup.sh`; same guarantee.
- `scripts/validate-state-all.sh` — must pass after adding `state/schemas/setup-complete.schema.json`.

**New tests (smoke, covered by a single shell-level run):**
- `./hydra setup --non-interactive --repos=foo/bar --autopickup-interval=45` in a throwaway tmpdir (with a stub `setup.sh` or actual bash run against an uncommitted test fixture): verifies `state/setup-complete.json` exists, schema-validates, repo entry landed, autopickup interval=45.
- Re-run in the same dir: exits 0 without rewriting fingerprint when no flags change.
- `./hydra setup` with no args on a broken tree (`.hydra.env` missing): proxies to `setup.sh`, which fails loudly with the same "run `./setup.sh` first" message.

Tests live inline in `scripts/test-local-config.sh` (or a sibling `scripts/test-hydra-setup.sh` if that gets unwieldy). Deferred to a follow-up ticket if the wrapper grows — not a blocker for this ticket's acceptance.

**Manual verification (documented in PR body):**
- Fresh clone → `./hydra setup` → interactive → repos + autopickup configured → `./hydra` launches Commander.
- Fresh clone → `./hydra setup --non-interactive --repos=...` → state valid → `./hydra` launches.
- Re-run on configured tree → shows current config → `[q]` → no changes.
- Re-run on configured tree → `[u]` → add one more repo → fingerprint updated.

## Risks / rollback

**Risks:**

- **Launcher heredoc regen.** Adding a `setup)` case bumps the launcher marker. Existing installs that had a pre-#152 `./hydra` will see a "Launcher version mismatch — regenerating" line, save a `hydra.bak-<ts>`, and replace. This is the documented contract in `docs/specs/2026-04-17-launcher-auto-regen.md`. Non-breaking; loud.
- **Idempotent re-run prompt surface.** A paused Commander's operator re-running `./hydra setup` to "just check state" shouldn't accidentally clobber. Mitigated by: default answer is `[q]uit`, all writes tmp+mv+schema-validate, explicit `--non-interactive` with no flags is a no-op.
- **Repo picker validates slugs.** `owner/name` matching `^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$`, trimmed. Invalid input reprompts; doesn't crash.
- **Token exposure.** No tokens or credentials are read, written, or echoed. The wrapper never touches `.env*` or `secrets/`.
- **Parallel execution race.** Two operators running `./hydra setup` against the same tree simultaneously — extremely unlikely, but tmp+mv makes the last writer win without corruption.

**Rollback:** this ticket adds a new wrapper + new schema + one-line launcher edit. Revert = `git revert <sha>`. The existing `./setup.sh` path continues to work for operators who call it directly; the new `./hydra setup` is additive.

## Out of scope (followups)

- Renaming `setup.sh` to `scripts/hydra-setup.sh`. Requires a deprecation window because operators have muscle memory for `./setup.sh`. File as `./hydra setup` stabilizes.
- `./hydra upgrade` (gstack-upgrade equivalent) — separate ticket.
- Deeper connector wiring inside setup. `./hydra connect` should stay the single source of truth; revisit only if operators report the two-command flow is confusing.
- Cloud-mode setup (Docker, Fly, managed agents). Phase 2.
- Using `state/setup-complete.json:version` to warn the operator on hydra-launcher upgrades that setup may need re-running. Data is there; hooking it into the session greeting is a separate UX decision.
