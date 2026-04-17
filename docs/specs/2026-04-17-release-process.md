---
status: implemented
date: 2026-04-17
author: hydra worker (ticket #28)
---

# Release process: CHANGELOG + VERSION + release.sh

## Problem

Hydra merged 9+ PRs in under an hour without a `CHANGELOG.md`, a `VERSION`
file, or a git tag. For an OSS project whose value proposition is "set it
loose overnight and come back to merged work", the absence of release
hygiene is a real adopter-facing gap:

- Someone cloning `tonychang04/hydra` at two different timestamps has no
  idea what changed between their checkouts.
- Bug reports have no version field — we can't tell whether an operator is
  on a pre- or post-fix commit.
- There's no ceremony around "this is a known-good snapshot" vs. "this is
  midway through a refactor". Tags make that legible.

## Goals / non-goals

**Goals:**

- `VERSION` file at repo root (plain text semver, first value `0.1.0`).
- `CHANGELOG.md` at repo root in Keep-a-Changelog format with categories
  Added / Changed / Fixed / Removed / Security, plus a `## [Unreleased]`
  staging section and per-version sections dated `YYYY-MM-DD`.
- `scripts/release.sh <new-version>` as the single operator-invoked entry
  point for cutting a release: validates the bump, rewrites the CHANGELOG,
  bumps VERSION, runs self-test, commits, tags. **Does not push** — that's
  a deliberate next-step the operator types.
- `--dry-run` flag that shows the diff + would-be tag without touching
  anything on disk.
- Downgrade / equal-version refusal with a clear error (so operators don't
  silently clobber 0.2.0 with 0.1.5 when they mistyped).
- `./hydra --version` reads and prints the VERSION file.
- README badge for the latest release tag.
- PR template checkbox: "Affects CHANGELOG [Unreleased]?" so contributors
  remember to log their change in the staging section.

**Non-goals:**

- Auto-generating CHANGELOG bullets from commit history. Too lossy; PR
  authors curate their own entries when they land.
- Auto-tagging on every merge. Tags are deliberate; `release.sh` is
  operator-invoked. This is also why the script deliberately stops at
  `git tag` and prints the `git push && git push --tags` as next steps.
- A release-notes GitHub Action (out of scope for Phase 1; revisit once CI
  ships — ticket #16).
- Pre-releases (`0.2.0-rc.1`). The script's semver regex is intentionally
  strict MAJOR.MINOR.PATCH for now; we'll loosen it when we need it.

## Proposed approach

The whole release surface is one script (`scripts/release.sh`) plus two
text files (`VERSION`, `CHANGELOG.md`). No release daemon, no GitHub Action
dependency, no opinion about where tags get pushed — the script stops
short of `git push` on purpose so the operator confirms.

Release-cut sequence (mirrored in `release.sh`):

1. Validate that `<new-version>` is strict semver and **strictly greater
   than** the current `VERSION`. Downgrade or equal is a hard error —
   prevents mistyped bumps from silently clobbering history.
2. Rewrite `CHANGELOG.md`: rename the first `## [Unreleased]` line to
   `## [<new-version>] — YYYY-MM-DD`, insert a fresh empty
   `## [Unreleased]` at the top, and rewrite the compare-link footer so
   `[Unreleased]` now points at `v<new-version>...HEAD` and a new
   `[<new-version>]: .../releases/tag/v<new-version>` line appears.
3. Write the new value to `VERSION`.
4. Run `./self-test/run.sh --kind=script` — if the script-kind golden
   cases are red, refuse to tag. (We skip Claude-auth-requiring kinds on
   purpose; release cut shouldn't hard-depend on a live LLM session.)
5. `git add VERSION CHANGELOG.md` + `git commit -m "Release v<version>"`
   + `git tag -a v<version> -m "Release v<version>"`.
6. Print the two manual next-step commands: `git push && git push --tags`.

### Release cadence

No fixed cadence in Phase 1. Cut a release when a cluster of merged PRs
represents a coherent step forward — typically when ≥3 merged PRs have
landed since the last tag, or any single merged PR marked as T2/T3 (those
warrant explicit version demarcation). This is a guideline, not a rule;
operators can tag whenever.

### Versioning strategy

Straight semver. In Phase 1 everything is "alpha", so MINOR bumps are
allowed to contain breaking-looking commander-prompt changes; we'll start
caring about true semver semantics when we hit `1.0.0`. Until then:

- `0.MINOR.0` — meaningful new workflow, new worker type, new memory
  subsystem, new MCP integration.
- `0.x.PATCH` — bugfix, doc fix, trivial plumbing, test additions.

### Alternatives considered

- **Use `git-chglog` / `release-please` / `goreleaser` / similar.**
  Every one of these brings a YAML config, a GitHub App install, or a
  binary the operator has to have. The hard rule on this ticket was
  "bash + jq only, nothing else". Also: release-please auto-PRs every
  merge, and the whole point is that release cuts are deliberate.

- **Store version in a manifest file (e.g. `package.json`).** Hydra has
  no package manifest — it's a shell + prompts project. A plain
  `VERSION` file is grep-friendly, editor-friendly, and matches what
  e.g. `curl`, `openssh`, and other bash-shaped projects do.

- **Auto-generate CHANGELOG from PR titles + labels.** Lossy; PR titles
  get written in a hurry and don't always capture the user-facing
  change. A hand-curated `## [Unreleased]` that PR authors update via
  the template checkbox keeps the quality bar higher for near-zero
  added friction.

## Test plan

Covered by the `release-script-smoke` golden case in
`self-test/fixtures/release/` + `self-test/golden-cases.example.json`:

- `bash -n scripts/release.sh` — syntax clean.
- `./scripts/release.sh --dry-run 0.2.0` (against a fixture VERSION +
  CHANGELOG) prints the diff and exits 0 without mutating files.
- `./scripts/release.sh 0.0.9` (downgrade) exits non-zero with a clear
  error.
- `./scripts/release.sh bogus` (non-semver) exits non-zero with a clear
  error.
- `./scripts/release.sh 0.1.0` (equal to current) exits non-zero.

Additionally, manual verification for this first release:

- `cat VERSION` reads `0.1.0`.
- `./hydra --version` (after `./setup.sh` regenerates the launcher)
  prints `0.1.0`.
- README renders the version badge.

## Risks / rollback

- **A release.sh bug corrupts CHANGELOG.md.** The script writes via a
  tmpfile and an atomic `mv`, so a mid-script failure leaves the
  existing CHANGELOG intact. If the post-`mv` state is wrong, revert is
  `git checkout -- CHANGELOG.md VERSION` before commit, or
  `git reset --hard HEAD~1` + `git tag -d v<version>` after commit (tag
  is local-only until operator pushes — another reason the script
  doesn't push).
- **Operator releases too frequently, CHANGELOG becomes noisy.** Low
  downside; we'd rather have a verbose history than no history. If it
  becomes a problem, fold the ≥3-PR-cluster guideline into a hard rule
  later.
- **Semver regex is too strict.** If an operator wants pre-releases
  (`0.2.0-rc.1`) we'll extend the regex; no rollback needed, just a
  follow-up commit to the script.

## Implementation notes

- The launcher (`./hydra`) is generated by `setup.sh` and is gitignored,
  so `--version` support lives in the here-doc inside `setup.sh` rather
  than in a committed launcher file. Operators who ran `setup.sh` before
  this ticket landed will need to delete `./hydra` and re-run `setup.sh`
  to pick up `--version`.
- `release.sh` runs `self-test/run.sh --kind=script` rather than the
  full suite, because worker-implementation / commander-* kinds require
  a live Claude session and we don't want release-cut blocked on LLM
  availability. The script-kind cases cover the plumbing
  (parse-citations, validate-learning-entry, linear-poll, s3 roundtrip,
  self-test-runner-meta, release-script-smoke) which is what actually
  regresses during refactors.
- `REPO_SLUG` is hardcoded to `tonychang04/hydra` in `release.sh`. If
  the repo is ever forked for real operational use, that's a one-line
  edit. A previous draft threaded it through env, but the complexity
  wasn't worth it for a single-operator tool.
