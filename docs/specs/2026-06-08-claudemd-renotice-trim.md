---
status: draft
date: 2026-06-08
author: hydra worker (issue #291)
---

# Re-trim CLAUDE.md below the NOTICE floor (post-#234/#238 re-inflation)

**Ticket:** [#291](https://github.com/tonychang04/hydra/issues/291)
**Tier:** T1 — docs/router trim only. No behavior change, no code, no schema, no rail removed.

## Problem

CLAUDE.md is loaded into every Commander session's context, so every inlined
character is a token tax paid on every turn. The repo guards this with
`scripts/check-claude-md-size.sh` and graduated NOTICE/WARN bands (NOTICE floor =
85% of the 18000 ceiling = 15300 chars).

#277 last trimmed CLAUDE.md to a NOTICE-free baseline, but subsequent routing
additions — #234 (the `commander-live-state` / cloud side-effect label) and #238
(the codex backend router and rate-limit auto-fallback) — re-inflated it to
**16168 / 18000 (89%, NOTICE band)**. The router is back in NOTICE: the size guard
emits an advisory on every session greeting and every preflight, and the next
routing addition pushes it toward WARN.

Per the CLAUDE.md scope rule (`memory/feedback_claudemd_bloat.md`, CLAUDE.md line
5), CLAUDE.md holds **routing tables, hard rails, one-line spec pointers, and the
file-structure map — nothing else**. Full procedures live in `docs/specs/`. The
re-inflation is prose that drifted back into the router; the fix is to relocate
that prose into the specs CLAUDE.md already points to, leaving terse routing.

## Goals

1. Bring CLAUDE.md back **below the NOTICE floor (≤ 15300 chars)** so
   `scripts/check-claude-md-size.sh` exits NOTICE-free (band `OK`).
2. Preserve **every routing row's existence, every hard rail, and every spec
   pointer**. The change is subtractive-in-CLAUDE.md / additive-elsewhere: prose
   relocates, nothing routing-relevant is deleted.
3. Keep `scripts/validate-state-all.sh` exit 0 (the bulk state-schema + size gate).

## Non-goals

- **Removing or renaming any routing row, command, worker type, or safety rail.**
  Existence is preserved; only verbose explanatory prose is compressed/relocated.
- **Changing any Commander behavior.** This is a documentation-density change only.
- **Authoring new specs for behaviors that already have one.** The destination
  specs (`2026-06-01-codex-auto-fallback.md`, `2026-06-01-cloud-side-effect-tracking.md`,
  `2026-06-07-commander-command-reference.md`, etc.) already carry the full prose;
  CLAUDE.md just over-summarized them. No new prose is invented downstream — the
  relocated detail is already documented there.
- **Fixing the pre-existing dangling pointer** `memory/feedback_claudemd_bloat.md`
  (referenced in CLAUDE.md but absent on this branch). Out of scope — touching it
  would risk a rail; left exactly as found.

## Proposed approach

The size guard counts the whole file (`wc -c`), so any prose removed counts. The
heaviest re-inflation is concentrated in a few routing entries that re-explain a
spec inline instead of pointing at it:

1. **Operating-loop step 2 (preflight, codex rate-limit branch).** The full
   "if `fallback_on_rate_limit` … run `set-backend-fallback.sh` … else legacy
   1-hr auto-pause" mechanism is documented in
   `docs/specs/2026-06-01-codex-auto-fallback.md`. Compress the inline mechanism
   to a one-line pointer; keep the preflight item's existence.

2. **Operating-loop step 5 (spawn / backend router).** The `select-worker-backend.sh`
   invocation detail (`--repo-backend …`, "applying any active rate-limit fallback")
   is the same spec's content. Keep the "pick subagent via the backend router"
   instruction + pointer; drop the re-explanation.

3. **Worker-types `worker-codex-implementation` row.** Compress the "OR an active
   Claude-rate-limit fallback" prose to the spec pointer it already carries.

4. **Applying-labels `commander-live-state` paragraph.** The teardown-verify
   semantics live in `docs/specs/2026-06-01-cloud-side-effect-tracking.md`.
   Compress to a one-line routing pointer.

5. **General prose tightening** across the identity, review-gate, watchdog,
   autopickup, memory-hygiene, retro, and session-greeting sections — replacing
   multi-clause restatements of spec content with terse pointers. No row, rail, or
   pointer is dropped; each edit removes redundancy that the linked spec already
   states.

### Alternatives considered

- **Raise the ceiling / NOTICE percentage.** Rejected — the gate exists precisely
  to force procedures into specs; raising it defeats the rail (CLAUDE.md line 5,
  Safety rule "trips mean procedures move to specs, not that the ceiling raises").
- **Delete a whole section.** Rejected — every section is routing-load-bearing.
  Density reduction preserves coverage; deletion would lose a rail.
- **Move prose into a brand-new spec.** Unnecessary — the destination specs already
  exist and already contain the detail; CLAUDE.md merely over-summarized them.

## Test plan

Captured in `validation-contract.md` (worktree-local, not committed to the repo
tree). The acceptance assertions, each backed by a command + exit code:

1. `scripts/check-claude-md-size.sh` exits 0 with band **OK** (size < 15300) —
   NOTICE-free. Verified by parsing its stdout for `✓` / absence of `NOTICE`.
2. `wc -c CLAUDE.md` ≤ 15300.
3. `scripts/validate-state-all.sh` exits 0.
4. No routing lost: every spec pointer (`docs/specs/*.md`) referenced in CLAUDE.md
   still resolves to a real file; every Worker-type row, every Command row, and
   every Safety rail present pre-trim is present post-trim (diff is subtractive
   prose only — `git diff` shows no removed table row / no removed `- Never …`
   rail / no removed `docs/specs/...md` pointer).

## Risks / rollback

- **Risk:** over-trimming removes a load-bearing instruction. *Mitigation:* the
  validation contract's "no routing lost" assertion diffs row/rail/pointer presence;
  the Commander review gate re-reads the diff.
- **Risk:** a relocated detail isn't actually in the destination spec. *Mitigation:*
  the destination specs already document the full mechanism (verified before edit);
  this trim only removes CLAUDE.md's redundant restatement.
- **Rollback:** revert the single CLAUDE.md commit. No state, schema, or behavior
  changed, so revert is a clean no-op for the running system.
