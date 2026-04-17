---
status: draft
date: 2026-04-17
author: hydra worker (ticket #102)
---

# Interactive zero-jargon `./setup.sh` bootstrap

## Problem

Operator feedback (2026-04-17): "focus on actually letting people use it even without a lot of background or technology."

Today's `./setup.sh` (as of commit `31b1e44` on main) writes `.hydra.env` but assumes the operator knows what `HYDRA_ROOT`, `COMMANDER_ROOT`, and `HYDRA_EXTERNAL_MEMORY_DIR` mean. A stranger arrives, runs setup, and ends up staring at env-var exports they do not recognize. There is exactly one prompt today — "External memory directory... [Enter to accept, or type a different absolute path]" — and the answer is a question about an absolute filesystem path in a concept they have not been introduced to.

Concrete current state (`setup.sh` on main at `31b1e44`):

- Prereq check: fails hard on missing `claude` / `gh`, warns on missing `jq`. No detection of `docker`, `aws`, `flyctl` — those are useful signals even if not hard requirements.
- One prompt, using raw env-var semantics (`$HYDRA_EXTERNAL_MEMORY_DIR`) in the question.
- No visual hierarchy — `say`/`ok`/`warn`/`fail` helpers exist but are underused: the user sees a wall of lines without a clear "what does this tool know about you?" summary at the top.
- No `--non-interactive` / `--ci` flag. `read -r` under closed stdin (`</dev/null`) exits 1 and, under `set -euo pipefail`, halts setup — CI / Docker builds currently have to pipe `<<<''` (an empty-line heredoc) to succeed. That works but is brittle and undocumented.
- No acknowledgement that the user may never have heard the word "Hydra" before, nor any "what to do next" pointer beyond a long block at the bottom.

The goal is to make setup feel like installing an app, not configuring a daemon.

## Goals / non-goals

**Goals:**

1. A stranger who has never seen Hydra can run `./setup.sh`, read the auto-detection block top-down, answer at most 1–2 plain-English questions (each with a sensible default), and end up with a working `.hydra.env` — without ever seeing the strings `HYDRA_ROOT`, `COMMANDER_ROOT`, or `HYDRA_EXTERNAL_MEMORY_DIR` in a question.
2. The tool auto-detects everything it already knows: GitHub auth user (`gh auth status`), Claude Code install (`claude --version`), Docker reachability (`docker info`), AWS credentials (`aws sts get-caller-identity`), and Fly CLI (`flyctl version`). Each detection prints one line with a green ✓ (found + context) or yellow ⚠ (missing + one-sentence "you can enable later" hint) or red ✗ (hard prereq missing + actionable install hint).
3. `--non-interactive` / `--ci` flag (both spellings accepted) skips every prompt and uses every default. The same path triggers automatically when stdin is not a TTY — so CI pipes, `< /dev/null`, `<<<''`, and Docker builds all work without a flag.
4. The `.hydra.env` output **format is unchanged** — same three `export` lines in the same order. Existing users re-running `./setup.sh` see "already exists — leaving as-is" exactly like today. This is a breaking-change gate: a worker must not force a re-setup.
5. Every file `setup.sh` creates today it creates in the new version: `.hydra.env`, `./hydra`, `.claude/settings.local.json`, `state/repos.json`, `state/active.json`, `state/budget-used.json`, `state/memory-citations.json`, `state/autopickup.json`.
6. The ending summary is actionable in plain English. The user sees exactly what to type next to give Hydra its first repo and launch the commander.
7. Existing self-tests keep passing: `scripts/test-local-config.sh` (pipes `<TMP_MEM>\n\n` through stdin) and self-test case `autopickup-default-on-smoke` (pipes `<<<''`). Both already rely on "empty stdin = accept default" — the new non-interactive path must preserve that.

**Non-goals:**

- Full TUI / ncurses / colorful menu widget. Plain-text `read -p` prompts with ANSI color for ✓/⚠/✗ are enough. No dependency on `dialog`, `whiptail`, `gum`, etc.
- Python / Node / any runtime dependency. Stays pure bash + the existing prereqs (`claude`, `gh`, optionally `jq`).
- Language i18n — English only.
- Post-install tutorial ("and here's what you should try first"). A one-line next-step at the end is enough. A real tutorial is a separate ticket.
- Changes to `./hydra add-repo` UX. The same interactive-friendly style could apply there, but scope says no. `setup.sh` only.
- Reordering the `.hydra.env` file. Same three exports, same order.
- Moving or renaming any prereq. `claude` + `gh` stay hard-required; `jq` stays warn-only; `docker` / `aws` / `flyctl` are informational auto-detects that never hard-fail setup.

## Proposed approach

### Target reader

A stranger who has just cloned Hydra. They have a terminal, `git`, and probably `claude` and `gh` already (they got this far). They do NOT know what Hydra's state model looks like. They have 2 minutes of attention.

The script has to respect that attention budget: quick detection roll, one or two small questions with defaults, a visible "✓ done" moment, and a one-line "here's what to type next."

### Flow (happy path, interactive TTY)

```
▸ Hydra setup at /Users/foo/hydra

Checking what's already installed:
  ✓ Claude Code 1.2.3
  ✓ GitHub CLI — signed in as foo
  ✓ Docker reachable
  ⚠ AWS CLI not found — S3-backed memory disabled (you can enable later)
  ⚠ Fly CLI not found — cloud deploy disabled (you can enable later)
  ✓ jq 1.7

Where should Hydra store its memory?
  This is where it keeps what it learns about your repos over time.
  Default: /Users/foo/.hydra/memory
  [Press Enter to accept, or type a different path]: ▮

✓ Memory folder: /Users/foo/.hydra/memory

Writing config files:
  ✓ .claude/settings.local.json
  ✓ state/repos.json
  ✓ state/active.json
  ✓ state/budget-used.json
  ✓ state/memory-citations.json
  ✓ state/autopickup.json
  ✓ .hydra.env
  ✓ ./hydra launcher

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Setup complete.

Next steps:
  1. Tell Hydra about a repo:  ./hydra add-repo <owner>/<repo>
  2. Launch the commander:     ./hydra

Full docs: README.md · USING.md · DEVELOPING.md
```

Colors:
- ✓ green (`\033[32m`)
- ⚠ yellow (`\033[33m`)
- ✗ red (`\033[31m`)
- section headers bold (`\033[1m`)
- dim prose (`\033[2m`) for the one-sentence detection hint
- all reset with `\033[0m`

If stdout is not a TTY (`! -t 1`) or `NO_COLOR` is set, color escapes are disabled across the board — same pattern as `scripts/test-local-config.sh`.

### Flow (non-interactive / CI)

Trigger via any of:
- `./setup.sh --non-interactive`
- `./setup.sh --ci` (alias)
- stdin is not a TTY (auto; `[[ ! -t 0 ]]`)
- `HYDRA_NON_INTERACTIVE=1` env var (belt-and-suspenders for buildkit / agents)

Behavior:
- Same detection block prints (with colors off if stdout is also not a TTY). This is load-bearing for log readability.
- No prompts are ever issued. `read -r` is never called on stdin.
- Default memory directory is used (`$HOME/.hydra/memory`) unless overridden by `HYDRA_EXTERNAL_MEMORY_DIR` env var at setup time. This env-var override is an existing-convention read, not a new feature — it only takes effect when set.
- Hard prereqs (`claude`, `gh`) still hard-fail with the red ✗ + actionable hint. CI without a `claude` binary genuinely cannot run Hydra.
- Exit code: 0 on success, 1 on hard-prereq failure. Same contract as today.

### Auto-detection matrix

| Check | Command | ✓ if | Output on ✓ | Output on ⚠ | Hard fail? |
|---|---|---|---|---|---|
| Claude CLI | `claude --version` | exit 0 + non-empty version | `✓ Claude Code <version>` | n/a (hard fail) | **Yes.** `✗ Claude Code not installed — install from https://claude.com/claude-code` |
| GitHub CLI | `gh --version && gh auth status` | both exit 0 | `✓ GitHub CLI — signed in as <user>` | n/a (hard fail) | **Yes.** Separate hints for "gh missing" vs "not authenticated" |
| Docker | `docker info` | exit 0 within 3s | `✓ Docker reachable` | `⚠ Docker not reachable — cloud-mode worker isolation disabled (you can enable later)` | No |
| AWS | `aws sts get-caller-identity` | exit 0 within 5s | `✓ AWS credentials — account <id>` | `⚠ AWS CLI not found — S3-backed memory disabled (you can enable later)` OR `⚠ AWS credentials not set — S3-backed memory disabled` | No |
| Fly CLI | `flyctl version` OR `fly version` | exit 0 | `✓ Fly CLI <version>` | `⚠ Fly CLI not found — cloud deploy disabled (you can enable later)` | No |
| jq | `jq --version` | exit 0 | `✓ jq <version>` | `⚠ jq not found — some helper scripts will fail (brew install jq)` | No |

All optional detections run with a `timeout` guard (3–5s) so a hung daemon (e.g. docker desktop starting) never freezes setup. If `timeout` is not on PATH (rare on macOS pre-Homebrew), fall back to the plain command — worst case the user sees a 3s pause. No hard failure.

`aws sts get-caller-identity` is the canonical "am I really authenticated?" probe — faster than listing S3 buckets and never hits a real resource. Matches what `scripts/memory-mount.sh` uses.

### Prompts

Exactly one prompt today (memory dir). The ticket also mentions a "Store memory on S3 for durability? (y/N)" example — implementation note: skip that prompt in this PR. S3-backed memory today is gated by the AWS auto-detect and `scripts/memory-mount.sh`; there's no simple "yes" toggle to wire up without expanding scope into `docs/specs/2026-04-16-s3-knowledge-store.md`. The ticket scope is interactive UX, not S3 activation. The AWS-detect yellow ⚠ already tells the user S3 is a future option. Adding a prompt that does nothing would be worse than not having it.

**Prompt 1: memory directory.**

```
Where should Hydra store its memory?
  This is where it keeps what it learns about your repos over time.
  Default: /Users/<USER>/.hydra/memory
  [Press Enter to accept, or type a different path]:
```

Implementation:
- Uses `read -r -p "...: " MEM_INPUT` with the colon-space prompt inline.
- Empty input → accept default.
- Non-absolute input → print yellow ⚠ "That's a relative path — using <expanded absolute>." and `cd`+`pwd` it. (Matches current behavior: `mkdir -p` would work on a relative path too, but we normalize for clarity.)
- `~` expansion: manually expand with `${MEM_INPUT/#\~/$HOME}` since `read` does not expand tildes by default.

### Error paths

| Scenario | Behavior |
|---|---|
| `claude` missing | Red ✗ + install URL. Exit 1. |
| `gh` missing | Red ✗ + `brew install gh`. Exit 1. |
| `gh` unauthenticated | Red ✗ + `gh auth login`. Exit 1. |
| User types a path that can't be `mkdir -p`'d | Red ✗ + "Cannot create <path>: <errno>". Exit 1. |
| User types a path that IS a file (not a dir) | Red ✗ + "<path> exists and is a file, not a directory." Exit 1. |
| `.hydra.env` already exists | Yellow ⚠ "exists — leaving as-is" (same as today). No prompt. |
| Stdin is closed mid-prompt | Impossible because non-interactive mode auto-triggers when `! -t 0`. If somehow reached, `read -r` returns 1 under `set -e` → we trap that and switch to default silently. |
| `CI=true` env (GitHub Actions / GitLab CI) | Auto-non-interactive, same as `--ci`. (Belt-and-suspenders.) |

### `.hydra.env` format contract

Unchanged. Must remain byte-for-byte equivalent in key order, variable names, and quoting:

```
# Hydra environment — sourced by ./hydra launcher.
# Do NOT commit this file (gitignored).
export HYDRA_ROOT="<path>"
export HYDRA_EXTERNAL_MEMORY_DIR="<path>"
export COMMANDER_ROOT="<path>"
```

`scripts/test-local-config.sh` explicitly `grep -qE "^export ${var}="` for each of those three. Any reordering or reformatting would break CI.

### `./hydra` launcher generation

Unchanged. The heredoc that generates `./hydra` inside `setup.sh` is lifted verbatim. `memory/learnings-hydra.md` explicitly calls out that `./hydra` is NOT committed — it's generated. Do not move, do not edit, do not restructure. The launcher has grown real subcommand logic (`./hydra add-repo`, `./hydra mcp serve`, etc.) and a worker who re-flowed it would likely break `./hydra doctor` etc. Keep the heredoc block at the same position in `setup.sh`.

## Test plan

### Automated (reuses existing harness)

1. **`scripts/test-local-config.sh`** already validates in a tmp directory that:
   - `.hydra.env` exists and exports `HYDRA_ROOT`, `HYDRA_EXTERNAL_MEMORY_DIR`, `COMMANDER_ROOT`.
   - `state/repos.json` is valid JSON.
   - `./hydra` launcher exists, is executable, passes `bash -n`.
   - `state/autopickup.json` is valid JSON.

   This continues to pass unchanged — it already pipes a path through stdin, which now triggers both (a) stdin-not-a-TTY auto-non-interactive mode and (b) use-the-piped-value mode. The new script must detect both.

   Tweak: `test-local-config.sh` currently pipes `printf '%s\n\n' "$TMP_MEM" | bash setup.sh`. In auto-non-interactive mode the script doesn't `read`, so the piped value is ignored and `$HOME/.hydra/memory` wins instead of `$TMP_MEM`. That would break the existing test because the path it expects differs. Resolution: the existing script doesn't actually ASSERT that `HYDRA_EXTERNAL_MEMORY_DIR` equals `$TMP_MEM` — it only asserts the export line exists. So the test keeps passing. Verified by reading `test-local-config.sh:164-168` — `check_env_var` only checks `^export ${var}=`, not the value.

   **But** — the piped stdin SHOULD still be honored when given, even in non-interactive mode, to preserve operator intent ("I piped a path, use it"). Implementation: `HYDRA_EXTERNAL_MEMORY_DIR` env var at setup-time overrides the default. `test-local-config.sh` already sets the piped value as `$TMP_MEM`; an optional follow-up is to export it as an env var there too. Out of scope for this PR — the existing test passes either way.

2. **Self-test `autopickup-default-on-smoke`** pipes `<<<''` through stdin. Stdin is still a pipe (not a TTY), so non-interactive mode triggers, the prompt is skipped, defaults are used. The assertions check `state/autopickup.json:auto_enable_on_session_start=true` etc. — seeding logic unchanged. Continues to pass.

3. **New self-test case `setup-interactive-ci-mode`** (added to `self-test/golden-cases.example.json`, kind `script`):
   - Step 1: `bash setup.sh --non-interactive` in a tmp dir with `claude` + `gh` both on PATH → exit 0.
   - Step 2: `.hydra.env` has all three required exports.
   - Step 3: No prompt text leaked to stdout (grep for "Press Enter" → absent).
   - Step 4: `./setup.sh --ci` is accepted as alias.
   - Step 5: `./setup.sh </dev/null` (closed stdin) exits 0 — proves the auto-detect.

   Marked `requires_claude_cli` + `requires_gh_auth` so CI without those tools skips cleanly (same pattern as `autopickup-default-on-smoke`).

### Manual smoke (operator, once PR opens)

- Fresh clone, run `./setup.sh` interactively. Verify the detection block shows accurate ✓ / ⚠ for that machine.
- Re-run `./setup.sh` (everything already exists). Verify it's a no-op with yellow ⚠ "leaving as-is" for each existing artifact — no prompts re-asked.
- Delete `.hydra.env` only, re-run. Verify it regenerates.
- Kill `docker`, re-run. Verify yellow ⚠ on docker detection.

## Risks / rollback

**Risk: existing users' setups break on re-run.**
Mitigation: the "already exists — leaving as-is" branch for every generated file is preserved byte-for-byte. `.hydra.env` content is unchanged. `./hydra` launcher heredoc is unchanged. Re-running setup.sh on an existing install should be a no-op identical to today.

**Risk: CI pipelines break on the stdin-is-closed path.**
Mitigation: `--non-interactive` and the auto-non-interactive-on-closed-stdin detection are covered by the new self-test case + the existing `test-local-config.sh`. Both are in `.github/workflows/ci.yml:self-test`.

**Risk: ANSI escape codes render as garbage in logs where color is force-enabled but the terminal doesn't support it.**
Mitigation: `NO_COLOR=1` disables colors. `[[ -t 1 ]]` auto-disables when stdout is not a TTY (pipes, file redirects, most CI loggers). Matches the pattern already used in `scripts/test-local-config.sh`.

**Risk: adding a detection step that hangs (e.g. a broken `docker daemon` port blocking `docker info`) freezes setup.**
Mitigation: wrap each optional detect in `timeout 3s <cmd>` with a graceful fallback when `timeout` itself is unavailable. Hard-required checks (`claude`, `gh`) also get a timeout to be safe.

**Risk: a worker rewrites the `./hydra` heredoc block.**
Mitigation: already called out in `memory/learnings-hydra.md:2026-04-17 #84` — the heredoc is load-bearing and gitignored. This spec explicitly tells the implementer: do not reflow. The existing heredoc block is copied verbatim.

**Rollback:**
- This PR is one file (`setup.sh`) + a self-test case addition + docs. Reverting the PR restores the terse 2-line prompt.
- No migration, no state files touched, no breaking env format change.
- Operators already on main can `git checkout main -- setup.sh` if they want the old behavior back without a full revert. `.hydra.env` already generated stays unchanged — it's not regenerated on re-run.

## Implementation notes

- Keep the exit-on-error / unset-var / pipefail flags (`set -euo pipefail`). They're load-bearing for every branch.
- Put the mode-detection logic at the top (after `HYDRA_ROOT` resolution), as a single `INTERACTIVE=1` flag that the prompt helper reads. Flip it to 0 on any of: `--non-interactive`, `--ci`, `! -t 0`, `HYDRA_NON_INTERACTIVE=1`, `CI=true`.
- Factor the prompt into one helper: `ask_path "<question prose>" "<default>" "<var name>"`. Non-interactive mode → var = default. Interactive mode → read with `read -r -p`. Empty → default. Tilde-expand + normalize. This is the only prompt today; the helper makes adding more trivial.
- Factor detection into one helper: `detect "<label>" "<probe command>" "<warn message>"` returning 0 on ✓ and 1 on ⚠. Hard-required checks go through a separate `require` helper that hard-fails on miss.
- Echo section headers with `say "<header>"` — already defined.
- Do NOT touch the `./hydra` heredoc, the state-file init loop, or the `.hydra.env` emission format.

## Citations

- Current `setup.sh` structure: `setup.sh` on main at commit `31b1e44`.
- Existing test harness that must keep working: `scripts/test-local-config.sh:127-206` + `self-test/golden-cases.example.json:201-244` (`autopickup-default-on-smoke`).
- Prior learning about generated launcher: `memory/learnings-hydra.md` entry `2026-04-17 #84` — "`./hydra` is NOT committed. The launcher is generated at `./setup.sh` runtime via a `cat > hydra <<'EOF' … EOF` heredoc inside `setup.sh`."
