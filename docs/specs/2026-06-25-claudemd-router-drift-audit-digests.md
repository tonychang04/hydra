---
status: draft
date: 2026-06-25
author: hydra worker (ticket #311, #312)
---

# CLAUDE.md router-drift fixes: route `audit_due` + list `digests.json`

## Problem

CLAUDE.md is a thin router: it must point to every shipped behavior so Commander
can reach it. Two router pointers drifted out of sync with the code/state that
already shipped:

- **#311 (P1):** The daily self-audit is fully implemented —
  `scripts/autopickup-tick.sh` section 4d emits `audit_due` (top-level output +
  `audit_json`), `state/schemas/autopickup.schema.json` has `last_audit_run`, and
  `docs/specs/2026-06-07-scheduled-self-audit.md` is `status: accepted` — but the
  CLAUDE.md "Scheduled autopickup" line never routes to it. Every other `*_due`
  tick output (retro/digest) is reachable from the router; only `audit_due` is
  orphaned. A reader of CLAUDE.md cannot tell that the auditor fires
  automatically once/day on the tick (not only on the operator's `audit`
  command).
- **#312:** The `state/` file-map row enumerates seven state files but omits
  `state/digests.json` — the canonical daily-digest source the tick reads
  (`DIGEST_FILE="$STATE_DIR/digests.json"`), which has
  `state/schemas/digests.schema.json`. `autopickup.json` is listed despite the
  same "example-only / runtime-created" status, so the omission is pure drift.

## Goals / non-goals

**Goals:**
- Route `audit_due` from CLAUDE.md: add `audit` to the autopickup tick act-list
  and add the `2026-06-07-scheduled-self-audit.md` spec pointer.
- Convey that the auditor also fires automatically on the daily tick (not only on
  the `audit` command).
- Add `digests.json` to the `state/` file-map enumeration.

**Non-goals:**
- No behavior change. Code, schemas, and the self-audit spec already shipped;
  this only fixes the router text. No new procedures inlined (scope rule).
- No raising the size-guard ceiling; additions stay one-line/minimal.

## Proposed approach

Three minimal, additive router edits to `CLAUDE.md`, each one token / one clause:

1. Autopickup line act-list: `… / merge / retro)` → `… / merge / audit / retro)`;
   append `2026-06-07-scheduled-self-audit.md` to that line's spec list.
2. `audit` command row: append a clause noting it also fires daily on the
   autopickup tick.
3. `state/` row: insert `` `digests.json` `` into the enumeration.

### Alternatives considered

- **Apply the `trivial` label to bypass the spec-presence gate instead of writing
  this spec:** rejected — a self-contained spec is the compounding "why" record
  for the next worker, and avoids depending on Commander to apply a label.
- **Document `audit_due` only in the `audit` command row, not the autopickup
  line:** rejected — the autopickup act-list is the canonical "what the tick acts
  on" list; leaving `audit` out of it keeps the orphan. Both edits are needed.

## Test plan

- `bash scripts/check-claude-md-size.sh` → exit 0, size within the OK band
  (additions keep it well under the 12960-char NOTICE floor).
- `bash scripts/validate-state-all.sh` → OK.
- `bash .github/workflows/scripts/syntax-check.sh` → `syntax-check: OK`
  (this spec carries valid frontmatter).
- Re-grep CLAUDE.md to confirm every added pointer resolves: `audit` present in
  the act-list, `2026-06-07-scheduled-self-audit.md` exists, `digests.json` +
  `digests.schema.json` exist.

## Risks / rollback

- Risk: a pointer typo creates a dangling spec reference (the exact drift class
  this fixes). Mitigated by re-grepping each pointer against a real file.
- Rollback: revert this PR's single CLAUDE.md commit; the router returns to its
  prior (drifted) state with no functional impact.

## Implementation notes

(Fill in after the PR lands.)
