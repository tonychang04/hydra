---
status: draft
date: 2026-06-08
author: hydra worker (ticket #295)
---

# Worker pre-PR repo-wide syntax-check gate + spec frontmatter template reference

## Problem

On 2026-06-08 two specs shipped without YAML frontmatter —
`docs/specs/2026-06-08-in-flight-spec-checkpoints.md` (#288) and
`docs/specs/2026-06-08-dynamic-session-preamble.md` (#274). Each turned CI RED:
the `Syntax` job (`.github/workflows/scripts/syntax-check.sh` check 3) and the
`local-syntax-check-parity` self-test both fail on ANY frontmatter-less spec.
Worse, the syntax-check scans the WHOLE `docs/specs/` tree, so the poison
surfaces on the *next* unrelated PR, and #288 even merged (no required checks).
Neither the worker's own narrow per-feature self-test nor `worker-review`
caught it. This is the third recurrence of the same class — see
`memory/learnings-hydra.md` 2026-05-21 #201 ("both PR #200's and #201's own
specs shipped frontmatter-less and reddened CI").

Root cause: a worker's pre-PR verification (the validation contract + evidence
checklist) does not require running the repo-wide CI syntax-check — only narrow
per-feature self-tests — so a missing/blank frontmatter block is invisible
locally and only reddens on CI. And because frontmatter is hand-written from
memory, it is sometimes omitted entirely.

## Goals / non-goals

**Goals:**
- Any worker PR that adds or edits a `docs/specs/*.md` MUST run
  `bash .github/workflows/scripts/syntax-check.sh` and confirm exit 0 BEFORE
  opening/finalizing the PR. The requirement lives in the
  `worker-implementation` pre-finalization gate (the validation-contract +
  evidence flow), terse and additive, matching the existing gate's format.
- New specs start from a canonical frontmatter template that already carries a
  valid `status: / date: / author:` block, so the frontmatter is copied, not
  recalled. The template is referenced from the spec-driven section of the
  worker prompt.

**Non-goals:**
- Not adding a new CI job or required-check (separate concern; the syntax-check
  job already exists — the gap is the *worker* not running it locally).
- Not rewriting the syntax-check itself.
- Not touching `CLAUDE.md` (Commander routing only; worker procedure belongs in
  the agent def + this spec).
- Not auto-generating specs from the template (a reference/pointer, not a
  scaffolder).

## Proposed approach

Two small, additive edits to `.claude/agents/worker-implementation.md`:

1. **Pre-finalization syntax-check requirement.** Add a short bullet to the
   validation-contract finalize step (Phase 2 / Flow step 6) stating: if the PR
   touches `docs/specs/*.md`, run `bash .github/workflows/scripts/syntax-check.sh`
   and confirm `syntax-check: OK` (exit 0) before finalizing — this is the same
   check the `Syntax` CI job runs, catching the frontmatter regression locally.

2. **Template reference.** In the spec-driven section (which currently says
   "write a spec at `docs/specs/YYYY-MM-DD-<slug>.md`"), point the worker at the
   already-existing `docs/specs/TEMPLATE.md` as the starting point so the
   frontmatter block is copied verbatim.

**Reuse the existing template — do not create a duplicate `_TEMPLATE.md`.**
`docs/specs/TEMPLATE.md` ALREADY exists with exactly the canonical frontmatter
the ticket asks for (`status: draft` / `date: YYYY-MM-DD` / `author: …`) and is
ALREADY exempt from the syntax-check by basename (check 3 skips `README.md` and
`TEMPLATE.md`). Creating a second `_TEMPLATE.md` would (a) duplicate an existing
artifact — violating `memory/feedback_follow_existing_patterns.md` — and (b)
require a NEW exemption in the syntax-check globbing (it skips `TEMPLATE.md`, not
`_TEMPLATE.md`). Reusing the existing file satisfies acceptance criterion #2 ("a
spec template exists + is referenced") with zero new surface and zero check
changes.

### Alternatives considered

- **Create `docs/specs/_TEMPLATE.md` (the literal ticket wording).** Rejected:
  duplicates the existing `TEMPLATE.md`; the syntax-check skips `TEMPLATE.md` by
  basename, so `_TEMPLATE.md` would either need its own valid frontmatter
  (redundant with `TEMPLATE.md`) or a new ignore-list entry. More surface, more
  drift, same end-state. The ticket allows "or a scaffold note" — referencing the
  existing template IS that note.
- **Add a required CI check / pre-commit hook.** Rejected as out of scope: the
  `Syntax` CI job already exists; the failure mode is a worker not running it
  locally before opening the PR, which is a procedure gap, not a CI gap.

## Test plan

- `bash .github/workflows/scripts/syntax-check.sh` exits 0 over the committed
  tree (this spec's own frontmatter passes — eat-our-own-dogfood).
- `head -5 docs/specs/TEMPLATE.md` shows the canonical `status:/date:/author:`
  block (template exists).
- `grep -n "TEMPLATE.md" .claude/agents/worker-implementation.md` shows the new
  reference (template referenced from the worker prompt).
- `grep -n "syntax-check.sh" .claude/agents/worker-implementation.md` shows the
  new pre-finalization requirement.
- `scripts/validate-state-all.sh` exits 0 (no state/schema/CLAUDE.md-size
  regression).

## Risks / rollback

- Risk: the added gate is prose in an agent def — a worker could still skip it.
  Mitigation: it lives inside the existing MANDATORY validation-contract flow
  that workers already follow, and the syntax-check is offline/fast (no docker).
  This narrows but does not eliminate the gap; a future ticket could add it as a
  required CI check.
- Rollback: revert this PR's single commit to the agent def. No state, schema,
  or runtime behavior changes — purely a worker-procedure doc edit plus this
  spec.
