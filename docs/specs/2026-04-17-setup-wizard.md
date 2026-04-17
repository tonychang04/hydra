---
status: draft
date: 2026-04-17
author: hydra worker (ticket #168)
---

# Setup wizard MVP — `./hydra setup`

## Problem

Today a fresh install of Hydra requires an operator to:

1. Clone the repo and run `./setup.sh` (bootstraps `.hydra.env`, creates the
   `./hydra` launcher, copies example state).
2. Manually edit `state/repos.json` to add the repos they want Commander to
   poll — either by hand or by calling `./hydra add-repo` once per repo.
3. Manually edit `state/autopickup.json` to pick an interval.
4. Run `./hydra doctor` to verify the environment.
5. Figure out which connectors (Linear / Slack / supervisor / digest) they
   want and run `./hydra connect <x>` for each.

Each of those steps is individually documented, but there is no single
"I just installed Hydra; walk me through it" command. The predecessor
ticket (#152) attempted a full-blown wizard covering connectors,
idempotent re-runs, and a rotation UI — and timed out three times because
the scope was too large.

This MVP ships the narrowest version that eliminates the manual-edit step
for a first-time operator: env sanity check, a loop to add repos, an
autopickup interval, a hint about connectors, and a fingerprint file so
future Commander code can detect "setup has run at least once".

## Goals / non-goals

**Goals:**

- `./hydra setup` walks a first-time operator through the minimum
  configuration needed to run a spawn loop.
- The wizard delegates environment checks to `./hydra doctor` — no
  duplicated logic.
- Repo entries are appended via `scripts/hydra-add-repo.sh` (already
  battle-tested; atomic writes, schema validation, slug validation).
- Autopickup interval is written to `state/autopickup.json` with the same
  shape the scheduled-autopickup code already expects.
- A `state/setup-complete.json` fingerprint is written on success so a
  future session-greeting hint (punted; see #169) can say "you haven't
  run setup yet" without guessing.
- A non-interactive mode (`--non-interactive --repos=A,B
  --autopickup-interval=N`) for CI and scripted installs.

**Non-goals:**

- Connector sub-wizards. The wizard prints a one-line hint ("run
  `./hydra connect linear` / `slack` / `supervisor` / `digest` to wire
  these") and moves on. Connector wizards already exist and have their
  own specs — duplicating here would blow the scope.
- Idempotent re-run UX. First MVP just overwrites
  `state/setup-complete.json` and appends to `state/repos.json`. Dupes
  in `repos.json` are rejected by `hydra-add-repo.sh` already; the
  wizard surfaces that error and moves on. Full rotation UI is #169.
- Session-greeting hook that nags when setup hasn't run. Filed as #169.
- Migration of existing installs. Operators who already edited
  `state/repos.json` by hand don't need to re-run setup; the wizard
  is additive.

## Proposed approach

One new script — `scripts/hydra-setup.sh` — called by a one-line dispatch
row in the `./hydra` launcher heredoc (`setup.sh`).

**Linear flow (interactive mode):**

1. **Env check** — shell out to `scripts/hydra-doctor.sh --category
   environment` and surface its exit code. If it fails, print "fix env
   issues first, then re-run" and exit non-zero. No retry prompt — the
   operator re-runs the wizard after fixing.
2. **Repos** — print "Enter repos to track (blank line to finish):",
   then loop: read a line, validate `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`,
   shell out to `scripts/hydra-add-repo.sh <slug> --non-interactive
   --trigger assignee`. If the inner script fails (bad slug, dupe
   without `--force`, no local clone found), print the error and
   continue the loop — one bad entry doesn't kill the wizard.
3. **Autopickup interval** — prompt "Autopickup interval in minutes
   (5-120) [30]:", validate integer in range, write
   `state/autopickup.json` with the full minimal shape (see schema
   section below). If the file already exists, overwrite only the
   `interval_min` + `auto_enable_on_session_start` fields via `jq`
   merge; preserve the rest.
4. **Connector hint** — print literal text:

   ```
   Setup complete. Next steps (optional):
     ./hydra connect linear     — poll Linear tickets via MCP
     ./hydra connect slack      — post PR-ready notifications
     ./hydra connect supervisor — escalate worker questions to an upstream agent
     ./hydra connect digest     — push a daily status paragraph
   ```

5. **Fingerprint** — write `state/setup-complete.json`:

   ```json
   {
     "version": 1,
     "completed_at": "<ISO-8601 UTC>",
     "mode": "interactive"    // or "non-interactive"
   }
   ```

**Non-interactive mode:**

`./hydra setup --non-interactive --repos=owner1/repo1,owner2/repo2
--autopickup-interval=30` skips all prompts. Missing flags default: no
repos added if `--repos` omitted (not an error — operator may add later),
interval 30 if omitted. Fingerprint `mode: "non-interactive"`. Useful for
CI smoke tests and scripted installs (Ansible, cloud bootstrap).

**Launcher wire (setup.sh heredoc):**

One new case-block row between `connect)` and `mcp)`:

```bash
setup)        shift; hydra_exec_helper scripts/hydra-setup.sh "$@" ;;
```

This is why `setup.sh` and `./hydra setup` don't collide — `setup.sh`
bootstraps the install (creates `.hydra.env` + launcher); `./hydra setup`
is the post-install wizard that consumes them.

**Schema:**

New `state/schemas/setup-complete.schema.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Hydra setup-complete fingerprint",
  "type": "object",
  "required": ["version", "completed_at", "mode"],
  "properties": {
    "version": { "const": 1 },
    "completed_at": { "type": "string", "format": "date-time" },
    "mode": { "enum": ["interactive", "non-interactive"] }
  },
  "additionalProperties": false
}
```

### Alternatives considered

- **Alternative A — absorb into `./setup.sh`.** `./setup.sh` already
  runs on install. Could tack the wizard onto the end. Rejected: keeps
  install minimal (just bootstrap) and lets operators run the wizard
  again later without re-running install. Also cleaner mental model:
  `setup.sh` is install, `./hydra setup` is configure.

- **Alternative B — full wizard with connector sub-wizards (the #152
  scope).** Rejected — that's exactly what timed out three times. This
  MVP is deliberately narrow so it fits in one worker session with
  per-step commit-and-push cadence.

- **Alternative C — skip the fingerprint.** Future session-greeting
  hint (#169) could just check "is `state/repos.json` empty?". Rejected:
  an operator could have a populated `repos.json` from a manual edit
  but never have run setup; we want a dedicated "setup has run"
  signal.

## Test plan

- **Unit** — `scripts/hydra-setup.sh --help` prints usage, exits 0.
- **Smoke (non-interactive)** — `./hydra setup --non-interactive
  --repos=tonychang04/hydra --autopickup-interval=45` in a fresh
  worktree:
  - exits 0
  - `state/repos.json` contains `tonychang04/hydra`
  - `state/autopickup.json:interval_min == 45`
  - `state/setup-complete.json:mode == "non-interactive"`
- **Validate-state** — after the smoke test, `scripts/validate-state-all.sh`
  still exits 0 (no schema drift).
- **Env failure path** — run the script with `HYDRA_ROOT=/tmp/nonsense`;
  doctor fails; wizard exits non-zero with "fix env issues first".

Golden-case regression (`self-test/`) can be added in a follow-up once
the wizard has shipped once; no pre-existing golden case would have
caught the missing wizard.

## Risks / rollback

- **Risk:** the wizard shells out to `hydra-add-repo.sh` which requires
  a local clone to exist at a detectable path. If the operator hasn't
  cloned the repos yet, every entry fails. **Mitigation:** the error
  message from `hydra-add-repo.sh` is already clear ("local_path does
  not exist"); operators can `git clone` and re-run. Documented in the
  wizard output.
- **Risk:** `state/autopickup.json` already exists from a prior session
  with fields the wizard doesn't know about (e.g., `last_run`,
  `consecutive_rate_limit_hits`). **Mitigation:** the wizard uses
  `jq` merge semantics — only `interval_min` and
  `auto_enable_on_session_start` are overwritten; everything else is
  preserved.
- **Rollback:** revert the merge commit. The wizard is additive — no
  existing script, state file, or CLAUDE.md routing row changes. The
  launcher gains one case-block row; reverting removes it and the
  `./hydra setup` subcommand simply stops resolving.

## Implementation notes

(Fill in after the PR lands.)
