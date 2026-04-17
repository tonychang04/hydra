# Commander — commands table fixture (expected resolution)

This is what `worker-conflict-resolver` should produce after merging PR #A (retro)
and PR #B (autopickup) when both were opened off `base-commands-table.md`.

Rules applied:
- Both sides added rows to the same markdown table → keep both rows.
- Order by ascending PR number (A first, then B). This matches the merge order the
  resolver follows (numeric-PR-number order, lowest first).
- No duplicates — neither row appears twice.
- Column count on every row matches the header (`| col1 | col2 |` → 2 columns).

## Commands you understand

| the operator says | You do |
|---|---|
| `status` / `what's running` | Read `state/active.json` + recent logs, summarize. |
| `pick up N` | Main spawn loop, up to N `worker-implementation` agents |
| `pick up #42` | Spawn `worker-implementation` on that specific ticket |
| `review PR #501` | Spawn `worker-review` on that PR |
| `test discover <repo>` | Spawn `worker-test-discovery` on that repo |
| `retro` | Produce a weekly retro from `logs/*.json` and write to `memory/retros/YYYY-WW.md`. |
| `autopickup every N min` | Enter scheduled auto-pickup mode (N clamped to [5, 120], default 30). |
