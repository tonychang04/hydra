---
status: draft
date: 2026-04-17
author: hydra worker #73
---

# Cloud commander: clone operator repos on-demand

## Problem

`state/repos.json` ships with `local_path` pointing at `/Users/gary/projects/insforge-repo/<repo>` — paths that exist on the operator's laptop, not inside the Fly.io commander image. When the cloud commander (hydra-commander-tonychang.fly.dev) picks up a ticket and tries to spawn `worker-implementation` on, say, `InsForge/CLI#42`, the worker's worktree setup fails because the repo was never cloned onto the Fly volume.

Without a cloud-side clone path, cloud-primary mode is fictional — the cloud commander can chat about tickets but can't actually touch code.

## Goals / non-goals

**Goals:**

- Before any worker spawn on a cloud commander, ensure the target repo is cloned to a cloud-local path that survives `fly deploy`.
- Keep local-commander behavior unchanged (`local_path` continues to work as today).
- Make the clone step idempotent (first call clones, subsequent calls re-fetch the default branch).
- Ship a script (`scripts/ensure-repo-cloned.sh`) with a clear contract, documented exit codes, and a self-test covering the first-clone / re-fetch path.
- Extend the `state/repos.json` schema additively with two optional fields (`git_url`, `cloud_local_path`) so existing files still validate.
- Document the cloud-mode clone flow in `docs/phase2-vps-runbook.md` so operators know where clones live, how to retry, and how to override.

**Non-goals:**

- Editing `infra/entrypoint.sh` or `infra/fly.toml` in this PR. Ticket #72 is in flight on both files; the entrypoint integration ("on cloud startup, loop over `state/repos.json` and call `ensure-repo-cloned.sh` for each enabled repo") is captured as a post-#72 follow-up in the PR body.
- git LFS support. The script treats LFS objects as regular git — anything LFS-backed will pull the pointer, not the blob. Future ticket.
- Submodules. Neither `--recurse-submodules` on first clone nor `git submodule update --init` on re-fetch. Future ticket.
- SSH-key-based auth. HTTPS-only via the existing `GITHUB_TOKEN`. SSH keys require volume mounts + known-hosts management; not a phase-1 fight.
- Multi-repo organization discovery. Operators still list repos explicitly in `state/repos.json`.
- Changing the worker spawn path to actually call `ensure-repo-cloned.sh` — that's the commander wiring, and it depends on #72 landing so the entrypoint knows when to run. This PR ships the tool; a follow-up wires it.

## Proposed approach

Two additive, independent pieces.

**Piece 1 — `scripts/ensure-repo-cloned.sh`.** Given `<owner>/<repo>`, it reads `state/repos.json` to find the matching repo entry, computes a target path (preferring `cloud_local_path`, falling back to the default `/hydra/data/repos/<owner>/<name>`), and:

- If `<target>/.git` does not exist → `git clone --depth 50 https://x-access-token:${GITHUB_TOKEN}@github.com/<owner>/<repo>.git <target>`.
- If `<target>/.git` already exists → `git -C <target> fetch --depth 50 origin` then `git -C <target> reset --hard origin/<default-branch>` to land back on a clean known-good state. The default branch is detected from `git remote show origin` on the first hit and cached via `git symbolic-ref refs/remotes/origin/HEAD`.

The script is idempotent: running it twice with no intervening change is a fast no-op (a `fetch` + a `reset --hard` to the same SHA). Exit codes are documented in the header and in the PR body:

- `0` — success, working tree at origin/HEAD.
- `1` — bad arguments (no owner/repo given, owner/repo not found in `state/repos.json`, `GITHUB_TOKEN` missing).
- `2` — git operation failed (network, auth, corrupted repo). Non-zero exits always print a one-line reason to stderr.

Auth reads `GITHUB_TOKEN` from the environment, the same token the cloud entrypoint already requires. Public repos work without a token (standard HTTPS clone), so the self-test can exercise the happy path against `octocat/Hello-World` in CI without any secret.

**Piece 2 — schema + example update.** `state/schemas/repos.schema.json` gains two optional properties on each repo entry:

- `git_url` (string) — override the default `https://github.com/<owner>/<name>.git`. Useful for forks, self-hosted GitLab, or custom mirrors.
- `cloud_local_path` (string) — override the default `/hydra/data/repos/<owner>/<name>`.

Neither is required, so every existing `state/repos.json` validates unchanged. `state/repos.example.json` grows a new example entry showing both fields populated with clear comments.

### Alternatives considered

- **Alternative A: eager clone all enabled repos in `entrypoint.sh` at boot.** Out of scope for this PR (ticket #72 is in flight on `entrypoint.sh`); also less resilient — a network blip at boot would crash the commander. Deferred as the follow-up wiring step; this PR ships the tool.
- **Alternative B: do a full clone (no `--depth`) and support LFS/submodules up front.** Rejected for phase 1. Full clones of InsForge repos run into hundreds of MB of history for tickets that touch 3 files; shallow is strictly cheaper and re-fetching doesn't compound storage.
- **Alternative C: SSH keys instead of HTTPS+token.** Rejected. We already have `GITHUB_TOKEN` in the Fly secret store; adding an SSH key path means mounting `~/.ssh` and shipping known-hosts. Not worth it until HTTPS+token stops being enough (e.g., rate limits).
- **Alternative D: put the clone tool inline in `worker-implementation`.** Rejected — workers are ephemeral heads. The clone cache lives on the cloud volume and must outlive any single worker. The script lives on the commander side.

## Test plan

- `self-test/golden-cases.example.json` grows a new `script`-kind case `ensure-repo-cloned-idempotent`. It writes a minimal `state/repos.json` fixture pointing at `octocat/Hello-World` with a temp-dir `cloud_local_path`, sets `HYDRA_CLOUD_MODE=1`, runs `scripts/ensure-repo-cloned.sh octocat/Hello-World`, and asserts:
  1. first run exits 0; `<target>/.git` exists; `<target>/HEAD` points at the default branch.
  2. second run exits 0 and takes the re-fetch path (observable: a sentinel file stays untouched; the working tree's `.git` inode is unchanged — we assert `git rev-parse HEAD` matches between the two runs).
  3. a bogus repo slug (`doesnotexist/doesnotexist`) exits non-zero with a clear stderr message.
- `scripts/validate-state.sh state/repos.example.json` still passes against the updated schema.
- `bash -n scripts/ensure-repo-cloned.sh` clean under the existing syntax CI job.
- `./self-test/run.sh --kind=script` — the new case runs in CI without GitHub auth because `octocat/Hello-World` is public and `git clone` over HTTPS works unauthenticated.

## Risks / rollback

- **Risk: idempotency regression.** If a future change makes the fast-path do a fresh clone every time, the commander wastes bandwidth and time on every spawn. Mitigation: the self-test asserts that `.git/config` survives between runs (same inode).
- **Risk: `git reset --hard` wipes in-flight worker changes.** The worker-implementation subagent works in an isolated worktree (`git worktree add`), so the commander's ensure-clone pass only ever operates on the main checkout — never on an active worker worktree. The script refuses to reset if `git -C <target> rev-parse --is-inside-work-tree && git -C <target> worktree list | wc -l > 1` (there are active worktrees). Log the skip and exit 0 so the commander keeps moving; the worker owns its own tree.
- **Risk: `GITHUB_TOKEN` missing in cloud.** The script exits 1 with a clear message. The entrypoint already hard-fails without `GITHUB_TOKEN`, so in practice this only happens on a misconfigured deploy.
- **Rollback:** revert this PR. The script is new, the schema fields are additive-optional, and no existing code path calls into `ensure-repo-cloned.sh`. Rolling back leaves the repo exactly in its pre-PR state.

## Post-#72 follow-up checklist (integration notes for the next worker)

Once #72 lands and `infra/entrypoint.sh` is free to edit, a follow-up PR should:

1. After the existing `# ---------- 3. Optional non-interactive setup ----------` block in `entrypoint.sh`, add a new step: iterate `state/repos.json:.repos[]`, skip disabled entries, and call `scripts/ensure-repo-cloned.sh "$owner/$name"` for each. Log each outcome. Tolerate individual failures (log + continue) so one bad repo doesn't block the commander boot.
2. Commander's worker-spawn path gains a pre-flight: if `HYDRA_CLOUD_MODE=1`, re-run `scripts/ensure-repo-cloned.sh` before creating the worktree, and use `cloud_local_path` (with the `/hydra/data/repos/<owner>/<name>` default) as the `git worktree add` source instead of `local_path`.
3. Add the `HYDRA_CLOUD_MODE=1` export to the entrypoint once the cloud commander has a canonical way to detect cloud-vs-local (the spec assumes the entrypoint sets it).

This is captured here so it doesn't get lost in the #72 PR review.

## Implementation notes

(Fill in after the PR lands.)
