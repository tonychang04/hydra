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

## Out of scope

PRs that turn Hydra into a general chat assistant, add CEO/design/DX plan reviews, or loosen the self-modification denylist will be closed. Scope is narrow on purpose. See README.md § "What Hydra is NOT."
