---
status: implemented
date: 2026-04-17
author: hydra worker (ticket #104)
---

# Actionable `./hydra doctor` diagnostics with `--fix` mode

## Problem

`scripts/hydra-doctor.sh` (ticket #36) already prints a check-by-check pass/warn/fail
with short reasons. That's enough for an experienced operator, but the tool's
target audience is also the brand-new user — someone who just ran `./setup.sh` and
wants to know _what to do about_ a red line, not just that the check failed.

Concrete signal from the operator on ticket #104:

> focus on actually letting people use it even without a lot of background or
> technology.

Today a failure like `✗ GITHUB_TOKEN is not set` is true but non-actionable. The
user sees it and wonders: is that an env var? a file? where do I put the value?
`brew doctor` and `docker system info` have the same shape but _each_ failure is
followed by the exact command to run. `hydra doctor` should match.

The companion ask is a `--fix` mode that walks the user through the fixable
failures interactively: for each ✗ with a safe auto-fix, prompt `y/n/s` — apply
it, skip it, or show the command first and then ask again.

## Goals / non-goals

**Goals:**

- Every fail/warn that hydra-doctor emits gains a `fix_hint` string — a single
  line showing the exact command or instruction to resolve it. The hint is
  printed in yellow right under the ✗ / ⚠ line. No behavior change for ✓.
- A new `--fix` flag walks the operator through each fixable issue interactively.
  Prompt: `[y]es apply · [n]o skip · [s]how command first · [q]uit`.
- `y` on a fix with `auto_fix` actually runs the command. `n` skips. `s` prints
  the command and re-prompts. `q` exits the loop early.
- Fixes that require root, network access, or installing a binary print the
  command and don't auto-run — they're shown as "manual" hints. Consistent with
  the existing `--fix-safe` boundary (#36 spec: "chmod +x / mkdir -p only; never
  edits `state/*.json` contents, `.claude/settings.local.json`, CLAUDE.md,
  policy.md, budget.json, or worker subagents").
- `--fix` implies `--fix-safe` for the auto-remediations the old flag already
  supported (chmod +x, mkdir -p) — so operators don't need both flags.
- Behavior is unchanged when `--fix` is NOT passed. The hint lines are new but
  the pass/warn/fail counts, exit codes, and per-check wording stay identical.
  That's what keeps the existing `hydra-doctor-runs-clean` self-test green
  without modification.
- A new self-test case `doctor-fix-smoke` exercises the hints against a
  deliberately-broken fixture and asserts every ✗ line is followed by a hint.

**Non-goals:**

- **Not rewriting the checks themselves.** Additive only — same checks, same
  categories, same exit codes, just a new field per check plus an interactive
  loop. If a check had no hint today, the worker adds one; no check's logic
  changes.
- No GUI / TUI. ANSI color + a blocking `read` prompt, nothing more.
- No auto-installing binaries. `brew install jq` prints as a hint, never runs.
  Same rule for `gh auth login`, `npm i -g ajv-cli`, `claude mcp add linear`.
- No editing of state-file _contents_ or framework files. The denylist from #36
  still applies. This ticket doesn't widen the safe-fix boundary.
- No replacing `--fix-safe`. `--fix` is `--fix-safe` plus an interactive prompt
  loop. Operators who scripted around `--fix-safe` keep working unchanged.
- No `--yes` / `--fix --auto` mode. The whole point is the human confirms each
  step. We can add batch mode later if operators ask, but defaulting to
  "just run them all" would defeat the guardrail the doctor is meant to be.

## Proposed approach

### 1. `fix_hint` on every emit

Add two optional positional args to `check_warn` and `check_fail`:

```bash
check_fail "<label>" "<reason>" "<fix_hint>" "<auto_fix>"
```

- `fix_hint` — human-readable line printed in yellow right below the ✗. Present
  even when `--fix` is not set, so a non-interactive run is just as actionable.
- `auto_fix` — optional command string. If set AND safe (no `sudo`, no `curl |
  bash`, no `brew install`), `--fix` can execute it after the operator confirms.
  Absent means "manual — print hint, don't offer y/n/s."

Both default to empty, so every existing callsite stays valid. The worker goes
through every `check_fail` and `check_warn` in the script and populates the
`fix_hint` (mandatory for failures). `auto_fix` is set only for the narrow
mkdir/chmod class of fixes the old `--fix-safe` already covered.

### 2. Deferred fix queue

Calls to `check_fail` / `check_warn` record `{label, fix_hint, auto_fix}` into a
bash array `fix_queue`. After all categories run, if `--fix` is set, the script
enters the interactive loop over the queue.

Doing it after (not during) keeps the category output uncluttered. Users see the
full doctor report first, then get the fix walkthrough.

### 3. Interactive loop

```
─── Fix walkthrough ───
[1/4] ⚠ logs/ exists — missing
     fix: mkdir -p /path/to/logs
     [y]es apply · [n]o skip · [s]how · [q]uit  ▸ _
```

`y` → run the command via `bash -c` (captured stdout/stderr) and report
`  → ran. ✓` or `  → failed: <stderr>`. `n` → print `  → skipped.`. `s` →
print the full command as it will be executed and re-prompt. `q` → exit the
loop, print summary, normal exit 0/1 per the original failure count.

Items without `auto_fix` (manual hints) print the hint and move on — no y/n/s
prompt, because there's nothing to run.

### 4. `--fix` flag plumbing

`--fix` implies `--fix-safe` (the auto-remediations the old flag did: chmod +x
scripts, mkdir -p). The difference:

| flag | chmod +x / mkdir -p | prompts before acting |
|---|---|---|
| (none) | no | — |
| `--fix-safe` | yes, silently | no |
| `--fix` | yes, but prompts | yes, y/n/s |

So `--fix-safe` stays the "CI / scripted" path; `--fix` is the "new operator on
a laptop" path.

### 5. Self-test: `doctor-fix-smoke`

New golden case (kind `script`). Steps:

1. Build a deliberately-broken fixture dir with a missing `logs/`, a script
   that's not executable, a malformed `state/active.json`, etc.
2. Run `HYDRA_ROOT=<fixture> NO_COLOR=1 scripts/hydra-doctor.sh` (no `--fix`).
3. Assert stdout has at least one line matching `^  ✗ ` AND every ✗ line is
   followed within 2 lines by a hint matching `fix:` or `run:` or `manual:`.
4. Run `HYDRA_ROOT=<fixture> NO_COLOR=1 scripts/hydra-doctor.sh --fix-safe` and
   assert the missing dir got created + chmod applied (old `--fix-safe` path
   still works).

The fixture lives under `self-test/fixtures/hydra-doctor/broken/` with the
minimum set of files + an explicit README saying "this is broken on purpose —
do not fix."

We do NOT self-test the interactive `--fix` prompt in CI — piping y/n/s into a
blocking `read` is brittle and the value is low. The `--fix-safe` equivalence
covers the non-interactive branch; the interactive branch is thin glue around
the same fix queue. Manual verification on a live broken install is fine.

### Alternatives considered

- **Alt A: Keep hints embedded in the existing `reason` string (no new field).**
  Rejected because the reason field is short — packing "reason AND next
  command" into it gets cluttered and hard to color-code. A separate line also
  makes it trivial for the `doctor-fix-smoke` case to assert "each ✗ has a
  hint" with a simple grep.
- **Alt B: A one-shot `--fix --yes` batch mode that runs every safe fix without
  prompting.** Rejected for now — the whole value of `--fix` is an operator
  confirming each step. Scripted callers should use `--fix-safe` (which already
  bypasses prompts for the narrow chmod/mkdir class). Adding `--fix --yes`
  later is backward-compatible if demand appears.
- **Alt C: Structured JSON output (`--json`) with hints as a machine-readable
  payload.** Rejected as out of scope for this ticket. Separate follow-up if
  an MCP tool needs to consume doctor results programmatically.
- **Alt D: Launch an interactive subagent that walks the user through fixes
  via chat.** Rejected — doctor is shell-only by design (see #36 spec alt C).
  A subagent for the hints would drag a Claude dep into the recovery path, and
  recovery is exactly when you _can't_ assume Claude is working.

## Test plan

- `bash -n scripts/hydra-doctor.sh` — passes (already covered by the Scripts
  category and `hydra-doctor-runs-clean`).
- `./scripts/hydra-doctor.sh --help` — usage includes `--fix`.
- `./scripts/hydra-doctor.sh --fix --category=bogus` — exits 2 (usage error;
  bogus category still rejected).
- `./scripts/hydra-doctor.sh --category=scripts` — unchanged: exits 0, summary
  line present, `hydra-doctor-runs-clean` golden case still passes.
- New `doctor-fix-smoke` case passes — every ✗ on the broken fixture has a
  hint; `--fix-safe` against the fixture creates the missing dir and fixes
  exec bits.
- Manual: run `./scripts/hydra-doctor.sh --fix` on a real broken install,
  answer `y`, `n`, `s`, `q` across a few items, confirm each behaves as
  documented.

## Risks / rollback

- **Risk:** new worker on the script doesn't populate a `fix_hint` on a newly
  added check and the operator sees a bare ✗ again.
  _Mitigation_: the spec sets "every `check_fail` has a non-empty `fix_hint`"
  as a convention; `doctor-fix-smoke` asserts every ✗ on the fixture has a
  hint. A bare ✗ on the fixture fails the self-test. In-repo `grep
  'check_fail.*""' scripts/hydra-doctor.sh` during code review is a belt.
- **Risk:** a future `auto_fix` string creeps beyond the chmod/mkdir boundary
  and doctor starts running risky commands on `y`.
  _Mitigation_: the fix-queue builder rejects any `auto_fix` string that
  contains `sudo`, `curl`, `wget`, `brew`, `apt`, `rm`, `mv`, `>`, or `&&` —
  those are printed as manual hints, not run. Deliberately conservative.
  Widening happens in a dedicated follow-up ticket with a separate spec review.
- **Risk:** interactive `read` prompt misbehaves on non-TTY stdin (CI pipe).
  _Mitigation_: `--fix` refuses to run if `stdin` is not a TTY, printing
  `hydra-doctor: --fix requires an interactive terminal; use --fix-safe
  instead`. Exit 2. Scripted callers stay on `--fix-safe`.
- **Rollback:** revert the `--fix` flag, the fix queue, and the `fix_hint`
  columns. The old `check_fail` / `check_warn` signatures still compile —
  extra positional args are optional. No state or external config is touched.

## Implementation notes

- `doctor-fix-smoke` lives in `self-test/fixtures/hydra-doctor/broken/`. The
  fixture is per-case scratch state — deliberately broken on purpose — and does
  NOT ship a working Hydra install. When the self-test runs it with an
  overridden `HYDRA_ROOT`, doctor sees the breakage and emits expected ✗ lines.
- The interactive prompt uses `read -r -p "  ▸ " ans </dev/tty` so it reads
  from the terminal even if stdout is piped (e.g. into `tee`). This matches
  what `gh auth login` does and feels natural to shell users.
- Quiet mode: in the fix loop, already-passing checks are silent. Only ✗ / ⚠
  rows with a `fix_hint` appear in the walkthrough.
- The `fix_hint` text is conventionally prefixed with `fix:` for runnable
  hints, `run:` for commands the user should run in another shell
  (install-binary class), and `manual:` for instructions like "edit the file
  and add X". The `doctor-fix-smoke` grep just looks for one of those three
  prefixes.
- The spec and self-test case land in the same PR (this ticket), but the hints
  themselves are concentrated in one diff block at the top of the script — the
  `check_fail` / `check_warn` calls stay spread across categories. Reviewers
  can eyeball "every ✗ in category X has a hint" by reading one category at a
  time.
- One pre-existing bug surfaced while authoring the spec: line 435 of the
  current script references `${ext_learnings[@]}` without a default, which
  errors under `set -u` when `$HYDRA_EXTERNAL_MEMORY_DIR` is set but empty of
  learnings. Fixed in-band in this PR because `doctor-fix-smoke` would
  otherwise flake on any CI host that sets the env var. Scoped fix, no
  behavior change beyond "doctor no longer aborts mid-memory-category."
