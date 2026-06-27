---
status: accepted
date: 2026-06-07
ticket: https://github.com/tonychang04/hydra/issues/255
area: worker contract / review gate / quality
size: M
authors: [worker-implementation]
supersedes: []
extends:
  - docs/specs/2026-05-21-evidence-based-review-gate.md
  - .claude/agents/worker-implementation.md
  - .claude/agents/worker-review.md
  - docs/specs/2026-04-17-slim-worker-prompts.md
---

# Verify-first validation contract + evidence completion gate

## Problem

Hydra's #1 documented weakness is **workers CLAIMING tests ran when they did
not**, and "changes land in weird ways" (`memory/MEMORY.md` →
`feedback_context_and_testing_weakness`, `feedback_integration_test_completeness`).
This session proved it twice: PRs passed the local self-test but failed CI —
once for missing spec frontmatter, once for a `set -u` `stat` bug that only
reproduced on Linux. In both cases the worker *believed* it had verified the
work; nothing on disk forced it to prove each acceptance criterion with a real
command + real output before opening the PR.

The existing **evidence-based review gate** (#196,
`docs/specs/2026-05-21-evidence-based-review-gate.md`) already attacks the
*reviewer* side: `worker-review` fills an EVIDENCE TABLE in the PR comment, and
`scripts/validate-evidence-table.sh` rejects any `PASS` without evidence. That is
a strong gate — but it fires **after** implementation, **off-worktree** (in a PR
comment a different worker authors), and it re-derives the criteria from scratch.
It does not force the *implementer* to verify-first, and it does not leave a
machine-checkable artifact **in the worktree** that the implementer produced.

The Factory Missions pattern (`memory reference_factory_missions_lessons`,
operator-provided — no web access in worker mode) closes exactly this gap: write
a `validation-contract` — a finite checklist of testable assertions, each naming
the command that proves it — **BEFORE** any implementation, and gate completion
on it. "Every phase produces a file or exit code; the orchestrator never trusts
chat output."

## Goals

1. Define a per-ticket **validation-contract** artifact (`validation-contract.md`)
   the implementation worker writes into its worktree **FIRST** (derived from the
   ticket's acceptance criteria), then **fills with captured EVIDENCE** (command
   + exit code + output snippet) before opening / finalizing the PR.
2. Provide a deterministic helper `scripts/validate-contract.sh` that PASSES
   (exit 0) only when **every** assertion row carries a command **and** evidence;
   an unproven assertion → nonzero exit. RED (missing evidence) → GREEN (complete)
   fixtures prove it.
3. Wire it in **additively**:
   - `worker-implementation` writes + fills the contract and runs the helper
     before finalizing the PR (a self-gate);
   - `worker-review` checks the contract artifact **exists and passes the helper**
     as one input to its existing evidence table — an *unproven contract* is a
     blocker. This EXTENDS the #196 gate; it does not replace it.
4. Document the artifact format so the downstream #256 (worker-validator) can
   build on it without reverse-engineering. Keep the format clean + extensible.

## Non-goals

- **Do NOT replace or duplicate the #196 review gate.** The reviewer's EVIDENCE
  TABLE (in the PR comment) stays exactly as-is. This adds an *implementer-side,
  in-worktree* artifact that feeds it. Two artifacts, one philosophy ("no PASS
  without evidence"), distinct lifecycles (contract = written first by the
  implementer; evidence table = written last by the reviewer).
- **Do NOT break the existing worker flow.** Rollout is additive: a PR that does
  NOT carry a contract is not auto-rejected by CI in this ticket (the helper is
  invoked by the agents, not wired into the `syntax` CI job). The contract becomes
  mandatory via the agent prompts; existing in-flight tickets keep functioning.
  Hard CI enforcement is a deliberate follow-up once the format proves out (V1
  ship principle: enforce the floor now, tighten with data later).
- **No LLM-based command execution inside the helper.** The helper is a pure text
  validator (assertion has a command + non-placeholder evidence). The *worker*
  runs the commands and pastes real output; the helper checks the artifact's
  shape and the no-PASS-without-evidence invariant — deterministic + testable,
  mirroring the #196 checker's design choice.
- **No new contract format vocabulary divergent from #196.** Verdicts reuse
  `PASS` / `FAIL` / `UNVERIFIED` with the same placeholder-evidence rules, so a
  worker who knows the review gate already knows the contract.

## Proposed approach

### Where the pieces live

| File | Change |
|---|---|
| `docs/specs/2026-06-07-validation-contract.md` | This spec. |
| `scripts/validate-contract.sh` | New. Parses a `validation-contract.md` table; exits 0 only when every assertion has a command + (for PASS) evidence. |
| `scripts/test-validate-contract.sh` | New. Self-contained RED→GREEN regression test (bash, pass/fail counter, `NO_COLOR`-aware — same shape as `test-validate-evidence-table.sh`). |
| `self-test/fixtures/validation-contract/` | New. `red.md` (missing evidence → helper FAILs) + `green.md` (complete → helper PASSes) fixtures the test consumes. |
| `.claude/agents/worker-implementation.md` | Add a "Validation contract (verify-first)" section: write the contract first, fill evidence, run the helper before finalizing the PR. |
| `.claude/agents/worker-review.md` | Add a flow step: check the worktree's `validation-contract.md` exists + passes `validate-contract.sh`; an unproven contract is a blocker feeding the EVIDENCE TABLE. |
| `CLAUDE.md` | One-line pointer under the review-gate area, offset by a trim elsewhere (size band guard). |

### The validation-contract artifact format

A single Markdown file at the per-ticket, gitignored path
`.hydra/contracts/<ticket>.md` (**updated by #262** — the artifact originally
lived at the committed worktree root as `validation-contract.md`, which collided
across concurrent tickets; see `docs/specs/2026-06-08-contract-artifact-location.md`).
It carries a fixed-header table; the helper parses **only** that table (free-form
prose around it is fine — the worker can add a header naming the ticket).

```markdown
# Validation contract — #<ticket>

> Written BEFORE implementation from the ticket's acceptance criteria.
> Each assertion names the command that proves it; evidence filled in before PR.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | <acceptance criterion, one line> | `<command that proves it>` | exit 0 / `<expected output>` | PASS | `<command>` -> exit 0; `<output snippet>` |
| 2 | <criterion> | `<command>` | `<expected>` | FAIL | observed: `<what actually happened>` |
| 3 | <criterion> | `<command>` | `<expected>` | UNVERIFIED | <why it could not be run in worker scope> |
```

Column contract (the helper enforces it):

- **Header row** is exactly `| # | Assertion | Command | Expected | Verdict | Evidence |`
  (case-insensitive on the column words; whitespace-tolerant), followed by a
  `|---|...|` separator.
- **Assertion** — non-empty. A row with no assertion is malformed.
- **Command** — non-empty and non-placeholder for **every** row regardless of
  verdict. The whole point is "name the command that proves it" *up front*; a row
  with no command is the verify-first failure the artifact exists to prevent.
- **Verdict** ∈ {`PASS`, `FAIL`, `UNVERIFIED`} (case-insensitive). Else malformed.
- **Evidence** — for `PASS`, non-empty + non-placeholder (a lone `-`, `n/a`,
  `none`, `tbd`, backticks-only → treated as EMPTY, exactly per #196). `FAIL` /
  `UNVERIFIED` may have empty evidence (a FAIL says what broke; UNVERIFIED says
  why it couldn't run).
- **At least one assertion row** must exist.

#### Command + Expected cell authoring rules (hardened by #310)

The **truth gate** (`scripts/revalidate-contract.sh`, #256) RE-RUNS each row's
Command and compares the actual exit/output to Expected. For that to be reliable,
the cells must be machine-checkable, not free prose. These rules are enforced by
the gate (a violation surfaces as a distinct `AUTHORING-ERROR`, exit 3 — NOT a
code `MISMATCH`). See `docs/specs/2026-06-26-revalidate-parser-hardening.md`.

- **Command cells MUST be self-contained and copy-paste runnable.** The gate runs
  the cell verbatim via `bash -c` in the worktree. Do NOT leave:
  - an unfilled angle-bracket placeholder (`<fixture>`, `<fixture-logs>`, `<n>`) —
    fill in the real value before you run the contract; and
  - a bare `$VAR` / `${VAR}` with no inline binding in the same command — either
    bind it inline (`T=foo; … "$T"`), use a well-known env var (`$HOME`,
    `$COMMANDER_ROOT`, …), or inline the literal value.
  A non-self-contained Command is a **contract authoring error**, reported
  distinctly and never confused with a real failure. (Root cause of the PR #307
  false positive: placeholder/unbound cells ran and their shell errors looked like
  code MISMATCHes.)
- **The expected exit code lives in its own structured field** — the leading
  `exit <N>` clause of the Expected cell, before the first ` / ` output separator.
  The documented Expected grammar is `exit <N>[ / <output substring>]`. The gate
  reads the exit code ONLY from that leading clause; it never scrapes an `exit <N>`
  token out of free-text prose elsewhere in the cell. So describing what *another*
  exit code would mean ("`exit 1` would mean no match") is safe prose, not a
  competing expectation. (Root cause of the PR #309 false positive: `exit 1` in a
  grep row's description was scraped and demanded.)
- **Escape a literal pipe as `\|`** inside any cell (Command, Expected, Evidence)
  — that is how GitHub renders a pipe in a table cell, and the shared splitter
  restores it as a literal `|` so it never shifts columns.

The two-phase lifecycle the artifact encodes:

1. **Phase 1 (verify-first, before code):** the worker writes the table with
   Assertion + Command + Expected filled, Verdict/Evidence blank or `UNVERIFIED`.
   This is the contract written FIRST.
2. **Phase 2 (before PR):** the worker RUNS each command, captures real exit code
   + output, fills Verdict + Evidence. Then runs `validate-contract.sh`; it must
   exit 0 before the PR is finalized.

### Why reuse the #196 vocabulary (alternatives considered)

- **Alternative A — a JSON contract.** Rejected: the artifact must be
  human-readable in the worktree / PR (the operator and the reviewer read it). A
  Markdown table is both human-readable and parseable, matching #196's identical
  choice (its Alternative B). One mental model, not two.
- **Alternative B — reuse `validate-evidence-table.sh` verbatim.** Rejected: that
  checker's header is the 4-column `# | Criterion | Verdict | Evidence` (a
  reviewer's table). The contract adds **Command** and **Expected** columns —
  verify-first means the command is named *before* the evidence exists. A separate
  6-column header keeps the two artifacts distinct (a reviewer's comment vs an
  implementer's worktree file) while sharing the placeholder/verdict logic. The
  new helper reuses that logic (copied, not imported — bash has no clean import;
  the #196 checker is the reference implementation and the regression test pins
  parity on the shared rules).
- **Alternative C — fold everything into the reviewer gate (no new artifact).**
  Rejected: that is the status quo, and it fires too late + off-worktree. The
  Factory lesson is *verify-first, on disk, by the implementer*. A new artifact
  is the point of the ticket.
- **Chosen:** a 6-column Markdown contract at `.hydra/contracts/<ticket>.md`
  (per-ticket, gitignored — #262; originally the committed worktree-root
  `validation-contract.md`), written first by the implementer + filled with
  evidence before the PR, plus a
  deterministic bash validator sharing #196's verdict/placeholder rules.

### #256 extension point (do not depend on it)

#256 (worker-validator) will consume `validation-contract.md` to drive an
independent validation pass. The format is kept stable + minimal for that: the
6-column table is the contract; a validator can read each row's Command and
re-run it. This spec records the seam — #256 reads the artifact, it does not
change the helper.

## Test plan

`scripts/test-validate-contract.sh` (bash, self-contained, pass/fail counter,
`NO_COLOR`-aware — same shape as `test-validate-evidence-table.sh`). The headline
assertion is the **RED → GREEN** pair:

1. **GREEN — complete contract → exit 0.** Every row has a command; every PASS
   has evidence; verdicts all legal. Reads `self-test/fixtures/validation-contract/green.md`.
2. **RED — assertion with empty Evidence on a PASS row → exit 1.** The core
   verify-first failure. Reads `self-test/fixtures/validation-contract/red.md`.
3. **RED — assertion with an empty Command cell → exit 1.** No command named =
   not a verify-first contract (regardless of verdict).
4. **PASS with placeholder evidence (`-`, `n/a`, `none`, backticks-only) → exit 1.**
5. **`UNVERIFIED` / `FAIL` with empty Evidence (but a command) → exit 0.** Allowed.
6. **Illegal verdict (`MAYBE`) → exit 1.**
7. **Zero assertion rows → exit 1.**
8. **Missing/garbled header → exit 2** (parse error).
9. **Reads from stdin and from `--file <path>`.**
10. **Escaped pipe `\|` in a Command/Evidence cell does not shift columns**
    (regression on the #196-shared splitter).
11. **`--help` → exit 0.**

Also run, and paste output into the PR:
- `bash scripts/test-validate-contract.sh` — the RED→GREEN proof.
- `self-test/run.sh --kind script` — no NEW failures vs baseline (note any
  pre-existing env-dependent failures, e.g. ajv/state-schemas).
- `scripts/validate-state-all.sh` — schema + CLAUDE.md size gate stays green.
- `scripts/preflight-syntax.sh` — bash -n + jq + spec frontmatter (this spec's
  frontmatter included).
- **Practice what we preach:** a filled contract for THIS ticket at
  `.hydra/contracts/<ticket>.md` (gitignored — #262; originally committed at the
  worktree root), passing `scripts/validate-contract.sh`.

## Risks / rollback

- **Risk: workers paste low-quality evidence to satisfy the helper** (copy the
  assertion into the Evidence cell). Mitigation: same as #196 — the helper
  enforces *presence*; quality stays a review-of-review concern; the reviewer + the
  operator see the table. Presence-checking is the mechanizable floor.
- **Risk: the artifact adds friction for trivial tickets.** Mitigation: a trivial
  ticket's contract is one row (e.g. "typo fixed" → `git diff` → the changed
  line). The worker-implementation prose scales the contract to the ticket, the
  same way the spec rule already does ("trivial tickets skip the spec but note
  why"). A one-row contract still proves the one thing changed.
- **Risk: the contract accidentally committed to a *target* repo** when Hydra
  works downstream repos. **Resolved by #262:** the artifact now lives at the
  gitignored, per-ticket path `.hydra/contracts/<ticket>.md` (`.hydra/` is in
  `.gitignore`), so it is worktree-local for BOTH Hydra's own tickets and external
  repos — never committed, never in a PR diff, no per-repo `.git/info/exclude`
  dance. (Originally this spec committed the contract for Hydra tickets; that
  caused the collision #262 fixed — `docs/specs/2026-06-08-contract-artifact-location.md`.)
- **Rollback:** revert the spec + delete the two scripts + the fixture dir + the
  agent-prose additions + the one CLAUDE.md line. Nothing else calls the helper;
  removal is clean. The contract degrades to "an extra markdown file in the
  worktree" if the helper is removed.
