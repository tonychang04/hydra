# hydra-doctor broken fixture

This directory is deliberately broken. It is a minimum `HYDRA_ROOT` that
exercises `scripts/hydra-doctor.sh` against a set of known-failing checks so
the `doctor-fix-smoke` self-test (spec: `docs/specs/2026-04-17-doctor-fix-mode.md`)
can assert that every ✗ line comes with an actionable `fix_hint`.

**Do not fix this fixture.** It is test data. Any failure doctor emits here is
expected.

What's broken:

- `state/repos.json` is malformed JSON (missing closing brace) — exercises the
  "valid JSON" parse-error failure.
- `state/active.json`, `state/budget-used.json`, `state/memory-citations.json`
  are **absent** — exercises the "missing state file" failures.
- `.claude/settings.local.json` is absent — exercises the settings-missing
  failure.
- `logs/` is absent — exercises the warning-with-auto-fix path.
- `budget.json` is present but valid, so the check_environment /
  check_integrations categories don't blow up mid-run.
- `memory/MEMORY.md` is present (empty) so the memory category doesn't abort
  before emitting the validate-learning-entry warnings.

How the fixture is invoked:

```bash
HYDRA_ROOT=self-test/fixtures/hydra-doctor/broken \
  NO_COLOR=1 scripts/hydra-doctor.sh --category=config --category=runtime
```

(The self-test runs one category at a time because the environment-category
checks inspect the host machine's PATH, not `HYDRA_ROOT`, and would flake
across CI hosts.)
