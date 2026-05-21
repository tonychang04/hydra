---
status: draft
date: 2026-05-21
author: hydra worker (ticket #195)
---

# Per-ticket cost-in-USD + cost-per-merged-PR efficiency metric

## Problem

`budget.json` / `state/budget-used.json` track **counts** — tickets done,
wall-clock minutes, rate-limit hits — but never **cost**. The community
consensus for proving an autonomous coding fleet is worth it is **cost per
merged PR**, not raw spend (the ticket cites Axon's "branch + PR URL + exact
cost in USD" return, Vantage's cost-per-PR framing, and Devin's ACU dashboards
with auto-recharge caps).

Two gaps:

1. **No per-ticket cost.** A worker run consumes input/output tokens, but
   nothing converts those tokens into dollars or records a per-ticket
   `cost_usd`. `budget.json:phase2_api_caps.per_ticket_cap_usd` (= 5) and
   `daily_cap_usd` (= 50) already exist as the *caps*, and
   `state/budget-used.json:phase2_spend_usd_today` already exists as the
   *counter slot* — but nothing computes the spend to fill them.
2. **No efficiency metric.** Even with per-ticket cost, the headline number
   the operator wants is `total cost ÷ PRs merged`. There is no tool that
   joins per-ticket cost against merged-PR status.

The merged trace substrate (#197, `docs/specs/2026-05-21-worker-session-trace.md`)
already captures token usage: `scripts/trace-append.sh` stores
`gen_ai.usage.input_tokens` / `gen_ai.usage.output_tokens` as **JSON numbers**
on `chat` spans (see `self-test/fixtures/worker-session-trace/sample-trace.jsonl`
line 6, and `scripts/test-trace.sh:98` asserting `input_tokens` is `type
"number"`). So the substrate is the input; this ticket builds the **cost
consumers** the trace spec explicitly fenced out as #195.

## Goals

1. A small, validated **pricing table** (model → $/Mtok for input and output)
   at `state/pricing.json`, schema-checked so it rides the existing
   `scripts/validate-state-all.sh` preflight gate.
2. `scripts/trace-cost.sh` — read a `logs/traces/<ticket>.jsonl`, compute
   `cost_usd` per token-bearing span (from the pricing table) and a per-ticket
   rollup `{input_tokens, output_tokens, cost_usd, by_model}`.
3. `scripts/cost-rollup.sh` — merge that per-ticket `cost_usd` (plus the token
   totals) **into the existing `logs/<ticket>.json`** without clobbering the
   other fields a worker wrote.
4. `scripts/cost-per-pr.sh` — the headline metric: a jq join of every
   `logs/<ticket>.json:cost_usd` against merged-PR status, emitting total
   cost, merged-PR count, and `cost_usd ÷ merged_prs`.
5. Pure bash + jq, no daemon, no backend — matches the trace substrate and the
   `scripts/*.sh` house style (`set -euo pipefail`, `--help`, documented exit
   codes, stdin-or-file, `--json`).
6. A real test (`scripts/test-cost.sh`) + a committed fixture + a self-test
   golden case, all offline.

## Non-goals

- **Not** wiring live workers to emit per-`chat`-turn token traces. That is the
  trace substrate's follow-up (broad emit rollout across the six worker types).
  This ticket consumes whatever token attrs are present; if a trace has none,
  cost is `0` (degrade safe, never crash).
- **Not** enforcing the per-ticket / daily USD cap at spawn time. We compute and
  record the spend; wiring it into the preflight cap-check (auto-pause when
  `phase2_spend_usd_today` ≥ `daily_cap_usd`) is a follow-up the recorded number
  unblocks. Flagged in the PR for a later ticket.
- **Not** a cost dashboard / UI. jq + the `quota` command are the read path.
- **Not** Phase-1 accuracy claims. Phase 1 is a flat Claude Code subscription
  (`budget.json:notes`), so the dollar number is a *modeled* cost (tokens ×
  list price), useful for relative efficiency + Phase-2 (Anthropic API on VM)
  where the dollars are real. The pricing table makes the model explicit.
- **Not** editing `scripts/trace-append.sh` to *emit* token attrs — it already
  does (numeric `gen_ai.usage.*_tokens`). `trace-cost.sh` only *reads* them.
- **Not** touching `scripts/rescue-worker.sh` (#206), self-test promotion
  (#205), or `CLAUDE.md` (conflict-avoidance per the ticket).

## Survey (current state, cited)

- **Token capture already works.** `scripts/trace-append.sh:183-187` stores a
  plain-integer `--attr` value as a JSON number; `scripts/test-trace.sh:98`
  asserts `gen_ai.usage.input_tokens | type == "number"`. The fixture
  `self-test/fixtures/worker-session-trace/sample-trace.jsonl:6` carries
  `"gen_ai.usage.input_tokens":1200,"gen_ai.usage.output_tokens":340`.
- **`logs/<ticket>.json` is the rollup target** and is heterogeneous: `ticket`
  can be an int (`logs/145.json`) or a string (`logs/144.json`,
  `"tonychang04/hydra#144"`); `repo` may be `null`; `pr_url` is a full GitHub
  PR URL. The cost tools must tolerate this. `logs/*` is gitignored runtime
  (`.gitignore: logs/*` + `!logs/.gitkeep`) — fixtures live under
  `self-test/fixtures/`, never `logs/`.
- **Cost slots already exist.** `budget.json:phase2_api_caps`
  (`per_ticket_cap_usd`, `daily_cap_usd`) are the caps;
  `state/schemas/budget-used.schema.json` already defines
  `phase2_spend_usd_today` (number, ≥ 0). The cost number we compute is what
  fills those — wiring the cap is the follow-up.
- **State validation gate.** `scripts/validate-state-all.sh` validates every
  `state/*.json` against `state/schemas/*.schema.json` and is the first
  preflight item. A new `state/pricing.json` + `state/schemas/pricing.schema.json`
  rides this gate for free. (`validate-state.sh` derives the schema name from
  the basename, so `state/pricing.json` → `state/schemas/pricing.schema.json`.)
- **Script house style** (followed here): `scripts/trace-analyze.sh` is the
  model jq-over-JSONL, stdin-or-file, `--json`, `set -euo pipefail`,
  documented-exit-code shape. `scripts/state-put.sh` is the atomic-write model.
- **Test + self-test conventions**: `scripts/test-trace.sh` (bash, `say/ok/bad`,
  pass/fail counter, `mktemp`, `NO_COLOR`) is the standalone-test model;
  `self-test/fixtures/worker-session-trace/run.sh` + the
  `worker-session-trace-script` case in `golden-cases.example.json` are the
  golden-wiring model. CI runs `bash -n` on every `scripts/*.sh` and
  frontmatter-checks every `docs/specs/*.md`.
- **macOS gotcha (learnings-hydra #126)**: BSD `sed`/`grep` reject `\s`/`\d`;
  use `[[:space:]]`/`[[:digit:]]`. All arithmetic on dollars is done in jq
  (floats), not bash (integer-only), to avoid precision loss.

## Pricing table

`state/pricing.json` — model → per-million-token rate, in USD. Input and output
priced separately (output is dearer). A `default` entry prices any model not
explicitly listed (so an unknown `gen_ai.request.model` never zeroes the cost
silently — it falls back to a documented rate). Shape:

```json
{
  "currency": "USD",
  "unit": "per_million_tokens",
  "_note": "Modeled list prices for relative efficiency + Phase-2 (API) cost. Phase 1 is a flat subscription; the dollar figure is an estimate, not a bill. Update rates as Anthropic list prices change.",
  "models": {
    "claude-opus-4-7":   { "input": 15.0, "output": 75.0 },
    "claude-sonnet-4-5": { "input": 3.0,  "output": 15.0 },
    "claude-haiku-4-5":  { "input": 1.0,  "output": 5.0 },
    "default":           { "input": 15.0, "output": 75.0 }
  }
}
```

`cost_usd = input_tokens / 1e6 * input_rate + output_tokens / 1e6 * output_rate`.

Model selection per span: `attrs."gen_ai.request.model"` if present, else the
table `default`. (The trace substrate does not yet emit a model attr on every
span; `trace-cost.sh` accepts an optional `--model <id>` to set the
whole-trace model when the trace omits it, defaulting to the table `default`.)

## Proposed approach

### Components / file structure

- **Create `state/pricing.json`** + **`state/schemas/pricing.schema.json`** — the
  table above + a Draft-07 schema (`currency`, `unit`, `models` required;
  each model `{input, output}` numbers ≥ 0; `default` required so fallback is
  always defined). Rides `validate-state-all.sh`.

- **Create `scripts/trace-cost.sh`** — cost over one `<ticket>.jsonl`.
  - Reads pricing from `--pricing <file>` (default `$HYDRA_PRICING_FILE` →
    `./state/pricing.json`).
  - Subcommands:
    - `spans` — per token-bearing span: `{span_id, model, input_tokens,
      output_tokens, cost_usd}`.
    - `rollup` — per-ticket total: `{input_tokens, output_tokens, cost_usd,
      by_model: {<model>: {input_tokens, output_tokens, cost_usd}}}`.
  - Input: trace file arg or stdin. `--model <id>` overrides the per-trace
    model. `--json` for machine output (default human lines). `--help`.
  - Cost math in jq (floats), rounded to 6 dp in the JSON, displayed to 4 dp.
  - Exit codes: `0` ok; `2` usage error / file-not-found / jq-missing /
    pricing-file-not-found.
  - Degrade safe: a trace with no token attrs → `cost_usd: 0`, never an error.

- **Create `scripts/cost-rollup.sh`** — write the per-ticket cost into
  `logs/<ticket>.json`.
  - `--ticket <n>` (required), `--trace <file>` (default
    `<trace-dir>/<ticket>.jsonl`), `--logs-dir <dir>` (default
    `$HYDRA_LOGS_DIR` → `./logs`), `--pricing`, `--model`, `--dry-run`.
  - Computes `trace-cost.sh rollup --json`, then merges
    `{cost_usd, input_tokens, output_tokens, by_model}` under a `cost` object
    **and** a top-level `cost_usd` (the headline number, where `cost-per-pr.sh`
    reads it) into the existing `logs/<ticket>.json` via
    `jq '. + {cost_usd: …, cost: …}'` (existing fields preserved). Atomic
    write (tmp + `mv`), matching `state-put.sh`.
  - If `logs/<ticket>.json` does not exist yet, create a minimal
    `{ticket, cost_usd, cost}` object (so cost can be recorded even before the
    worker writes its full log). `--dry-run` prints the merged JSON without
    writing. Exit `0`/`2`.

- **Create `scripts/cost-per-pr.sh`** — the headline aggregate.
  - Scans `--logs-dir` (default `./logs`) for `*.json`, reads each
    `cost_usd` (default `0` when absent) and `pr_url`.
  - Determines merged status. Default: `gh pr view <pr_url> --json
    state,mergedAt` per distinct `pr_url` (a PR is "merged" iff `mergedAt !=
    null`). For offline/test runs, `--merged-prs <file>` supplies a
    newline-list of merged PR URLs (or `state == "MERGED"`) and **no `gh` is
    called** — this is how the test runs in CI with no network.
  - Emits `{total_cost_usd, merged_prs, cost_per_merged_pr, tickets_counted,
    by_ticket: [...]}`. `cost_per_merged_pr` is `total_cost_usd ÷ merged_prs`
    over tickets whose PR merged (and `null` when `merged_prs == 0`, never a
    divide-by-zero). `--json` for machine output; human default prints the
    three headline lines. `--include-unmerged` adds unmerged spend as a
    separate line (so the operator sees wasted spend too). Exit `0`/`2`.

- **Create `scripts/test-cost.sh`** — standalone bash test (style of
  `scripts/test-trace.sh`): pricing math, rollup merge (preserve existing
  fields), cost-per-PR aggregate with an offline `--merged-prs` file, the
  divide-by-zero guard, degrade-safe zero-token trace, and usage errors.

- **Create `self-test/fixtures/cost-attribution/`**:
  - `sample-trace.jsonl` — a trace with two `chat` spans carrying token usage
    (one explicitly opus, one default-priced) so per-model rollup is exercised.
  - `logs/` — two `logs/<ticket>.json` fixtures (one with a merged PR, one with
    an unmerged PR) for the cost-per-PR join.
  - `merged-prs.txt` — the offline merged-PR list for the join.
  - `run.sh` — offline driver: delegates to `scripts/test-cost.sh`, asserts
    `SMOKE_OK`. Mirrors `self-test/fixtures/worker-session-trace/run.sh`.

- **Modify `scripts/README.md`** — one row each for `trace-cost.sh`,
  `cost-rollup.sh`, `cost-per-pr.sh`, `test-cost.sh`.

- **Modify `self-test/golden-cases.example.json`** — add a `kind:"script"`
  case `cost-attribution-script` (bash -n + --help + usage-error + fixture
  roundtrip), mirroring `worker-session-trace-script`. Self-defending `cmd`s
  (echo a sentinel only on success) per learnings-hydra #73 — the runner does
  not enforce `expected_stdout_contains`.

### Data flow

```
trace (logs/traces/<t>.jsonl, token attrs from #197)
   └─ trace-cost.sh rollup --json ──► {cost_usd, tokens, by_model}
        └─ cost-rollup.sh ──► merges cost_usd into logs/<t>.json (preserves fields)

logs/*.json  (each: cost_usd + pr_url)
   └─ cost-per-pr.sh ──► total_cost_usd ÷ merged_prs  (gh pr view, or --merged-prs offline)
```

### Error handling

- Missing required flag / unknown subcommand → exit 2, usage to stderr.
- `--pricing` / `--trace` file not found → exit 2 with a clear message.
- jq absent → fail fast "jq required" (matches sibling scripts).
- Zero token attrs in a trace → `cost_usd: 0` (not an error).
- Unknown model → priced at the table `default` rate (never silently `0`).
- `cost-per-pr.sh` with zero merged PRs → `cost_per_merged_pr: null` + a clear
  "no merged PRs" human line (no divide-by-zero).
- `cost-per-pr.sh` default (online) path needs `gh`; if `gh` is absent or a
  `pr_url` lookup fails, that PR is treated as unmerged and a one-line stderr
  warning is emitted (the aggregate still completes). `--merged-prs` makes the
  whole run offline + deterministic.

## Test plan

All offline, bash + jq, no network/docker (CI-safe). `scripts/test-cost.sh`:

1. **pricing math** — a span with 1,000,000 input + 1,000,000 output tokens at
   opus rates (15 / 75) → `cost_usd == 90.0`.
2. **per-model rollup** — fixture with an opus span + a default span → `by_model`
   has both, `cost_usd` == sum of the two.
3. **degrade-safe** — a trace with no token attrs → `cost_usd == 0`, exit 0.
4. **rollup merge preserves fields** — given a `logs/<t>.json` with
   `tier`/`pr_url`, `cost-rollup.sh` adds `cost_usd` + `cost` and leaves
   `tier`/`pr_url` intact.
5. **rollup creates minimal log** — no pre-existing log → a `{ticket, cost_usd,
   cost}` object is written.
6. **cost-per-pr join (offline)** — two ticket logs (one merged PR `$2.00`, one
   unmerged `$1.00`) + a `--merged-prs` file ⇒ `total over merged == 2.00`,
   `merged_prs == 1`, `cost_per_merged_pr == 2.00`.
7. **cost-per-pr divide-by-zero guard** — empty `--merged-prs` ⇒
   `cost_per_merged_pr == null`, exit 0.
8. **cost-per-pr --include-unmerged** — unmerged spend reported separately.
9. **usage errors** — missing subcommand / missing file / missing `--ticket`
   ⇒ exit 2.
10. **`bash -n`** on all new scripts (also CI).
11. **`validate-state-all.sh`** passes with the new `state/pricing.json`.

The fixture `run.sh` runs the suite; output is pasted into the PR per the
operator's "test for real" standing requirement.

## Risks / rollback

- **Risk: dollar figure is misread as a real bill in Phase 1.** Mitigated by
  the `_note` in `state/pricing.json` and the spec's non-goal: Phase 1 is a flat
  subscription; the number is a *modeled* estimate for relative efficiency and
  Phase-2 readiness.
- **Risk: stale list prices.** The pricing table is a single small JSON file the
  operator updates; rates are documented as list prices. No rate is hard-coded
  in a script.
- **Risk: heterogeneous `logs/*.json` shapes break the join.** Mitigated by
  defaulting `cost_usd`/`pr_url` to `0`/null and tolerating string-or-int
  `ticket`. Tested against both an int-ticket and a string-ticket fixture.
- **Risk: `cost-per-pr.sh` online path needs network (`gh`).** Mitigated by the
  `--merged-prs` offline override (the only path the test/CI uses) and
  treat-as-unmerged-on-lookup-failure.
- **Risk: scope creep into the cap enforcement / dashboard.** Explicitly fenced
  as follow-ups; this ticket only records the number.
- **Rollback:** purely additive — three new scripts + a test + a pricing
  state file + schema + a fixture + a README + a golden case + this spec.
  Nothing existing changes behavior. Delete the files to roll back; no
  migration. (The new `state/pricing.json` is read only by the new scripts.)

## Out of scope (tracked elsewhere)

- Enforcing `per_ticket_cap_usd` / `daily_cap_usd` at spawn preflight (auto-pause
  on `phase2_spend_usd_today` ≥ cap) — follow-up the recorded number unblocks.
- Wiring `cost_usd` into the `quota` / daily-digest output — follow-up (the
  scripts emit `--json` ready for it).
- Per-`chat`-turn model attribution in live worker traces — trace substrate
  follow-up (#197 broad emit rollout).
- Watchdog trace-reader — #206. Self-test promotion — #205. CLAUDE.md — not
  edited (conflict-avoidance).
