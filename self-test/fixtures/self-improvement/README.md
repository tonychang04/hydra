# self-improvement fixtures

Supports the `self-improvement-proposes-from-fixtures` golden case in `self-test/golden-cases.example.json`. Spec: `docs/specs/2026-04-16-self-improvement-cycle.md`. Ticket: #9.

## Layout

| Path | Purpose |
|---|---|
| `logs-3-stuck/` | Four `logs/*.json` — three with `result: "stuck"` + matching `stuck_pattern`, one shipped. Above the 3-occurrence / 2-distinct-ticket threshold, so `propose-improvements.sh` emits a stuck-pattern proposal. |
| `logs-2-stuck/` | Two stuck logs on the same pattern. Below threshold; proposer emits zero stuck-pattern proposals. Anchors the "don't over-propose on noise" behavior. |
| `memory-citations-hot.json` | Three promotion-ready entries (counts 6, 5, 4) plus one non-promotion entry (count 2). Proposer emits 2 proposals (only `count >= 5` entries qualify). |
| `empty/` | Empty directory to pass as `--retros` when we don't want the recurring-retros rule to fire. `.gitkeep` keeps it tracked. |
| `expected-proposals.json` | Canonical output of `propose-improvements.sh --fixture --logs-dir logs-3-stuck --citations memory-citations-hot.json --faq /dev/null --retros empty`. The golden case diffs against this bit-for-bit — if the expected output needs to change, regenerate it via the same command. |

## Regenerating `expected-proposals.json`

```bash
scripts/propose-improvements.sh --fixture \
  --logs-dir self-test/fixtures/self-improvement/logs-3-stuck \
  --citations self-test/fixtures/self-improvement/memory-citations-hot.json \
  --faq /dev/null \
  --retros self-test/fixtures/self-improvement/empty \
  > self-test/fixtures/self-improvement/expected-proposals.json
```

`--fixture` replaces the wall-clock timestamp with the literal string `"fixture"` so the committed file is deterministic. If you hand-edit a fixture (add a stuck log, tweak a citation count), regenerate the expected output in the same commit.
