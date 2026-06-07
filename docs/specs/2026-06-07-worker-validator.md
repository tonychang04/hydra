---
status: accepted
date: 2026-06-07
ticket: https://github.com/tonychang04/hydra/issues/256
area: worker contract / review gate / quality
size: M
authors: [worker-implementation]
supersedes: []
extends:
  - docs/specs/2026-06-07-validation-contract.md
  - docs/specs/2026-05-21-evidence-based-review-gate.md
  - .claude/agents/worker-review.md
  - .claude/agents/worker-implementation.md
---

# worker-validator — black-box runtime validation (re-run the contract for truth)

## Problem

#255 gave Hydra a per-ticket **`validation-contract.md`**: each acceptance
criterion → the command that proves it → captured EVIDENCE (command + exit code +
output snippet), gated by `scripts/validate-contract.sh`. The #255 review found
the remaining gap, and it is the whole reason #256 exists:

> **presence ≠ truth.** `validate-contract.sh` checks that every PASS row carries
> *non-empty, non-placeholder* evidence. It does **not** re-run the command. A
> worker can paste `echo works` (or copy the assertion text) into the Evidence
> cell for a command that, when actually run, *fails* — and the contract gate
> passes anyway. The gate enforces that the worker *wrote down* a proof, not that
> the proof is *real*.

This is exactly the **Factory Missions "black-box validator / never trust chat
output"** lesson the operator captured (`memory reference_factory_missions_lessons`):
Factory runs TWO validator types at each milestone — *scrutiny* (review quality,
= Hydra's `worker-review`) AND *black-box user-testing* that exercises the system
"the way a real user would" — because Factory found implementers and
scrutiny-reviewers cannot objectively judge runtime behavior. Hydra today has
only the scrutiny side (`worker-review`). The trust boundary is still "the
worker's own pasted text."

## Goals

1. A new **`worker-validator`** subagent that, given a PR + its
   `validation-contract.md`, **RE-RUNS each assertion's Command itself** in the
   PR's worktree, compares the *actual* exit code / output to the contract's
   `Expected` column, and reports a PASS/FAIL verdict with **freshly-captured**
   evidence. It does **NOT** trust the worker's pasted Evidence cell. It makes
   **NO code changes** (read + execute only, like `worker-review`).
2. **Conditional UI/behavioral validation** (mirror Factory's `skipUserTesting`
   toggle): re-running the contract's commands applies to **ALL** tickets; the
   additional **browser / computer-use** validation (drive the app via the
   `browse` / `verify` skills, assert behavioral state) runs **ONLY for
   UI/behavioral tickets**. Spec / script / backend tickets skip the browser leg
   — their contract commands already are the black-box test.
3. A deterministic helper **`scripts/revalidate-contract.sh`** that re-executes a
   contract's commands and diffs *actual* exit/output against the contract's
   `Expected` + claimed Verdict, so a contract whose pasted evidence **LIES**
   (`echo works` as evidence for a command that actually fails) is **caught**.
   RED → GREEN fixtures prove it.
4. Wire `worker-validator` into the review gate **AFTER** `worker-review`: a
   failed re-run is a **blocker** (re-spawn implementation); a clean re-run lets
   the PR proceed to surface. This **EXTENDS** the #255/#196 gates; it does not
   replace either.

## Non-goals

- **Not a deploy controller / prod canary.** Hydra stops at the draft PR
  (`CLAUDE.md` identity: "deploy controller (stops at PR)"). The validator runs
  the contract's commands **in the worktree / CI sandbox**, never against
  production or a deployed environment. The `browse`/`verify` leg drives a
  **locally-run** app (the worker starts it under the anti-stall background+kill
  pattern), not a live deployment.
- **Does NOT replace `worker-review` (scrutiny) or the `validate-contract.sh`
  presence gate.** Three layers, one philosophy ("no PASS without *real*
  evidence"): (a) implementer writes+fills the contract (#255); (b) `worker-review`
  scrutinizes the diff + checks the contract *presence* gate (#196/#255); (c)
  `worker-validator` RE-RUNS the contract for truth (#256). Distinct lifecycles,
  distinct trust boundaries.
- **Does NOT change `validate-contract.sh`.** That helper stays a pure
  presence/shape validator. `revalidate-contract.sh` is a **separate** helper
  (re-execution is a fundamentally different, side-effecting operation — it runs
  arbitrary commands — so it must not be folded into the presence gate the
  reviewer/implementer run liberally).
- **No new contract format.** `worker-validator` consumes the existing 6-column
  `validation-contract.md` verbatim via the seam #255 already documented
  ("#256 extension point … a validator can read each row's Command and re-run
  it"). No artifact divergence.
- **Not an auto-merger.** Like every Hydra gate, a clean validation surfaces the
  PR for the operator's merge decision (tier-aware merge policy unchanged).

## Proposed approach

### Where the pieces live

| File | Change |
|---|---|
| `docs/specs/2026-06-07-worker-validator.md` | This spec. |
| `.claude/agents/worker-validator.md` | New subagent: re-run the contract, conditional UI leg, report PASS/FAIL with fresh evidence; NO code changes. |
| `scripts/revalidate-contract.sh` | New. Re-executes each contract row's Command, captures actual exit/output, diffs against `Expected` + claimed Verdict; exits nonzero when a claimed-PASS row does NOT reproduce (lying evidence). |
| `scripts/test-revalidate-contract.sh` | New. Self-contained RED→GREEN regression (bash, pass/fail counter, `NO_COLOR`-aware — same shape as `test-validate-contract.sh`). |
| `self-test/fixtures/revalidate-contract/` | New. `lying.md` (PASS evidence for a command that actually fails → caught) + `honest.md` (commands actually reproduce → clean). |
| `self-test/golden-cases.example.json` | New `revalidate-contract-script` script-kind case so the harness exercises the helper. |
| `.claude/agents/worker-review.md` | One note: review is *scrutiny*; runtime truth is `worker-validator`'s job, dispatched after review (cross-reference, no behavior change to the reviewer). |
| `CLAUDE.md` | Worker-types table: one new row (`worker-validator`); review-gate paragraph: one clause on the post-review validation step. Offset by a trim (size band guard). |

### `scripts/revalidate-contract.sh` — the truth check

The helper is the deterministic core the agent leans on (the agent adds judgment
+ the conditional UI leg; the helper does the mechanical re-run so the result is
reproducible and self-testable).

**Input:** a `validation-contract.md` (via `--file <path>`, default stdin) and an
optional `--cwd <dir>` (the worktree the commands should run in; default `.`).

**For each data row of the contract table** (parsed with the **same** splitter /
placeholder / verdict rules as `validate-contract.sh` — copied, not imported;
bash has no clean import, and `validate-contract.sh` is the reference the
regression pins parity against):

1. Read `Command`, `Expected`, claimed `Verdict`.
2. **Skip rows the validator must not run:**
   - `UNVERIFIED` rows — the worker declared they could not be run; re-running
     is out of scope (e.g. "needs production data"). Reported as `SKIPPED`.
   - Rows whose Command is flagged non-reexecutable (a `# manual` / `# ui`
     marker, or an empty/placeholder command — though #255's gate already
     rejects empty commands). UI-only assertions are validated by the agent's
     browser leg, not this helper.
3. **Re-run** the Command in `--cwd`, under a portable **background + `sleep N &&
   kill` bound** (default 120s; macOS lacks `timeout` — never assume it), capture
   the **actual exit code** and a stdout/stderr snippet.
4. **Compare** actual vs claimed:
   - `Expected` parsing is intentionally lenient (it is human prose). The helper
     recognizes the common machine-checkable forms and otherwise falls back to
     exit-code agreement:
     - `Expected` mentions `exit <N>` (e.g. `exit 0`, `exit 1`) → assert actual
       exit == N.
     - else `Expected` has no parseable exit → for a claimed `PASS`, require
       actual **exit 0** (a passing command convention); for a claimed `FAIL`,
       require actual **nonzero**.
     - If `Expected` ALSO quotes an output substring (backtick- or quote-wrapped),
       require that substring to appear in the captured output (best-effort; a
       missing substring on an otherwise exit-matching row is a `WARN`, not a
       hard fail, because output snippets drift — exit code is the hard signal).
   - **Verdict reproduction (the lying-evidence catch):** a row claiming `PASS`
     whose re-run does **not** satisfy the expectation (wrong exit, or the
     command itself errors) is a **MISMATCH** → nonzero exit. This is precisely
     the `echo works`-as-evidence-for-a-failing-command case.
5. **Report** a per-row result line (`OK` / `MISMATCH` / `SKIPPED` / `WARN`) with
   the freshly-captured exit + snippet, then a summary.

**Exit codes:**
- `0` = every re-runnable row reproduced its claimed PASS expectation (UNVERIFIED
  / SKIPPED rows do not fail the gate; WARNs do not fail the gate).
- `1` = at least one claimed-PASS row did NOT reproduce (lying / stale evidence).
- `2` = usage / parse error (no contract table, unreadable file, bad header) —
  same contract as `validate-contract.sh`.

**Safety of executing arbitrary commands:** the helper runs the contract's own
commands — which the implementer wrote and the reviewer already read — in the
worktree, bounded by the kill watchdog. This is the same trust model as the
worker running its own tests; the validator is a *second, independent* runner of
those same commands, which is the entire point ("never trust chat output; run it
yourself"). The agent file documents that the validator must NOT run a contract
it has not had a chance to read (a command-injection guard is out of scope for
Hydra-internal contracts the reviewer vetted; noted as a future hardening if
downstream/untrusted contracts ever feed it).

### `worker-validator` subagent

Frontmatter mirrors `worker-review` (isolation: worktree; `memory: project`;
`disallowedTools: WebFetch, WebSearch`; no code-change tools used). Skills: it
lists `browse` / `verify` for the conditional UI leg. **Flow:**

1. Step 0 orient (read `using-hydra-skills` dispatcher, `CLAUDE.md`, the contract
   spec + this spec, `learnings-hydra.md`).
2. `gh pr view <n>` + locate the PR's worktree; find `validation-contract.md` at
   the worktree root. **No contract present** → report `UNVALIDATED (no contract)`
   and return (during rollout, the same way the reviewer treats a missing
   contract as a Concern, not a hard block) — do not fabricate a verdict.
3. **Re-run leg (ALL tickets):** `bash "$COMMANDER_ROOT/scripts/revalidate-contract.sh"
   --file "<wt>/validation-contract.md" --cwd "<wt>"`. Nonzero → a `FAIL` row
   exists (lying / stale evidence) → **blocker**.
4. **UI/behavioral leg (ONLY UI/behavioral tickets):** detect via the ticket's
   labels / PR file globs (`*.tsx`, `*.css`, `packages/dashboard/**`) or an
   explicit `ui: on` spawn hint. For these, additionally start the app locally
   (anti-stall background+poll+kill) and drive it with `browse`/`verify` to
   assert the behavioral criteria the contract names. Non-UI tickets **SKIP**
   this leg and say so explicitly (`skipUserTesting: true`).
5. **Report** a VALIDATION verdict (PASS / FAIL / UNVALIDATED) with the
   freshly-captured evidence (NOT the contract's pasted evidence). Post via
   `gh pr review` (comment, or `--request-changes` on a blocker) and apply
   `commander-validated` (clean) or `commander-stuck` (blocker) via REST.
6. **NO code changes, no commits, no merges** — same hard rails as `worker-review`.

### Review-gate composition (after `worker-review`)

```
worker-implementation opens PR
   → worker-review (scrutiny: /review + evidence table + contract PRESENCE gate)
   → worker-validator (truth: RE-RUN contract commands; UI leg if UI ticket)
        ├─ re-run FAIL (lying/stale evidence)  → blocker → re-spawn implementation
        └─ re-run clean                        → surface "PR #N passed review + validation"
```

The validator is a *separate worker after the reviewer* (Factory's two-validator
shape) so the runtime-truth judgment is not biased by the scrutiny pass — the
same isolation rationale that keeps review separate from implementation.

### Alternatives considered

- **A — fold re-run into `worker-review`.** Rejected: re-running commands is
  side-effecting (it executes arbitrary shell), takes time, and is the *black-box*
  half Factory deliberately separates from scrutiny. Bundling them re-introduces
  the bias the separation exists to remove and makes the reviewer slower/stallier.
- **B — extend `validate-contract.sh` to re-run.** Rejected: that helper is run
  liberally (by the implementer pre-PR, by the reviewer) as a *cheap, pure*
  presence check. Making it execute arbitrary commands changes its safety profile
  and would surprise every existing caller. A separate `revalidate-contract.sh`
  keeps presence (cheap, pure) and truth (side-effecting, slower) cleanly split.
- **C — always run the browser leg.** Rejected: most Hydra tickets are
  specs/scripts/backend; a browser pass for them is pure cost with nothing to
  drive. Factory's `skipUserTesting` toggle is the precedent: re-run always, UI
  leg conditionally.
- **Chosen:** a new after-review `worker-validator` + a separate
  `revalidate-contract.sh` truth helper, re-run for all tickets, browser leg only
  for UI/behavioral tickets, consuming the #255 contract verbatim.

## Test plan

`scripts/test-revalidate-contract.sh` (bash, self-contained, pass/fail counter,
`NO_COLOR`-aware). The headline is the **lying-evidence RED → GREEN** pair:

1. **RED — lying evidence caught.** `self-test/fixtures/revalidate-contract/lying.md`:
   a row claims `PASS` with pasted evidence "works", but its Command actually
   exits nonzero → `revalidate-contract.sh` re-runs it, sees the real failure,
   exits **1**. (Without #256, `validate-contract.sh` would have passed this file
   — the test asserts that too, proving the gap #256 closes.)
2. **GREEN — honest contract reproduces.** `self-test/fixtures/revalidate-contract/honest.md`:
   every claimed-PASS Command actually reproduces its expectation → exit **0**.
3. **`exit <N>` expectation matching** — a row whose `Expected` says `exit 1` and
   whose command really exits 1 with `PASS` claim → OK (it correctly expects a
   nonzero-exit command to be the proof, e.g. "helper rejects bad input").
4. **`UNVERIFIED` rows are SKIPPED, not run** (no live-DB attempt) → do not fail
   the gate.
5. **Output-substring drift is a WARN, not a hard fail** (exit matches, snippet
   differs) → exit 0.
6. **`--cwd <dir>`** runs commands in the given directory.
7. **No contract table → exit 2**; **`--help` → exit 0**.
8. **`revalidate` shares `validate-contract`'s splitter** on an escaped-pipe
   command (no column shift).

Also run + paste into the PR:
- `bash scripts/test-revalidate-contract.sh` — the lying-evidence RED→GREEN proof.
- `bash scripts/test-validate-contract.sh` — #255's test still green (parity).
- `self-test/run.sh --kind script` — no NEW failures vs the documented baseline
  (the pre-existing `state-schemas` / ajv `SKIP_HAS_AJV` case is the only red).
- `scripts/validate-state-all.sh` — schema + CLAUDE.md size gate stays green.
- `scripts/preflight-syntax.sh` — bash -n + jq + spec frontmatter (this spec
  included; `.claude/agents/worker-validator.md` frontmatter valid).
- `scripts/validate-contract.sh` on THIS ticket's own `validation-contract.md`
  (dogfood #255), AND `scripts/revalidate-contract.sh` on it (dogfood #256:
  re-run my own contract for truth).

## Risks / rollback

- **Risk: re-running commands has side effects** (a contract command that writes
  files / hits a network). Mitigation: the helper runs in the worktree sandbox
  under a kill bound; the contract commands are the same ones the implementer
  already ran; UNVERIFIED rows (the ones that need external resources) are
  skipped. Document in the agent file that the validator runs in an isolated
  worktree, never against prod.
- **Risk: false MISMATCH from output-snippet drift** (timestamps, ordering).
  Mitigation: exit code is the hard signal; an output-substring mismatch on an
  otherwise exit-matching row is a WARN, not a fail.
- **Risk: lenient `Expected` parsing misjudges a row.** Mitigation: the helper's
  fallback (claimed PASS ⇒ require exit 0) is the safe default; the
  regression test pins the parse cases. A genuinely ambiguous Expected that the
  worker wants the validator to honor exactly should say `exit <N>` — documented
  in the agent file + the #255 contract guidance.
- **Risk: the UI leg stalls the validator** (dev server foregrounded).
  Mitigation: the agent file mandates the same anti-stall background+poll+kill
  pattern as `worker-implementation` / `worker-review`; the browser leg is
  bounded.
- **Rollback:** revert the spec + delete `worker-validator.md` + the two scripts
  + the fixture dir + the golden case + the CLAUDE.md row/clause + the
  worker-review cross-reference note. The #255 contract + presence gate keep
  working unchanged; removal is clean (nothing else calls `revalidate-contract.sh`).
</content>
</invoke>
