# state-schemas fixtures

Fixtures for the `state-schemas` golden case in `self-test/golden-cases.example.json`.
Exercises `scripts/validate-state.sh` and `scripts/validate-state-all.sh` against
the schemas in `state/schemas/*.schema.json`.

## Layout

```
valid/                   one file per schema — all MUST pass validation
├── active.json
├── autopickup.json
├── budget-used.json
├── memory-citations.json
└── repos.json

invalid/                 one file per schema — all MUST fail the minimal (bash+jq) check
├── active.json          missing 'workers'
├── autopickup.json      missing last_run, last_picked_count, consecutive_rate_limit_hits
├── budget-used.json     missing total_worker_wall_clock_minutes_today, rate_limit_hits_today
├── memory-citations.json  missing 'citations'
└── repos.json           missing 'repos'

invalid-strict/          one file per schema — fails ONLY the strict (ajv-cli) check
├── active.json          has 'tier': 'T4' — not in the enum, accepted by bash+jq
└── autopickup.json      interval_min: 1 — violates minimum: 5, accepted by bash+jq
```

The `invalid/` fixtures intentionally trip the `required` top-level check so the
bash+jq fallback path catches them. The `invalid-strict/` fixtures use deeper
violations (enum / minimum) that only ajv-cli can detect, so they are useful
when validating with `--strict` and a real `ajv` binary on PATH.

## Maintaining

- Each schema added to `state/schemas/` needs a matching fixture pair under
  `valid/` and `invalid/` (+ optionally `invalid-strict/`). The bulk validator
  iterates `state/schemas/*.schema.json`, so a missing fixture silently makes
  the bulk run skip the real file in CI — add the pair when you add the schema.
- When a schema changes (new required field, tighter enum, stricter regex),
  update the paired fixtures in the same commit. The golden case runs on every
  PR, so the CI signal is immediate.
- Both `valid/` and `invalid/` fixtures MUST remain structurally valid JSON.
  Only the schema should reject them — the point is to test schema enforcement,
  not to test JSON parsing.

Spec: `docs/specs/2026-04-16-state-schemas.md`. Ticket: #30.
