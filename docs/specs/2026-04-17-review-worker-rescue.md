---
status: draft
date: 2026-04-17
author: hydra worker (ticket #75)
---

# Review-worker rescue — extend the watchdog to worker-review timeouts

## Problem

The worker timeout watchdog (PR #69, ticket #45) recovers `worker-implementation` runs that hit the 18-min stream-idle timeout: it probes the worktree, finds partial commits or dirty files, commits+rebases+pushes, and spawns a follow-up worker. That pattern works for implementation because the evidence of progress is **in the worktree** (uncommitted code + local commits).

`worker-review` workers have a different evidence shape. The artifact of a review is:

- a `gh pr review --comment` body posted to the PR, and/or
- a `commander-review-clean` label applied on the PR (or an equivalent review-blocker label).

If the review worker dies mid-run, the worktree is irrelevant — there is no code to rescue. The only visible signal is "did the review actually land on GitHub?" (Two recent review workers illustrated both ends of the failure: PR #68's review got partially posted before timeout; PR #70's review never posted a single byte. Commander had to re-run the review manually in both cases.)

Without a review-specific rescue path, the watchdog's `--probe` on a review worker's worktree would return `nothing-to-rescue` (correctly: there are no code changes to rescue), and commander would label the ticket `commander-stuck`. That's the wrong outcome — the *right* answer is "check GitHub for the review artifact, and if it's missing, have commander itself run the review." The current watchdog procedure has no hook for that.

## Goals / non-goals

**Goals:**

1. Extend `scripts/rescue-worker.sh` with a new exit code `4 = review-type rescue required; dispatch to commander`, so commander can tell the difference between "worker died cold, nothing to do" (current exit-via-probe `nothing-to-rescue`) and "worker died and the review artifact is missing, commander needs to take over" (new exit 4).
2. Extend the CLAUDE.md "Worker timeout watchdog" section with a **review-rescue path**: on a silent `worker-review`, commander checks the PR for a posted review body starting with "Commander review" (or an equivalent marker) OR for a `commander-review-clean` label. If neither is present, commander dispatches to itself (runs the review inline) and posts a consolidated comment noting "(auto-rescued after review-worker timeout)".
3. Add a self-test fixture step that simulates "no review posted, no label applied" and asserts `scripts/rescue-worker.sh` returns exit 4 in the review-rescue subcommand.

**Non-goals:**

- **Auto-re-spawning the review worker.** The ticket explicitly marks this out of scope; commander's fallback is to run the review itself on the main thread, not to spawn another `worker-review`.
- **Commander-side dispatch logic beyond the documented procedure.** This PR documents what commander should do and gives it the exit-code signal; it does not add a commander-side state machine, a retry limit, or a new `state/*.json` file.
- **Mutating the PR from `rescue-worker.sh`.** The script stays read-only in the review path — it only inspects GitHub via `gh` and emits the verdict. Any `gh pr review --comment` that lands post-rescue is authored by commander directly, not by the script.
- **Changing the existing `--probe` / `--rescue` verdicts or exit codes for `worker-implementation`.** This PR is purely additive: new subcommand (`--probe-review`), new exit code (4), same caller contract for existing flags.
- **Live execution of the full commander-side rescue dispatch.** Like the existing `worker-timeout-watchdog-rescue` SKIP stub, the review-rescue commander behavior is documented, not executed, until the worker-subagent executor (ticket #15 follow-up) lands. The script-level probe is live in CI today.

## Proposed approach

**Shape of the change:** a new `--probe-review <pr_number>` subcommand to `scripts/rescue-worker.sh`. It runs two `gh` lookups:

1. `gh pr view <pr> --json reviews` — does the review list contain any entry whose body starts with a commander review marker (`"Commander review"` — matches the canonical opening line the `/review` skill emits)?
2. `gh pr view <pr> --json labels` — is `commander-review-clean` present?

The verdict and exit code:

| Condition | stdout JSON | exit code |
|---|---|---|
| Review body present OR `commander-review-clean` label applied | `{"verdict":"review-already-landed", ...}` | 0 |
| Neither present | `{"verdict":"review-missing-dispatch-to-commander", ...}` | 4 |
| `gh` not available / auth failure | (stderr error message) | 1 |
| No `<pr>` arg | usage error | 2 |

Exit code 4 is new. It tells commander "the worker-review output did not land; you (commander) need to run the review yourself and post it." This is intentionally orthogonal to the existing codes (0/1/2/3) so existing callers of `--probe` / `--rescue` are unaffected.

**Why a new subcommand instead of a verdict-only change to `--probe`:** `--probe` inspects a worktree; `--probe-review` inspects a PR on GitHub. They need different positional args (worktree+branch+ticket vs. pr-number) and different guard rails (worktree mode refuses if HEAD doesn't match `<branch>`; PR mode has no worktree to guard). Keeping them as distinct subcommands makes the script's contract auditable — each flag has one job.

**CLAUDE.md "Worker timeout watchdog" extension:** add a new sub-section "Review-worker rescue" describing the detection trigger (silent `worker-review` past 12 min, no review artifact on the PR), the three-step procedure (probe-review → if exit 4, run the review inline and post with the "auto-rescued" note), and the safety guarantees (same 12-min threshold, same non-mutating probe principle, no PR mutation from the script itself).

**Self-test fixture:** extend `self-test/fixtures/rescue-worker/run.sh` with three new steps that exercise `--probe-review` **without hitting GitHub**. The script is structured to accept a `HYDRA_RESCUE_GH_MOCK=<path>` env var pointing at a mock directory: when set, `gh pr view` is intercepted and responses are read from files in that directory (`reviews-<pr>.json`, `labels-<pr>.json`). The fixture seeds three cases: (a) review-already-landed via body match, (b) review-already-landed via label, (c) no review + no label → exit 4. This keeps CI offline, same pattern as the existing probe fixture.

### Alternatives considered

- **Alternative A — auto-re-spawn `worker-review` on exit 4.** Symmetric with the implementation rescue path (which spawns a follow-up `worker-implementation`). Cost: a second silent timeout on the respawned worker leads to a rescue loop — and the ticket explicitly excludes this. Rejected because the ticket specifies "commander falls back to running `/review` itself" as the correct behavior; re-spawning would just re-run the same failure mode.

- **Alternative B — merge review-rescue into the existing `--probe` verdicts.** Add a fifth verdict `"review-missing"` that `--probe` emits when the worktree is empty AND the branch is a review worker's branch. Cost: `--probe` would need to know "is this a review worker?" (via a new positional arg or a branch-name heuristic), and the guard rails (refuse on worktree mismatch) would need to become conditional. Rejected — a new subcommand is cleaner than overloading `--probe`.

- **Alternative C — skip the exit code, encode the decision entirely in CLAUDE.md.** Commander could inspect the PR itself (via `gh`) after a timeout and decide without a script helper. Cost: duplicates logic (commander and the watchdog script both doing `gh pr view` with the same JSON-parsing rules), and loses the testable seam that a self-test fixture can drive. Rejected because the rest of the watchdog lives in `scripts/rescue-worker.sh` — adding this as a peer subcommand keeps the surface area coherent.

## Test plan

**Goal 1 — new exit code 4 + `--probe-review` subcommand in `scripts/rescue-worker.sh`:**

- `bash -n scripts/rescue-worker.sh` passes (enforced by CI `syntax` job).
- `scripts/rescue-worker.sh --help` mentions `--probe-review` and exit code 4.
- `scripts/rescue-worker.sh --probe-review` with no PR arg exits 2 (usage error).
- `scripts/rescue-worker.sh --probe-review 999 --gh-mock <dir>` with a mock responding "review already landed" returns exit 0 and emits `"verdict":"review-already-landed"` on stdout.
- `scripts/rescue-worker.sh --probe-review 999 --gh-mock <dir>` with a mock responding "no review, no label" returns exit 4 and emits `"verdict":"review-missing-dispatch-to-commander"` on stdout.

**Goal 2 — CLAUDE.md review-rescue procedure documented:**

- Manual review of the new "Review-worker rescue" sub-section under "Worker timeout watchdog" — the detection trigger, the three-step procedure, and the "auto-rescued after review-worker timeout" comment marker are all spelled out.
- The `spec-presence-check.sh` CI job passes (this spec file exists and is referenced in the PR body).

**Goal 3 — self-test fixture step asserts exit 4 on the no-review scenario:**

- `self-test/fixtures/rescue-worker/run.sh` gains three new blocks: review-already-landed-by-body, review-already-landed-by-label, and review-missing → exit 4. The fixture uses `HYDRA_RESCUE_GH_MOCK` to avoid network calls.
- `self-test/golden-cases.example.json`'s `worker-timeout-watchdog-script` entry picks up the extended fixture run via the existing "fixture roundtrip" step — no new golden case, just more coverage inside the same fixture.

**Out of scope for the test plan:** the commander-side dispatch of the inline review itself (posting the auto-rescued comment, consolidating verification scripts) — same blocker as the existing `worker-timeout-watchdog-rescue` SKIP stub, noted in CLAUDE.md.

## Risks / rollback

- **Risk: the "Commander review" body-prefix heuristic false-matches an unrelated review comment and commander skips the rescue even though the review didn't actually land.** Mitigation: the canonical opening line of `/review` output is stable (it has been for 6+ months across the `superpowers:review` and `gstack:review` skills); the fixture asserts exact-prefix match so any skill-output drift would break CI. A more robust alternative — a machine-readable marker (e.g. an HTML comment `<!-- commander-review -->`) at the top of every posted review body — is noted as a follow-up if the prefix heuristic ever fires a false positive in practice.

- **Risk: `gh pr view --json reviews` returns a stale / cached response and commander thinks the review already landed when it hasn't.** Mitigation: `gh` doesn't cache by default; a 30-second eventual-consistency window on GitHub's side is a documented ceiling. The watchdog only fires 12+ min after spawn, well past the consistency window. If a review *truly* posted in the last 30 seconds of the silent window, the worker is healthy and the rescue path correctly no-ops.

- **Risk: exit code 4 collides with a future `rescue-worker.sh` exit code.** Mitigation: the exit codes are documented in the script header (`0` success, `1` I/O, `2` usage, `3` rescue-conflict, `4` review-type rescue required) and in CLAUDE.md's watchdog section; any future code must pick an unused number.

- **Risk: the `--gh-mock` test-only hook leaks into production use.** Mitigation: the hook is a scoped env-var check (`HYDRA_RESCUE_GH_MOCK`); unset in production. The fixture is the only caller. If this pattern catches on, we can revisit whether to make it a first-class dependency-injection mechanism for the whole watchdog — for now it's an internal test seam.

**Rollback:** revert the commit that adds the `--probe-review` subcommand + CLAUDE.md sub-section + fixture steps. Commander falls back to the legacy "operator notices missing review, runs `/review` by hand" path. The implementation-side watchdog (PR #69) is unaffected — this PR is purely additive.

## Implementation notes

(Filled in after the PR lands.)
