---
status: implemented
date: 2026-04-17
author: hydra worker (ticket #124)
---

# `./hydra pair-agent` — one-command agent pairing

## Problem

Getting an external MCP-speaking agent (Claude Code on a laptop, a Cursor project, an OpenClaw workflow, a Codex-CLI run) wired up to a Hydra Commander today takes roughly six manual steps:

1. Deploy cloud Commander (ticket #119).
2. `./hydra mcp register-agent <id>` to generate a bearer (ticket #92 handles this primitive).
3. Copy the raw bearer somewhere safe — it's printed once.
4. Figure out the MCP URL (local `http://127.0.0.1:8765/mcp`? Fly app at `https://<app>.fly.dev/mcp`? stdio?).
5. Configure the consuming agent's MCP client with the right invocation + auth header (every client has a different config grammar).
6. Troubleshoot the inevitable failure on step 4 or 5 (401? 404? timeout? wrong transport?).

Step 5 is where the ergonomics cliff is — every MCP client has a different config grammar, the operator typically Googles "how do I add an HTTP MCP server to Cursor?", and the raw bearer lives in shell history or a half-open browser tab while they fiddle. The ticket calls out that this is the single highest-friction moment in the whole onboarding path.

gstack's own `/pair-agent` skill solves an analogous problem (handing browser control to a remote agent via a one-line setup-key print). The pattern transfers: one command, ready-to-paste recipes for the handful of clients the operator actually uses, automatic sanity check so "does it work?" is answered before the operator leaves the terminal.

## Goals / non-goals

**Goals:**

- `./hydra pair-agent <agent-id>` — one command. Generates bearer, prints recipes, runs sanity check.
- Recipes for at least four clients (ticket acceptance): **Claude Code**, **Cursor** (mcpServers JSON), **OpenClaw / Codex-CLI** (generic MCP), **raw curl** one-liner.
- Automatically detect cloud (Fly app running) vs local MCP URL. If ambiguous (both look plausible), print **both** recipes; don't guess.
- Run the curl sanity check at the end — call `hydra.get_status` with the fresh bearer; print ✓ on success, specific actionable error on failure (401 = bearer mismatch, 404 = MCP server not running, connect-refused = wrong URL / not deployed, timeout = firewall / wrong URL).
- `--scope <read|spawn|merge|admin>` — wrap the ticket #92 primitive's scope arg. Default `read,spawn` (minimum viable: the agent can read status + trigger workers, but not merge or pause).
- `--editor <claude-code|cursor|openclaw|generic>` — if set, print only that recipe (skip the others — clean copy-paste for single-client onboarding).
- `--dry-run` — print the recipes with `<token-would-go-here>` placeholder, **no bearer generation**, **no curl call**, **no mutation** of `state/connectors/mcp.json`. Used by the self-test fixture to assert recipe shape without touching real state.
- Reuse `scripts/hydra-mcp-register-agent.sh` as-is for bearer generation — no duplication of the security-critical primitive. This script wraps it, runs extra recipe/sanity logic, never reimplements the hash-write path.
- Security invariants (no bearer leakage):
  - Raw bearer goes to stdout **exactly once** — the consolidated "copy this now" block at the end of the run, with a bold yellow warning above.
  - Bearer is never written to any file (the register-agent primitive only stores the hash in `mcp.json`).
  - Bearer is never emitted in a log line, error message, or `curl -v` output — the sanity check uses `curl -sS` (no verbose) and scrubs headers from error output.
  - `--dry-run` never runs `register-agent` and never prints a real token.

**Non-goals:**

- **Not an editor-opening flow.** v1 prints to stdout; `$EDITOR` integration (one of the ticket's "optional" items) is a follow-up if friction persists.
- **Not a multi-agent bulk pair.** One agent per invocation. For multiple agents, run the command multiple times.
- **Not a revoke or rotate flow.** `./hydra mcp register-agent <id> --rotate` (ticket #92) already covers rotation. `pair-agent` defaults to the non-rotate path; passing an existing agent-id without `--rotate` will fail at the register-agent layer with the existing "already registered" error — intentional.
- **Does not modify `scripts/hydra-mcp-register-agent.sh`.** The primitive is the security-audited surface; this wrapper must not change its behavior.
- **Does not touch `infra/fly.toml` / `infra/entrypoint.sh`.** Deployment shape is out of scope; we only *detect* what's running.
- **Does not change `CLAUDE.md` or Commander behavior.** This is a pure operator-side ergonomic command.
- **No Windows support.** bash + jq + curl + python3 (all four are already Hydra's baseline). Windows operators are expected to run under WSL, same as every other `./hydra` subcommand.

## Proposed approach

One new helper script + one new launcher dispatch line + one self-test.

### `scripts/hydra-pair-agent.sh`

Leaf bash script matching the `hydra-mcp-register-agent.sh` pattern (`set -euo pipefail`, `usage()`, stderr colors gated on `NO_COLOR`, exits 0/1/2).

Flow:

1. **Parse args.** `<agent-id>` (required, positional), `--scope <list>` (default `read,spawn`; comma-separated; validated against the set `{read, spawn, merge, admin}`), `--editor <name>` (optional; filters recipe output), `--dry-run` (no mutation). Reuses the agent-id validator regex from the primitive.
2. **Detect URL.**
   - **Local**: `127.0.0.1:<port>/mcp` where port comes from `state/connectors/mcp.json:server.http_port` (default 8765). Only considered "running" if a TCP connect to that port succeeds in <500ms.
   - **Cloud**: if `flyctl` or `fly` is on PATH and `fly status --app <app-from-fly.toml>` succeeds with a Machine in `started` state, the cloud URL is `https://<app>.fly.dev/mcp`. App name read from `infra/fly.toml:app`.
   - If both detect: print both recipes. Label clearly so the operator picks the right one per context (laptop dev vs cloud commander).
   - If neither detects: print recipes with the default local URL and a yellow warning — "No local server detected and no Fly app reachable. Start one with `./hydra mcp serve` or `fly deploy` before running the sanity check."
3. **Generate bearer.** Unless `--dry-run`, invoke `scripts/hydra-mcp-register-agent.sh <agent-id>` and capture stdout (the raw token — stderr has the confirmation banner). The primitive already fails loudly on duplicate agent-id without `--rotate`; we surface that error verbatim.
   - After bearer generation, if the caller requested a scope other than the primitive's default (`["read"]`), edit `state/connectors/mcp.json` to widen the scope field on the new entry. Done via `jq` + atomic tmp+mv — same pattern as the primitive itself.
4. **Emit recipes.** Each recipe is a labeled block printed to stdout. Each block is self-contained copy-pasteable (no backtick fencing — just literal text the operator can select). Block headers use the same visual pattern as `./hydra doctor` status lines so the output looks familiar.
   - **Claude Code**: `claude mcp add hydra --url <url> --transport http --header "Authorization: Bearer <token>"`. The `--header` flag matches current `claude-code` CLI grammar (verified against `claude mcp add --help` at time of writing; if an operator's client predates the `--header` flag, the generic JSON config falls back to stdio-style).
   - **Cursor / mcpServers JSON**: fully-formed JSON snippet ready to drop into `~/.cursor/mcp.json` (or the user's `mcpServers` block). Includes a `headers` object with the bearer, and an `env` reference showing how to move the bearer to an env var for long-term use.
   - **OpenClaw / Codex-CLI**: printed as a generic MCP config — URL, transport, bearer — since these clients' grammar isn't stable across versions. A short annotation points at each client's most recent docs and notes "replace the header flag with your client's equivalent."
   - **Raw curl**: one-liner calling `hydra.get_status` with the bearer. Serves double duty: (a) a manual sanity check the operator can re-run later, (b) the command the sanity-check step runs internally.
5. **Sanity check.** Unless `--dry-run`, invoke the raw-curl recipe (with real token) against the detected URL. Parse the response:
   - HTTP 200 + valid `{"jsonrpc":"2.0","result":{...}}` body → print green ✓ with the agent-id and URL.
   - HTTP 401 → "bearer mismatch — the server doesn't recognize this token. Did you run this against the right URL / deployment?"
   - HTTP 404 → "MCP server not running — run `./hydra mcp serve` locally, or `fly deploy` for cloud."
   - Connect-refused → "nothing listening at <url> — start the server or check the URL."
   - Timeout (5s) → "no response within 5s — wrong URL, firewall, or the server is unreachable."
   - Other HTTP 5xx → server ran but errored; print the status line.
   - In every failure case, exit the script with code 3 (distinct from register-agent's 1) so CI / wrappers can distinguish "bearer generation failed" from "sanity check failed."
6. **Final bearer block.** Print the bold yellow warning banner, then the literal token on its own line (last thing on stdout), then a final status line on stderr. This ordering means `./hydra pair-agent <id> | tail -n1` yields the bearer — useful for chaining.

### Launcher dispatch

Single line addition to `setup.sh`'s generated `./hydra` template, inside the existing `case "${1:-}"` dispatch:

```
pair-agent) shift; hydra_exec_helper scripts/hydra-pair-agent.sh "$@" ;;
```

Matches the exact pattern used by `doctor`, `add-repo`, `status`, etc. Worker #123 is editing the same heredoc for version-marker logic; adding a single dispatch case is conflict-resolver-safe (additive, non-overlapping line) — see "Risks / rollback" below.

### Self-test

One new script-kind case in `self-test/golden-cases.example.json` named `pair-agent-dry-run`. Exercises:

1. Script parses (`bash -n`).
2. `--help` exits 0 with usage banner.
3. `--dry-run <agent-id>` exits 0, prints all four recipe block headers (Claude Code, Cursor, OpenClaw, raw curl), and leaks no real bearer (asserts the placeholder `<token-would-go-here>` is present and no 43+ char base64-shaped string that matches token entropy is on stdout).
4. Dispatch wiring: `grep -q 'pair-agent) shift; hydra_exec_helper scripts/hydra-pair-agent.sh' setup.sh`.

The dry-run path is fully offline — no register-agent call, no network, no state mutation. CI-safe.

### Alternatives considered

- **Alternative A: Generate the config JSON files directly in the operator's agent config dirs (e.g. patch `~/.cursor/mcp.json` in-place).** Rejected — touches out-of-worktree files, platform-specific paths, and no way to dry-run safely. Print-and-copy is the universal lowest-common-denominator.
- **Alternative B: Fork `scripts/hydra-mcp-register-agent.sh` and fold pair-agent into it.** Rejected — the primitive is security-audited and narrowly scoped. Wrapping keeps responsibilities separate: primitive owns bearer; wrapper owns UX.
- **Alternative C: Python instead of bash.** Rejected — matches the "bash + jq + python3 only where needed" surface area of the rest of `scripts/`. Python is used only for the server + supervisor-escalate client where structured JSON + network I/O + CLI arg parsing genuinely benefit. This script is mostly orchestration + text output; bash is the right tool.
- **Alternative D: Single "universal" JSON config file the operator points every client at.** Rejected — there is no universal MCP client config format. Different clients have different config grammars. Per-client recipes are the honest answer.
- **Alternative E: Run the sanity check via `python3 -c '...'` hitting the JSON-RPC endpoint natively.** Rejected for v1 — `curl` is already universally available, we already print the curl recipe for the operator's manual use, and running the same command the operator sees gives identical error surface. Future hardening could add a structured-response parse via jq once the curl is wired.

## Test plan

- `bash -n scripts/hydra-pair-agent.sh` — syntax clean.
- `scripts/hydra-pair-agent.sh --help` exits 0, usage banner printed.
- `scripts/hydra-pair-agent.sh` with no args exits 2 + `missing required <agent-id>` message.
- `scripts/hydra-pair-agent.sh --dry-run pair-test-1` exits 0; stdout contains each of the four block headers ("Claude Code:", "Cursor / mcpServers JSON:", "OpenClaw / Codex-CLI / generic MCP:", "Raw curl:"); stdout contains the placeholder `<token-would-go-here>`; no register-agent call happened (verify `state/connectors/mcp.json` unchanged).
- `scripts/hydra-pair-agent.sh --dry-run --editor claude-code pair-test-2` prints only the Claude Code block, not the others.
- `scripts/hydra-pair-agent.sh --dry-run --scope admin pair-test-3` prints recipes that reference the admin scope (documentation / comment, not a real token).
- Integration smoke (covered by self-test fixture): dispatch wiring present in `setup.sh`.
- Ensures self-test file remains valid JSON (`jq . self-test/golden-cases.example.json`).

Live server test (manual, not in CI):
- Start `./hydra mcp serve` in one terminal.
- In another: `./hydra pair-agent live-test`. Expect ✓ with HTTP 200 and the reported URL.
- Stop the server; re-run: expect ✗ with "MCP server not running" hint.

## Risks / rollback

- **Risk: bearer leaks into stderr / logs / curl output.** Mitigation: the script never passes the token as a positional argument (always via `-H "Authorization: Bearer $TOKEN"` which is `argv[0]`-visible on `ps`, but only inside the wrapper — curl exits before its argv matters — and we avoid `curl -v`). The token is never `echo`'d to any file, and the "final bearer" banner is emitted as the last stdout line so `2>/dev/null` pipes still surface it to the operator.
- **Risk: merge conflict with worker #123's `setup.sh` heredoc edit.** Mitigation: the two changes touch disjoint lines — worker #123 adds version-marker logic (a new comment block or a new path inside the launcher); this adds one case arm inside the existing subcommand dispatch. A trivial three-way merge resolves cleanly. If conflict-resolver flags it, both changes can land by taking both sides.
- **Risk: `flyctl` on the operator's PATH points at a different app than the one they're pairing.** Mitigation: we read the app name from `infra/fly.toml`, not from `flyctl`'s default. If the operator has a non-standard fly.toml or is deploying to a custom app, the `fly status --app <name>` call fails cleanly and we fall through to the "no cloud detected" branch.
- **Risk: sanity-check false negative when the MCP server is alive but audit logging is misconfigured.** The `hydra.get_status` tool is read-scope; any bearer with the default `read` scope can call it. If audit logging has a write failure, the server may still return the 200 — we consider that a success. Out-of-scope for this command; the health check is orthogonal.
- **Risk: operator runs this against a cloud Commander with a stale / rotated bearer from a previous session.** Won't happen — this command always generates a fresh bearer before the sanity check. Rotation is explicit via `--rotate` on the primitive, which we don't wrap.
- **Rollback:** delete `scripts/hydra-pair-agent.sh`, revert the one-line dispatch in `setup.sh`, remove the `pair-agent-dry-run` self-test case. No persistent state writes beyond the new entry in `state/connectors/mcp.json` (that entry is cleaned up by rotating / removing the agent via the primitive, same as any other agent). Clean revert.

## Implementation notes

- Recipe block printing uses `printf` (not heredocs) for consistent stdout streaming and to keep the literal `<token>` placeholder free of shell-substitution surprises in `--dry-run`.
- Color output gated on `NO_COLOR` + `-t 1` (stderr) — matches every other `scripts/hydra-*.sh`.
- The URL-detection TCP-probe uses `bash`'s built-in `/dev/tcp/<host>/<port>` redirect with a 500ms timeout (via `timeout` if present, else best-effort). No external dep.
- The sanity-check curl timeout is 5 seconds total. The register-agent primitive is kept synchronous inside the main script — no background spawn — so Ctrl-C interrupts cleanly. End-to-end runtime on a warm local server is ~300ms.
- The script refuses to run if the `register-agent` primitive isn't executable (symlink broken, permissions wrong) — exits 1 with a specific error pointing at the primitive's path.
