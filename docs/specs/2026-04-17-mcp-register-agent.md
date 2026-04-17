---
status: draft
date: 2026-04-17
author: hydra worker (#84)
---

# `./hydra mcp register-agent` — generate + hash bearer tokens

## Problem

PR #76 shipped `scripts/hydra-mcp-server.py` + the `./hydra mcp serve` subcommand. PR #72 (now merged as #76) also wired `infra/entrypoint.sh` to launch the server automatically on Fly boot. But the server **refuses to start** if `state/connectors/mcp.json` has no real `authorized_agents[]` entry (the example file's `SHA256:REPLACE_WITH_SHA256_HEX_OF_YOUR_TOKEN` placeholder is explicitly refused — see `self-test/golden-cases.example.json` case `mcp-server-starts`, step "--check refuses placeholder config").

Meaning: cloud commander at `hydra-commander-tonychang.fly.dev` has an MCP surface compiled in, but nothing can talk to it — no operator has a documented recipe for generating a token, hashing it, adding it to the config, and deploying. The infrastructure is live; the first-use friction isn't.

Today an operator would have to:

```bash
TOKEN=$(head -c 32 /dev/urandom | base64)
HASH=$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')
# Then hand-edit state/connectors/mcp.json to append an authorized_agents entry
# with id + token_hash. And remember to print and copy $TOKEN before it scrolls off.
```

This is a security-sensitive ritual (one wrong redirection and the raw token lands in `.bash_history` or a log). It should be one command.

## Goals / non-goals

**Goals:**

- One command: `./hydra mcp register-agent <agent-id>`
- Generate a cryptographically strong 32-byte bearer token using only stdlib tools.
- Compute SHA-256 without the token ever touching disk (no `echo $TOKEN > /tmp/xxx; sha256sum /tmp/xxx`).
- Atomically append a new `authorized_agents[]` entry to `state/connectors/mcp.json` (creating the file from `.example` if missing). Atomic = tempfile in the same directory, `mv` to final path; no intermediate state where the file has a partial entry.
- Print the raw token to stdout **exactly once**, followed by an unmissable warning that this is the only time it will be shown.
- Refuse (exit 1) if an entry with `<agent-id>` already exists — unless `--rotate` is passed, in which case replace only `token_hash` (preserve `scope`, `id`, and any other fields).
- No token in any log line, error message, stderr, or shell command echo.
- Self-test with 5 assertions proving: (a) exit 0, (b) token is ≥43 chars base64, (c) SHA-256 of the printed token matches the hash written to the config, (d) `--rotate` succeeds on second call, (e) non-rotate second call with same id refuses with exit 1.

**Non-goals (explicitly deferred):**

- **Fly-secret companion flag.** The ticket mentions an optional flag that would push the token into `fly secrets set` in one step, for bot-style consumers on Fly. Scope creep risk here is high: it'd introduce a `flyctl` dep on the register-agent path, push the token through another process's env/args (exposure surface), and require a new secret-name flag. Phase 1 ships the token-printing path only; operators copy to `fly secrets set` manually. A follow-up ticket can add `--fly-secret NAME` once the local-only path is battle-tested.
- **Multi-workspace / team tokens.** Out of scope per ticket.
- **Token expiry / rotation policies beyond `--rotate`.** Out of scope per ticket.
- **Web UI for token management.** Out of scope per ticket.
- **Editing `scope`.** `--rotate` never touches `scope` — operators edit the config by hand to widen/narrow permissions. The register-agent command is a creation/rotation tool, not a permission editor.

## Proposed approach

New script: `scripts/hydra-mcp-register-agent.sh` (bash, same pattern as `scripts/hydra-add-repo.sh`). Dispatch in the `./hydra` launcher heredoc inside `setup.sh`: the existing `mcp` case grows a `register-agent)` branch that `exec`s the new script.

**Token generation — bash + openssl/shasum only.** The 32 random bytes come from `/dev/urandom`, base64-encoded:

```bash
token=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
```

This produces ~44 characters of URL-safe-ish base64. We use `tr -d '\n'` because on some platforms the base64 line-wraps at 76 columns. The worker protocol requires the token to be a single line.

**SHA-256 — stdin pipe, never touches disk.** We pipe the token into `shasum -a 256` (macOS) / `sha256sum` (Linux) and capture just the hex digest. No intermediate `/tmp/xxx` write:

```bash
hash=$(printf '%s' "$token" | shasum -a 256 2>/dev/null | awk '{print $1}')
# or sha256sum on Linux — script detects which is available
```

We use `printf '%s'` (not `echo`) because `echo` appends a newline on some shells and the server would hash `token\n` and refuse the match.

**Atomic config update — tmpfile in same dir + mv.** Same pattern as `hydra-add-repo.sh`:

```bash
tmp=$(mktemp "$(dirname "$mcp_file")/mcp.json.XXXXXX")
trap "rm -f '$tmp'" EXIT
jq --arg id "$agent_id" --arg hash "SHA256:$hash" \
  '.authorized_agents = ((.authorized_agents // []) + [{id: $id, token_hash: $hash, scope: ["read"]}])' \
  "$mcp_file" > "$tmp"
mv "$tmp" "$mcp_file"  # atomic on POSIX
```

Tempfile must be in the same directory as the target — `mv` is only atomic within a filesystem. `/tmp` may be on a tmpfs different from `state/connectors/`.

**Duplicate detection.** Before any write, `jq` checks if `.authorized_agents[] | select(.id == $id)` is non-empty. If so: print a clear message to stderr, exit 1, no file changes. With `--rotate`, replace only `token_hash` on the matching entry:

```bash
jq --arg id "$agent_id" --arg hash "SHA256:$hash" \
  '.authorized_agents = (.authorized_agents | map(if .id == $id then .token_hash = $hash else . end))' \
  "$mcp_file" > "$tmp"
```

`--rotate` without an existing entry for `<agent-id>` is also an error (exit 1, clear message) — operators should catch "typo'd the id" cases early.

**Scope default.** The ticket says scope starts read-only. New entries get `["read"]`. Operator widens in the file afterward. This is a deliberate choice: the CLI should not be the place where `"merge"` or `"admin"` scope gets silently granted.

**Token printing.** The raw token goes to stdout as the final step, on its own line, followed by a warning block to stderr (so piping stdout to `fly secrets set` still works):

```
<token on stdout>

⚠ This is the only time this token will be shown.
  Copy it into the consuming agent's config NOW.
  Registered: agent-id=<id> scope=[read]
  Hash stored in state/connectors/mcp.json
```

The warning is stderr because: (a) machine-readable stdout (a consumer may pipe into `fly secrets set …`), (b) the warning should be visible even if stdout is redirected away.

**Config-missing bootstrap.** If `state/connectors/mcp.json` does not exist, create it by copying `state/connectors/mcp.json.example` and then removing the two placeholder `authorized_agents` entries (keep everything else: `server`, `upstream_supervisor`, `audit`). This matches the UX of `hydra-add-repo.sh` bootstrapping from `repos.example.json`.

### Alternatives considered

- **Alternative A: Python script instead of bash.** `secrets.token_urlsafe(32)` + `hashlib.sha256()` is slightly simpler than the bash pipeline. Rejected: the ticket says "stdlib only, no `pip install`". Both bash and Python 3 satisfy that, but bash matches the existing `hydra-*.sh` convention (setup.sh, add-repo.sh, doctor.sh, etc.). The only Python helper in scripts/ is `hydra-mcp-server.py`, which is a long-running daemon — not a one-shot CLI. A bash register-agent keeps operator dependencies minimal: they already have `bash`, `jq`, `head`, `shasum`/`sha256sum`. Python would add nothing.

- **Alternative B: Have the MCP server itself expose a `register-agent` RPC (protected by a bootstrap admin token).** Cleaner in some sense — the server manages its own config. Rejected: introduces chicken-and-egg (need an admin token to bootstrap the first admin token), complicates testing (need a running server), and pushes write access into a long-running network-reachable process. The current model (server reads config, CLI writes config) keeps the server's surface minimal and read-only.

- **Alternative C: Push token to `fly secrets set` by default.** Rejected: Phase 1 lives on a mix of local dev + Fly cloud. Local-only operators don't have `flyctl` and don't need to. The local recipe must work in a `./hydra mcp register-agent <id>` invocation regardless of cloud context. The Fly push is a future optional flag (see Non-goals).

## Test plan

One new self-test golden case `mcp-register-agent` (kind: `script`) that drives `self-test/fixtures/mcp-register-agent/run.sh` through the five ticket-body assertions, plus two static checks (`bash -n`, `--help`):

1. **First-use happy path.** Invoke the script against a tmpdir config (seeded from `mcp.json.example`). Assert:
   - exit 0
   - stdout contains a base64 token ≥43 chars (32 bytes in base64 with no padding is 43; with padding, 44)
   - `printf '%s' $token | shasum -a 256` (or `sha256sum`) matches the `SHA256:<hex>` just written to the config's `authorized_agents[-1].token_hash`
   - the new entry's `scope` is `["read"]` and `id` matches what the caller passed
2. **Duplicate rejected without `--rotate`.** Second call with the same id: exit 1, stderr mentions "already registered" (or similar clear phrase), and the config file on disk is unchanged (byte-for-byte — the tmpfile/mv path must never leave a partial state).
3. **`--rotate` happy path.** Third call `<id> --rotate`: exit 0. The printed token is different from call #1. The updated config still has exactly one entry for `<id>`, its `token_hash` matches the new token, its `scope` field is unchanged from call #1 (`["read"]`).
4. **`--rotate` on unknown id.** Call `--rotate new-id-that-doesnt-exist`: exit 1, no writes.
5. **Missing config auto-bootstrapped.** Pointed at a tmpdir with no `mcp.json`, run `register-agent new-id`: script copies from `mcp.json.example`, clears the placeholder `authorized_agents`, appends the new entry. Exit 0. Config is valid JSON.

Plus `scripts/hydra-mcp-register-agent.sh bash -n` and `--help` shape checks, matching the `mcp-server-starts` case layout.

The tmpdir is created with `mktemp -d` and cleaned up in a `trap`. The fixture **never** writes to the real `state/connectors/mcp.json` — all runs use `HYDRA_MCP_REGISTER_CONFIG` (an env override the script honors, same idea as `HYDRA_MCP_CONFIG` for the server).

**What the test does NOT cover:**

- Interactive token paste flow (the script is non-interactive — no stdin prompts for a token).
- Fly-secret push (out of scope).
- Concurrent invocations on the same config (the `mv` is atomic, but two `jq` reads interleaved before either `mv` can lose one entry; this is a known multi-writer limitation of the tmpfile pattern. Operators don't run register-agent from 2 shells at once. If that assumption breaks later, add `flock`.)

## Risks / rollback

- **Token shows up in `ps` output.** If we did `echo $TOKEN | sha256sum`, the token might appear in `/proc/*/cmdline` on some shells. We use `printf '%s'` which is a bash builtin (no fork, no `/proc` entry for the builtin itself — but the shasum invocation gets only the piped stdin, not the token in argv). Mitigation: we never pass `$token` as a positional argument to any command. The only commands that see it are via stdin. Verified by `grep -n '\$token' scripts/hydra-mcp-register-agent.sh` — every occurrence is a `printf '%s' "$token" | …` or the final `echo` to stdout.

- **Race with the server reading config.** If the server is running when we `mv`, the server might read the old config on one request and the new one on the next. That's fine — the new entry is only useful AFTER the operator copies it into the consumer's config, so the window between `mv` and first use is under human control.

- **Bad jq on an operator's laptop.** The script requires `jq`. `setup.sh` already requires `jq` (warns but doesn't fail today; in practice every Hydra install has it). We hard-fail with a clear message: "jq required for mcp register-agent — brew install jq / apt install jq".

- **Rollback.** Revert the PR. The register-agent path is additive: no existing state or script is mutated beyond the `./hydra` dispatch in `setup.sh`. Removing the new `register-agent)` branch leaves the `mcp serve` branch untouched. Operators who had already registered tokens keep the entries they wrote — the server doesn't care how the config was populated.

## Implementation notes

(Fill in after the PR lands.)
