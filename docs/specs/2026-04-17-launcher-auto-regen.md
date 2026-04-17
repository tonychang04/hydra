---
status: draft
date: 2026-04-17
author: hydra worker (ticket #123)
---

# Launcher auto-regen on version mismatch

## Problem

PR #122 shipped critical fixes to `./hydra`'s dispatch logic (new subcommands `ps`, `activity`, `mcp serve`, `mcp register-agent`, a top-level `--help` case that doesn't fall through to Claude Code, etc.). The fixes live inside `setup.sh`'s heredoc — the 100+ line block beginning `cat > hydra <<'EOF'` — because `./hydra` is generated at install time, not committed.

Smoke-test (2026-04-17) on a workspace that had been detached at PR #116 found that `./setup.sh --non-interactive` after a `git pull --ff-only origin main` printed:

> ⚠ ./hydra launcher already exists — leaving as-is

…and left the stale 100-line launcher in place. Users typing `./hydra ps --json` / `./hydra activity` / `./hydra --help` continued to fall through to `claude`, which fabricates plausible-looking output from state files. The fix was sitting on disk the whole time, in `setup.sh`'s heredoc, **invisible**.

The workaround — `rm ./hydra && ./setup.sh --non-interactive` — is fine if you know it. Everyone who doesn't keeps running against a silently stale launcher until they notice the behavior drift by hand. For a framework that ships launcher behavior changes roughly every other PR (PR #64 — CLI subcommands; PR #121 — webhook receiver; PR #122 — dispatch fix), this is a recurring silent-upgrade hazard.

**Root cause:** `setup.sh` at line 303 (current `main` = commit `07138b6`) checks `if [[ -f hydra ]]; then warn "already exists — leaving as-is"`. Idempotent in the trivial sense (second run is a no-op), but wrong in the sense a user wants (second run after an upgrade should reflect what the repo just shipped).

## Goals / non-goals

**Goals:**

1. When `setup.sh` runs and the on-disk `./hydra` launcher's content no longer matches the heredoc `setup.sh` would write, regenerate the launcher, backing up the previous one as `./hydra.bak-<ts>`.
2. When the on-disk launcher matches the heredoc (same content), keep today's behavior: `./hydra launcher already up to date — leaving as-is`. CI idempotency (`setup-interactive-ci-mode:second run on a populated tree is a no-op byte-identical`) must still hold on a clean-upgrade tree (no marker mismatch).
3. Log clearly when regeneration happens: operator sees `⚠ Launcher version mismatch (had <oldhash>, expected <newhash>) — regenerating; previous saved as ./hydra.bak-<ts>`.
4. `hydra-doctor.sh` gains a check that reports whether the installed launcher matches the `setup.sh` it was generated from, with an actionable fix hint (`./setup.sh --non-interactive` to regen).
5. New self-test case `launcher-upgrade-regen` demonstrates the detection path end-to-end: create an old-style launcher, run setup.sh, assert the old was backed up + the new has a marker + the third run is no-op.

**Non-goals:**

- **Alternative markers beyond the heredoc hash.** Not checksum-of-binary-file (hashes the generated output, same as what we're doing). Not semver files committed to the repo (bumping by hand is a discipline everyone forgets). The ticket names both options and picks hash.
- **Operator-configurable `.bak` retention count.** Over many upgrades, `.hydra.bak-*` files accumulate. That's fine until it isn't. Out of scope today; follow-up ticket can add a retention-N policy with the operator override. For now, each regeneration writes exactly one new `.bak` file with a unique timestamped name — operator can `rm ./hydra.bak-*` at leisure.
- **Migration of existing `.bak` files.** None exist today (the convention is new).
- **Recompute marker from a pinned template file separate from `setup.sh`.** Would be cleaner architecturally but widens the blast radius. Sticking to "marker is a function of setup.sh's heredoc body" keeps the one source of truth.
- **Touch the launcher contract that it's not committed to git.** Still generated, still gitignored.

## Proposed approach

### Marker strategy

Add a `# hydra-launcher-version: <hash>` comment as the **first comment line after the shebang** inside the heredoc body. The hash is an 8-hex-character prefix of the SHA-256 of the launcher body text with the marker line itself replaced by a stable placeholder — avoiding the chicken-and-egg of a self-referential hash.

**Why 8 hex:** enough to make collisions on real heredoc evolution practically impossible (2^32 space, single-digit edits per PR = effectively zero collision risk across Hydra's lifetime), short enough to print in an error line without wrapping. Matches the length of `git rev-parse --short`.

**Why SHA-256 over MD5:** same runtime cost, no downside. `sha256sum` is on every supported platform (macOS 10.13+ / every Linux distro).

**Why heredoc body, not setup.sh file hash:** `setup.sh` changes for reasons unrelated to the launcher (prereq detection, prompt text, etc.). Hashing just the heredoc body means the marker only changes when the launcher body changes — minimizing false-positive regenerations. A false-positive regeneration would still be safe (the old file is backed up, the new file is byte-identical except for the marker, operator's data is fine) but chattier in the log than needed.

**Computation:**

1. At setup.sh runtime, write the heredoc body to a temp file, with the marker line set to a fixed placeholder `# hydra-launcher-version: __PLACEHOLDER__`.
2. `marker=$(sed 's/# hydra-launcher-version: .*/# hydra-launcher-version: PLACEHOLDER/' "$tmpfile" | sha256sum | awk '{print $1}' | cut -c1-8)`. This normalizes the marker line to a fixed token before hashing, so the resulting hash is a function of the body **minus** the specific marker value.
3. Replace the placeholder in the temp file: `sed -i.orig "s/__PLACEHOLDER__/$marker/" "$tmpfile"` (or equivalent portable sed). Move into place.
4. On re-run, extract the marker from the existing `./hydra` with `awk '/^# hydra-launcher-version:/ { print $3; exit }' ./hydra`. Compute the expected marker the same way. Compare.

All computation is bash + sha256sum + awk / sed — no Python/Node. Portable across macOS and Linux.

### `.bak` naming convention

Format: `./hydra.bak-YYYYMMDDTHHMMSSZ` (ISO-8601 basic, UTC, colon-free — colons break some Windows-shared filesystems and look ugly in `ls`). Generated with `date -u +%Y%m%dT%H%M%SZ`.

Example: `./hydra.bak-20260417T185302Z`.

Collision-free: second-resolution is enough because `setup.sh` isn't run faster than once per second. If it somehow is (two parallel CI jobs on the same checkout), the second write to the same filename would overwrite the first `.bak` — that's an acceptable failure mode, since both `.bak`s would contain the same stale content.

### Fallback if the marker can't be computed

Three failure modes for marker extraction from an existing launcher:

1. **No marker line at all** (launcher predates this PR — i.e. every operator currently installed). Treat as if marker == `legacy`. Always regenerate on next `setup.sh` run, because `legacy != <current hash>`. This is the **one-time migration moment** — every existing install gets a free upgrade the next time they run setup. Log: `⚠ Launcher has no version marker (pre-#123 install) — regenerating; previous saved as ./hydra.bak-<ts>`.
2. **Marker line present but malformed** (someone hand-edited the launcher and corrupted the marker). Treat as if marker == `corrupt`. Always regenerate. Log: `⚠ Launcher version marker malformed — regenerating; previous saved as ./hydra.bak-<ts>`.
3. **`sha256sum` not on PATH.** Effectively impossible (it's a coreutils primitive) but should be guarded. If the expected-marker computation fails, print `⚠ Cannot compute launcher version (sha256sum missing) — leaving launcher as-is; check PATH and re-run setup` and fall back to today's behavior (don't touch the launcher). This is fail-soft: we never destroy the operator's launcher because of an environment issue.

### `hydra-doctor.sh` check

Add one check under the Scripts category:

```
✓ launcher version matches setup.sh     (cN)     → marker == expected
⚠ launcher version stale                (cN → cN+1) → marker != expected
     fix: ./setup.sh --non-interactive    # regenerates with the new marker
```

Implementation: call the same marker-extraction + marker-computation logic used by `setup.sh`. Factored into a helper function `compute_launcher_marker()` in a new file `scripts/launcher-marker.sh` that both `setup.sh` and `hydra-doctor.sh` source. DRY, one source of truth.

### Self-test: `launcher-upgrade-regen`

New fixture at `self-test/fixtures/launcher-upgrade-regen/run.sh`. Flow:

1. Make tmpdir, rsync the worktree in (same pattern as `launcher-dispatch-smoke`).
2. Write a "pre-#123" launcher by hand: a short shebanged script with NO marker line. `chmod +x`.
3. Run `./setup.sh --non-interactive`. Assert:
   - Exit 0.
   - A file matching `./hydra.bak-*` now exists and is byte-identical to the pre-placed old launcher (`diff` == empty).
   - The fresh `./hydra` contains a `# hydra-launcher-version: <8hexchars>` line.
   - `setup.sh`'s stdout contains the string `Launcher version mismatch` OR `Launcher has no version marker` (the one-time migration path for this fixture).
4. Run `./setup.sh --non-interactive` a second time. Assert:
   - Exit 0.
   - Only one `./hydra.bak-*` file exists (no new `.bak` created because markers now match).
   - Stdout contains `launcher already up to date` or equivalent idempotent marker. Does NOT contain `Launcher version mismatch`.
5. Cleanup: `rm -rf $tmp`.

Added as a `kind: script` case with `requires_claude_cli` + `requires_gh_auth` so it SKIPs cleanly on CI runners without those tools, matching `setup-interactive-ci-mode`.

### Alternatives considered

- **Always regenerate + keep a .bak (Option 3 in ticket).** Rejected. Simpler in theory but noisier in practice — every `setup.sh` run would print a regenerate-log line and create a `.bak` file, even on installs where nothing changed. The `.bak` directory blows up over time, and the signal ("the launcher got upgraded") is drowned in the noise ("we re-wrote the same file again").
- **Checksum-compare the whole launcher file.** Rejected. Requires writing the heredoc to a temp file on every run to compute the expected checksum, which is effectively what we're doing — but without an in-file marker line, there's no way for `hydra-doctor.sh` (or an operator running `sha256sum ./hydra`) to see at a glance which version they're on. The marker line is self-documenting.
- **Semver file (`VERSION-launcher`) bumped manually per PR.** Rejected. Discipline-dependent (every PR author has to remember to bump) and easy to get wrong (merge-conflict resolver picks the wrong side). Hash-based means the PR diff itself updates the marker automatically — no human step.

## Test plan

1. Unit: run `scripts/launcher-marker.sh --self-test` — an inline self-check that hashes a known string and asserts a known output. Catches coreutils drift on exotic platforms.
2. Golden-case: `self-test/run.sh --case=launcher-upgrade-regen`.
3. Regression: full `self-test/run.sh --kind=script`. No prior case may break. Specifically, `setup-interactive-ci-mode:second run on a populated tree is a no-op byte-identical` must still pass — the marker line is deterministic given identical `setup.sh` source, so two fresh runs produce two byte-identical launchers.
4. Doctor: on a tree with a marker-less launcher, `./hydra doctor` emits the `launcher version stale` warning with the `fix:` hint. On a matching tree, it's a green ✓.
5. Manual smoke: in a worktree with a pre-123 launcher, run `./setup.sh --non-interactive`, confirm the `⚠ Launcher has no version marker` line prints, confirm `./hydra --help` now emits Hydra's help (not Claude's).

## Risks / rollback

- **Risk: the marker-extraction awk expression is fragile against manual edits to the launcher.** Handled: malformed markers fall through to the `corrupt` migration path (regenerate + backup).
- **Risk: `.bak` file accumulation over time.** Real but bounded — each file is ~4KB and operators only regenerate when the heredoc body changes. A `rm ./hydra.bak-*` cleanup is a one-liner the operator can run any time. Follow-up ticket to add auto-prune if it becomes a real pain.
- **Risk: `sha256sum` behavior differs on macOS vs Linux.** macOS `shasum -a 256` and Linux `sha256sum` take different arg styles. Mitigated by probing in the helper: try `sha256sum` first, fall back to `shasum -a 256`. Both output `<hash>  <filename>`, same parsing.
- **Risk: the launcher dispatch smoke test (`launcher-dispatch-smoke`) is affected.** That test copies the worktree and runs `setup.sh --non-interactive`, then asserts dispatch. It currently passes because the launcher is fresh. With this change, the launcher is still fresh (the test `rm`s any existing `./hydra` before running setup) — so behavior unchanged. The new regen-on-mismatch path isn't exercised by `launcher-dispatch-smoke`, but IS exercised by `launcher-upgrade-regen`.
- **Rollback:** revert the PR. Backed-up `.bak` files are harmless leftovers operator can `rm` on the next session. Launcher behavior returns to "first-run writes, subsequent runs no-op" — the silent-upgrade hazard returns, but nothing is corrupted.

## Related

- Ticket #117 / PR #122 (launcher dispatch fix — what exposed this hazard)
- Ticket #102 / `docs/specs/2026-04-17-interactive-setup.md` (interactive setup rewrite)
- Ticket #104 / `docs/specs/2026-04-17-doctor-fix-mode.md` (doctor `--fix` walkthrough pattern)
- Ticket #117 / `docs/specs/2026-04-17-launcher-dispatch-smoke.md` (dispatch self-test that this spec coexists with)
