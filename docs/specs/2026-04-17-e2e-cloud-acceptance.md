---
status: draft
date: 2026-04-17
author: hydra worker (ticket #127)
---

# Live cloud E2E acceptance test — "assign ticket, sleep, wake up to merged PR"

## Problem

Every feature this session has shipped in isolation: `fly deploy` (#119), MCP
bearer registration, autopickup ticks, the review gate, per-repo merge policy.
Nothing proves the **complete loop in cloud mode** — the one claim that
separates "Hydra with infrastructure" from "Hydra that works." CLAUDE.md's north
star is: _the machine runs while the operator sleeps._ There is no scripted
acceptance test that proves THIS, so a regression in any one subsystem (deploy,
tick scheduling, review-gate labelling, auto-merge) could silently break the
end-to-end promise and no signal would fire until a human noticed at a dogfood.

We need one executable that walks the entire "operator goes offline → wakes to a
merged PR" loop, fails loudly with `step N: expected X, got Y` on any break, and
— critically — can be **exercised offline with zero real cloud side effects** so
the orchestration itself is regression-protected in CI even though a real Fly run
costs compute and depends on prereqs that are out of scope for this build.

## Goals / non-goals

**Goals:**

- `scripts/e2e-cloud-acceptance.sh` orchestrates the 9-step loop from the ticket
  (deploy → register bearer → enable autopickup → assign issue → disconnect →
  wait for tick → poll for PR → reconnect+verify → auto-merge), exiting 0 only
  if the full loop succeeds.
- On ANY step failure: a clear error naming the step number, what was expected,
  and the actual state observed.
- A `--dry-run` mode that runs the whole script end-to-end against a **mocked Fly
  API + mocked GitHub state machine**, with provably zero real side effects
  (no real `fly` / `gh` / `curl` / `./hydra` invocation, no lingering infra).
- The dry-run reuses the existing `examples/hello-hydra-demo/` fixture and its
  `fixture-issues/` — no new fixture repo invented.
- Deterministic clock for the "wait for tick" step via `HYDRA_FAKE_NOW` (no
  multi-minute real sleeps; anti-stall safe).
- A self-test case `e2e-cloud-dry-run` wired into `self-test/golden-cases.example.json`
  that runs the dry-run and asserts no side effects.
- A README status badge (passed / failing / not-yet-run) and a runbook section.

**Non-goals:**

- Running this in CI on every PR against a real Fly machine (costs real compute;
  operator-run for now). Only the **dry-run** is CI-wired.
- A green **real** cloud run. That depends on #119 (`fly deploy`), #123 (launcher
  auto-regen), #115 (memory-sync prefix) which are out of scope here. Real mode
  is wired structurally and gated behind a prereq check; it is NOT claimed green
  by this PR.
- Multi-ticket parallel E2E (single-ticket loop proves the flow).
- Historic run snapshotting / regression diffing of runs.

## Proposed approach

A single bash script mirroring the house style of `scripts/hydra-migrate-to-cloud.sh`
(the closest existing analog: a multi-step cloud orchestration with a `--dry-run`
that turns every side effect into a `DRY RUN:` log line). Shared idioms reused
verbatim: the `say/ok/warn/fail/dim/dry` helpers, the `FLY_BIN` dispatch, the
`run_cmd` "log-don't-exec in dry-run" wrapper, and the auto-detect of a missing
`flyctl` as a notice (not a hard fail) in dry-run so the rehearsal runs on a box
with no flyctl installed (e.g. CI).

**The 9 steps**, each wrapped in a `step_begin N "<name>"` / `step_ok` /
`step_fail N "<name>" "<expected>" "<actual>"` frame:

1. **Fresh Fly deploy** — real: `fly deploy --app $APP --config infra/fly.toml`;
   dry: log + write mock `fly-app.json {status: deployed, health: ok}`.
2. **Register MCP bearer** — real: `fly ssh console -C './hydra mcp register-agent <id>'`;
   dry: log + write a clearly-fake mock bearer (`MOCK-…`, never a real token).
3. **Enable autopickup** — real: flip `state/autopickup.json:enabled=true` on the
   cloud commander; dry: write mock `autopickup.json {enabled: true, interval}`.
4. **Assign fixture issue #1** — real: `gh issue edit 1 --add-assignee …`
   (honoring #26 assignee_override); dry: write mock `issue-1.json {assignee}`.
5. **Disconnect** — the operator simulator goes offline. Pure log line in both
   modes; the script does not exit, it just stops "interacting."
6. **Wait for the autopickup tick** — real: poll until the cloud tick fires,
   clamped by `HYDRA_FAKE_NOW` / a short `--tick-interval`; dry: advance the
   simulated clock and materialize the mock PR (`pr.json {number, draft:true}`)
   with no real sleep.
7. **Poll for PR creation** — bounded poll loop (emits a line each iteration →
   anti-stall safe) against real `gh pr list` or the mock `pr.json`.
8. **Reconnect + verify** — assert: PR exists, CI green, `commander-review-clean`
   label applied. Real: `gh pr view` + `gh pr checks`; dry: read the mock.
9. **Flip to T1 auto-merge + confirm merged** — real: merge-policy lookup + merge;
   dry: mark mock PR merged and assert `merged:true`.

**Mock state machine (dry-run):** a single `mktemp -d` directory holds small JSON
files representing the simulated Fly app + GitHub state. Each step writes/reads
these instead of touching the network. Because no step ever shells out to
`fly`/`gh`/`curl`/`./hydra` in dry-run, the "zero side effects" property is
testable the same way the `migrate-to-cloud-dry-run` golden case proves it:
stage a `PATH` of stub binaries that scream + `exit 99` if invoked, run the
dry-run, and assert none were called.

**Cleanup:** a single `trap cleanup EXIT INT TERM` removes the mock dir (dry-run)
or tears down the Fly app (real mode, best-effort `fly apps destroy --yes` unless
`--keep`), satisfying the ticket's "no lingering Fly infrastructure after success
OR failure" requirement.

**Real-mode prereq gate:** real mode requires `fly` + `gh` + `curl` +
`infra/fly.toml`; if any is missing it exits 3 naming the out-of-scope prereqs
(#119/#123/#115). Real mode is wired but explicitly not verified by this PR.

**README badge:** a shields.io badge seeded to `not yet run`. The script prints,
at the end of every run, the exact badge markdown for the just-observed result so
an operator can paste it after a real run. The script does NOT mutate tracked
files on its own.

### Alternatives considered

- **Alternative A — localstack for the mock.** The ticket mentions localstack.
  Rejected: localstack mocks AWS, not the Fly API or GitHub; it would add a heavy
  docker dependency that breaks the "runs offline in CI with just bash+jq"
  property the self-test needs. A tiny in-repo JSON state machine is lighter,
  deterministic, and has zero external deps — matching how every other Hydra
  self-test fixture works.
- **Alternative B — drive the real `autopickup-tick.sh` in dry-run.** Rejected
  for this build: the tick orchestrator reaches into real `gh`/state; faking its
  whole environment is more surface than the loop needs to prove. The mock state
  machine models the *observable contract* (a PR appears, gets labelled, merges)
  which is what the acceptance test asserts. A future ticket can deepen the
  dry-run to drive the real tick once #119/#123/#115 land.
- **Alternative C — script mutates the README badge every run.** Rejected: a
  test that writes to a tracked file on every invocation creates diff churn and
  risks committing a transient "failing" badge. Printing the paste-ready badge
  line keeps the run side-effect-free.

## Test plan

- **Self-test golden case `e2e-cloud-dry-run`** (`kind: script`, no `requires`,
  runs anywhere bash+jq is present) added to `self-test/golden-cases.example.json`:
  1. `bash -n` clean.
  2. `--help` prints the usage block.
  3. `--help` advertises `--dry-run`.
  4. `--dry-run` completes exit 0 and reports all 9 steps + "E2E dry-run complete".
  5. `--dry-run` with a stub `PATH` does NOT invoke real `fly`/`gh`/`curl`/`claude`
     (the zero-side-effects assertion, mirroring `migrate-to-cloud-dry-run`).
  6. `--dry-run` does not leak fake secret values into output.
  7. `--dry-run` leaves no lingering mock dir (cleanup trap fired).
- **Manual:** `bash scripts/e2e-cloud-acceptance.sh --dry-run` exits 0 with the
  9-step trace; captured exit code + output tail pasted into the PR body.
- **`shellcheck scripts/e2e-cloud-acceptance.sh`** clean (where shellcheck is on
  PATH); covered ambiently by `scripts/test-cloud-config.sh`'s `bash -n` loop.
- The added assertions only *increase* `self-test/baseline.json`'s net count, so
  the coverage guard cannot regress; no baseline bump needed.

## Risks / rollback

- **Risk: the dry-run diverges from real behavior** (the mock passes but a real
  run would fail). Mitigation: the mock models only the observable acceptance
  contract, and real mode runs the SAME step sequence with the real commands; the
  spec is explicit that a green dry-run is NOT a green real run. A future ticket
  hardens real mode once prereqs land.
- **Risk: a long real-mode poll stalls a worker/operator.** Mitigation: all poll
  loops are bounded (`--poll-timeout`) and emit a line each iteration; dry-run
  never sleeps (clock is faked).
- **Risk: real mode leaves a Fly app running on failure.** Mitigation: the
  `trap cleanup EXIT INT TERM` tears down on every exit path unless `--keep`.
- **Rollback:** the script is additive and operator-invoked; deleting
  `scripts/e2e-cloud-acceptance.sh`, the spec, the badge line, the runbook
  section, and the golden case fully reverts with no behavioral impact on the
  rest of Hydra.
