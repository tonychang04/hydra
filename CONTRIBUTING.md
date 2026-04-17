# Contributing to Hydra

See **[DEVELOPING.md](DEVELOPING.md)** for the full contributor workflow — how to set up, the dogfood principle, spec-driven rule, testing layers, and out-of-scope PRs.

Quick version:

1. **Check the issue backlog** — https://github.com/tonychang04/hydra/issues
2. **Comment before starting** — so someone doesn't dupe your work
3. **Non-trivial changes need a spec** in `docs/specs/YYYY-MM-DD-<slug>.md` BEFORE the code. Rule: if it touches `CLAUDE.md`, `policy.md`, worker subagents, or the permission profile, it needs a spec. Typos + dep patch bumps can skip.
4. **Every PR includes tests** — unit, integration, or self-test golden case depending on scope
5. **Run `./self-test/run.sh` before committing** (once #15 lands)
6. **Open as draft PR** labeled `commander-review` for the review-worker to pick up

Also — Hydra can contribute to Hydra. See DEVELOPING.md § "The dogfood principle."

## Commander procedure docs

New Commander procedures (tick loops, rescue flows, decision protocols, template systems, anything with "steps" longer than ~10 lines) go to `docs/specs/YYYY-MM-DD-<slug>.md`. CLAUDE.md at the repo root holds only **routing tables, hard rails, and one-line spec pointers** — never the full procedure inline.

Why: CLAUDE.md is loaded into every Commander session's context. Every token of inline procedure is paid on every session start, forever. In April 2026 it hit 40k characters and started degrading performance — most of the bloat was duplication of procedures that already had specs. The rule is now enforced mechanically: `scripts/check-claude-md-size.sh` fails if `CLAUDE.md > 18000` chars, and it runs inside `scripts/validate-state-all.sh`, which Commander calls as the first item of every spawn preflight. A trip on the size gate means **move a section out**, not raise the threshold.

Shape of a pointer section:

```
## Worker timeout watchdog

Workers can hit stream-idle timeouts around 18 min with partial work
uncommitted. The watchdog runs on every tick that touches state/active.json,
uses scripts/rescue-worker.sh --probe to check for recoverable work, and
either rescues + resumes or labels commander-stuck.

Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md +
docs/specs/2026-04-17-review-worker-rescue.md.
```

3-6 lines of orienting context + a spec pointer. The full procedure, exit-code contracts, and edge cases live in the spec. Sections kept inline in full are hard rails only: identity, worker types table, operating-loop steps, commands table, safety rules, state-file list, session greeting.

See `memory/feedback_claudemd_bloat.md` and `docs/specs/2026-04-17-claudemd-size-guard.md` for the full rule and rationale. The rule scopes to Hydra's root CLAUDE.md; downstream repos Commander manages have their own budgets.

## Out of scope

PRs that turn Hydra into a general chat assistant, add CEO/design/DX plan reviews, or loosen the self-modification denylist will be closed. Scope is narrow on purpose. See README.md § "What Hydra is NOT."
