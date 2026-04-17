---
status: implemented
date: 2026-04-16
author: hydra worker (issue #9)
---

# Self-improvement cycle: Commander files its own tickets

## Problem

Today the loop is: operator files tickets → Hydra clears tickets → operator reviews PRs. The operator is still the source of work. The 24/7 vision (umbrella #4) only closes when Hydra also watches its own operation and proposes improvements — i.e. files its own tickets.

Signals are already sitting in the filesystem:

- `logs/*.json` — every worker run, including stuck patterns
- `memory/escalation-faq.md` — the human interventions we paid for
- `state/memory-citations.json` — which memory earned its keep
- `memory/retros/*.md` — weekly patterns already surfaced in retros

None of that flows back into "what ticket should we file next?" today. The operator has to spelunk manually, which is exactly the kind of friction that loses to "I'll do it later."

## Goals

- A detection pass (`scripts/propose-improvements.sh`) that reads the signals above and emits structured proposal JSON when thresholds are met
- A filing pass (`scripts/file-proposed-issues.sh`) that consumes the JSON, enforces the 3/week rate limit, checks against `state/declined-proposals.json`, and calls `gh issue create`
- Deterministic, stable pattern hashes so dedup against previously-filed and operator-declined proposals actually works
- CLAUDE.md procedure that documents when the commander runs this and what it looks at
- Self-test golden case covering threshold respect: 3-occurrence fixture proposes, 2-occurrence fixture doesn't

## Non-goals

- Not a worker subagent. The detection is pure read-over-state + jq; no worktree isolation needed. (The issue body considered `worker-improvement-proposer` as an option — rejected for the same reason `retro` is inline: it only reads state and writes JSON.)
- Not automatic filing. `propose-improvements.sh` is safe to run often; `file-proposed-issues.sh` is the side-effectful step, invoked by the operator (or by a future scheduled tick, which is explicitly out of scope for this PR).
- Not an LLM-driven proposer. The rules are simple enough to codify in bash+jq. If the rule set grows to the point where it needs judgment, that's a future ticket — not this one.
- Not a replacement for operator-filed tickets. Operators still file tickets directly; this is additive.

## Proposed approach

Two scripts, split on the side-effect boundary.

### `scripts/propose-improvements.sh` (pure detection)

Reads (each optional, each with a flag to override the directory — mirrors the `--memory-dir` pattern from `parse-citations.sh`):

- `--logs-dir <path>` (default `./logs`) — scan `*.json`; look for `result: "stuck"` entries grouped by `(repo, stuck_pattern)`. Threshold: ≥3 occurrences across ≥2 distinct tickets in the last 30 days.
- `--citations <path>` (default `./state/memory-citations.json`) — entries with `count >= 5` and `promotion_threshold_reached: true` but no open promotion PR → propose one.
- `--faq <path>` (default `./memory/escalation-faq.md`) — count `### ` headings per topic prefix (simple grep-by-keyword). ≥3 similar questions → propose "add repo-native skill for X pattern." (Heuristic: group by keyword buckets declared in the script; the bar for declaring a bucket is low — it's ok to miss some themes, just don't invent ones.)
- `--retros <path>` (default `./memory/retros`) — read recent retros' `## Stuck` and `## Proposed edits` sections; any pattern surfaced 2+ weeks in a row → propose.

Emits JSON to stdout:

```json
{
  "generated_at": "2026-04-16T00:00:00Z",
  "proposals": [
    {
      "pattern_hash": "<stable hex digest>",
      "source": "logs-stuck|citations-hot|faq-theme|retro-recurring",
      "repo": "tonychang04/hydra",
      "title": "[auto-proposed] <short summary>",
      "body": "## Summary\n...\n## Evidence\n...",
      "labels": ["commander-proposed"],
      "confidence": "high|medium|low",
      "evidence_refs": ["logs/10.json", "logs/11.json", "logs/12.json"]
    }
  ]
}
```

Does NOT call `gh`. Does NOT write anywhere. Stateless; safe to run often.

**`--fixture` mode:** swaps the defaults to read from the fixture subdir passed to `--logs-dir` etc. Produces deterministic output (no `generated_at` timestamp — replaced with the literal string `"fixture"`) so the self-test can diff against a committed `expected-proposals.json`.

### `scripts/file-proposed-issues.sh` (side-effectful filing)

Reads the JSON above on stdin (or from a file arg), then:

1. Loads `state/proposed-issues.json` (created lazily, tracks `filed_issues[pattern_hash] = {issue_url, filed_at}`).
2. Loads `state/declined-proposals.json` (operator-declined patterns with 90-day suppression).
3. For each proposal:
   - If `pattern_hash` is in either state file and still within the TTL → skip.
   - If this tick's filed count + already-filed-this-week ≥ 3 → stop (rate limit).
   - Else: `gh issue create --title ... --body ... --assignee @me --label commander-proposed` on `repo`.
   - Append to `state/proposed-issues.json`.
4. Writes back `state/proposed-issues.json`.

The `--dry-run` flag prints the `gh` commands without running them. Default is dry-run (explicit safety — invocation requires `--execute`).

### Pattern hash

`sha1(source + "|" + repo + "|" + normalized_title)` — normalized title strips variable tokens (dates, counts, ticket numbers) so the SAME pattern at a different count still hashes to the same value. Dedup actually works.

### Alternatives considered

- **A: Single script with `--file` flag.** Simpler but conflates safe detection with risky filing. Rejected — splitting matches the `parse-citations.sh` / commander-merges-delta pattern already in the codebase.
- **B: Worker subagent (`worker-improvement-proposer`).** The issue body considered this. Rejected: no code changes are produced, no worktree isolation needed. Retro proved that commander-inline is fine for this kind of meta-analysis.
- **C: LLM-driven proposer.** Write an agent prompt that reads the state files and drafts issues. Rejected for v1 — the rules are simple enough that bash+jq is more auditable. Future ticket if the rule set outgrows the script.

## Test plan

1. `bash -n scripts/propose-improvements.sh scripts/file-proposed-issues.sh` clean — basic hygiene
2. `jq empty state/declined-proposals.json.example state/proposed-issues.json.example` — JSON valid
3. `scripts/propose-improvements.sh --fixture --logs-dir self-test/fixtures/self-improvement/logs-3-stuck …` produces 1 stuck-pattern proposal (threshold met)
4. `scripts/propose-improvements.sh --fixture --logs-dir self-test/fixtures/self-improvement/logs-2-stuck …` produces 0 stuck-pattern proposals (below threshold)
5. `scripts/propose-improvements.sh --fixture --citations self-test/fixtures/self-improvement/memory-citations-hot.json` produces promotion-candidate proposals for entries with `count >= 5`
6. Golden self-test case `self-improvement-proposes-from-fixtures` wires all of the above and diffs against `self-test/fixtures/self-improvement/expected-proposals.json`

## Risks / rollback

- **Risk:** Over-proposing. **Mitigation:** ≥3 occurrence + ≥2 distinct ticket threshold (matches memory promotion); 3/week rate cap; 90-day decline TTL.
- **Risk:** Pattern hash drift breaks dedup (operator declines a proposal, next week commander files the same one again because the hash changed). **Mitigation:** normalized titles + unit-testable hash function; self-test asserts hash stability across equivalent inputs.
- **Risk:** `gh issue create` fails mid-batch leaving `state/proposed-issues.json` inconsistent. **Mitigation:** append after each successful `gh` call, not in a batch at the end; a mid-batch failure leaves correct state for the issues that did file, and the next run picks up where it left off.
- **Risk:** Operator finds the filing too noisy. **Mitigation:** `state/repos.json:auto_propose: true` is opt-in per repo (default false for external repos); `./hydra` or CLAUDE.md can be edited to remove the `propose improvements` trigger from retro's tail.
- **Rollback:** revert the PR. Scripts + state are additive; no existing code path depends on them. The `state/declined-proposals.json` file (if populated) is pure commander state; losing it means a previously-declined pattern might re-propose once, which is a paper cut, not damage.

## Implementation notes

(Filled in after the PR lands.)

- CLAUDE.md wires the procedure under a new "Self-improvement proposals" section that sits right before "Weekly retro" — the two are companions (retro surfaces patterns, proposer acts on them).
- `state/declined-proposals.json` and `state/proposed-issues.json` are gitignored (per usual for operator state); committed examples ship as `*.example` files.
- `scripts/file-proposed-issues.sh` defaults to `--dry-run`. An operator who wants the filing to actually happen passes `--execute` — this matches the pattern from `scripts/memory-mount.sh` where the destructive path is opt-in.
- The fixture test (`self-improvement-proposes-from-fixtures`) runs under the existing script-kind self-test executor — no new runner wiring required.
- escalation-faq.md picked up a new "Self-improvement proposals" section documenting how the rate limit and decline-TTL interact, so workers and the operator have a single answer surface for "why didn't / did commander propose X?".
