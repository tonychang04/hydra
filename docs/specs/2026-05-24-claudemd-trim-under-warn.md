---
title: Trim CLAUDE.md back under the WARN band — relocate prose to existing specs
date: 2026-05-24
ticket: 231
pillar: P1 (keeps the spawn loop unblocked)
status: implemented
---

# Trim CLAUDE.md back under the WARN band

**Ticket:** [#231](https://github.com/tonychang04/hydra/issues/231)

## Problem

CLAUDE.md is loaded into every Commander session. The character budget
(`scripts/check-claude-md-size.sh`, ceiling 18000) is a **hard preflight gate** —
at 18000 chars all spawns block. After the recent run of capstone tickets (the
autopickup step-1.8 skill-promotion hook, PR Shepherd, the auto-rescue-on-completion
watchdog branch, the anti-stall discipline pointer) several H2 sections had grown
from one-line spec pointers back into multi-sentence prose. The file sat at
~16900/18000 (93%) — above the 90% headroom the operator wants — with the WARN
floor (95% / 17100) one routing addition away.

The CLAUDE.md scope rule (top of the file + `memory/feedback_claudemd_bloat.md`)
is explicit: CLAUDE.md holds **routing tables, hard rails, and one-line spec
pointers only**. Expanded procedure prose belongs in `docs/specs/`. The procedures
that had re-bloated were already documented in their specs — the CLAUDE.md copies
were duplication, not unique content.

## Goals

- Get CLAUDE.md back into the NOTICE band (target <90% / ~16200, ideally lower for
  headroom) so the spawn-loop preflight gate stays unblocked.
- Lose **no** information: any unique phrasing trimmed from CLAUDE.md is already
  present in (or is moved into) the spec the pointer references.

## Non-goals

- Do **not** alter the "Safety rules (hard)" section, the "Applying labels" REST
  rule, or any other hard rail. These are load-bearing rails, not prose.
- Do not change behavior. This is a documentation/size change only; the scripts,
  specs, and procedures referenced are unchanged.
- Do not raise the ceiling. The fix is moving prose out, never bumping `--max`.

## Proposed approach

Collapse the re-bloated sections to routing + one-line pointers, keeping every
spec reference so the pointers still resolve:

| Section | Before | After |
|---|---|---|
| Worker timeout watchdog | full `--probe` verdict prose + completion-probe paragraph | one-line trigger + verdict→action summary + spec pointer list (incl. completion-probe + anti-stall specs) |
| Scheduled autopickup | inline "Each tick:" step-by-step (preflight → retro → digest → skill-promotion → pick) | one-line tick summary + spec pointers (steps live in the scheduled-autopickup + skill-promotion specs) |
| Memory hygiene | full per-ticket + every-10-tickets + tooling prose | routing summary + canonical-tooling pointer + spec list |
| Commander review gate / PR Shepherd | expanded PR Shepherd classification paragraph | one-line PR Shepherd pointer |
| Escalate to supervisor | full do/don't bullet prose | tightened do/don't one-liners + spec list |
| Session greeting | verbose health one-liner prose | tightened one-liners + spec pointers |

All relocated detail already exists in the referenced specs:

- step-1.8 skill-promotion tick → `docs/specs/2026-04-17-skill-promotion-automation.md`
  (§ "Autopickup hook") + `docs/specs/2026-04-16-scheduled-autopickup.md` (step 4).
- watchdog probe verdicts + completion-probe →
  `docs/specs/2026-04-16-worker-timeout-watchdog.md`,
  `docs/specs/2026-05-23-auto-rescue-on-completion.md`,
  `docs/specs/2026-04-17-review-worker-rescue.md`.
- anti-stall discipline → `docs/specs/2026-05-24-worker-anti-stall-discipline.md`.
- PR Shepherd classification → `docs/specs/2026-05-23-pr-shepherd.md`.

### Alternatives considered

- **Raise the ceiling to 20000.** Rejected — the whole point of the gate is to
  keep CLAUDE.md lean; raising the ceiling is the failure mode the gate exists to
  prevent (see the size-guard spec and `feedback_claudemd_bloat.md`).
- **Split CLAUDE.md into includes.** Rejected — the harness loads a single
  CLAUDE.md; specs already serve as the "includes" via pointers. No new mechanism
  needed.

## Test plan

- `scripts/check-claude-md-size.sh` reports under the WARN band (NOTICE / <90%)
  and exits 0.
- `scripts/validate-state-all.sh` exits 0 (the CLAUDE.md size gate is the last
  item in it).
- Every `docs/specs/...` and `docs/...` pointer remaining in CLAUDE.md resolves to
  a real file (grep the references, confirm each path exists).

## Risks / rollback

- **Risk:** a trim accidentally drops a routing fact a future Commander needs.
  Mitigation: only prose that is duplicated in a referenced spec is removed; the
  spec pointer stays so the detail is one hop away. Hard rails untouched.
- **Rollback:** revert the single CLAUDE.md commit. No code or state changes.
