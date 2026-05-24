---
status: draft
date: 2026-05-24
author: hydra worker (tickets #220 / #222)
---

# Worker anti-stall discipline: no foreground-blocking commands; `/codex review` off by default

**Tickets:**
- [#220 — Foreground blocking commands (dev server / full test suite) trip the 600s stall watchdog — workers killed, work lost](https://github.com/tonychang04/hydra/issues/220)
- [#222 — worker-review reliably stalls on `/codex review` (600s kill before posting)](https://github.com/tonychang04/hydra/issues/222)
- Related: [#219 — Workers can finish with verified work UNCOMMITTED](https://github.com/tonychang04/hydra/issues/219) (recoverability sibling)

## Problem

The Hydra harness runs a **600s no-progress stall watchdog**: a worker that emits
no stream output for ~600 seconds is assumed dead and killed, taking any
uncommitted work with it. On 2026-05-23 (dogfooding) this killed **four-plus
workers in a single session**, all from the same family of root cause — a worker
ran a command that produces no stream output for a long stretch:

1. **`mcp-sentinel` #1** started a **foreground dev server** (`npm run dev` =
   `vite`, which never exits) for an auth smoke test. Vite serves and blocks; no
   stream output → 600s kill → the **entire scaffold lost uncommitted**.
2. **`hydra review` #218** ran the **full self-test suite** (long and quiet) →
   killed before posting its review.
3. **`hydra review` for PR #8** ran `/codex review`, then "waited for it by
   monitoring the output file" — the worker polls a file in a loop, emitting no
   stream output → 600s kill → **no review posted**. Memory records the identical
   failure on prior reviews #181 / #182 / #187.

There are three distinct but related root causes:

- **RC-1 — long-lived / quiet FOREGROUND commands.** Dev servers (`vite`,
  `npm run dev`, anything with `--watch`) never return; full test suites and big
  builds run quietly for minutes. Foregrounded, they starve the stream and the
  watchdog kills the worker (#220).
- **RC-2 — `timeout` is not portable.** The natural mitigation "wrap the slow
  command in `timeout`" **silently fails on macOS**, which ships neither
  `timeout` nor `gtimeout` (the binary is absent; the shell returns exit **127**,
  "command not found"). Guidance that assumes `timeout` exists is a no-op on the
  operator's host.
- **RC-3 — `/codex review` is a foreground-blocking command in disguise.**
  `/codex review` spawns the long-running codex CLI; the review worker then waits
  by polling an output file, emitting no stream output. It is the single most
  reliable way for `worker-review` to die (#222), and it dies *before* it can
  synthesize and post — so the whole review is lost, not just the codex portion.

This compounds #219 (workers can finish with verified work uncommitted): a stall
kill on uncommitted work is unrecoverable, whereas a stall on a worker that has
committed + pushed + opened a draft PR leaves a recoverable artifact. The
**early-PR skeleton-first doctrine** (#188, `docs/specs/2026-05-21-early-pr-skeleton-first.md`)
is the recoverability half; this spec is the prevention half — stop emitting the
commands that trigger the kill in the first place. #188's spec explicitly flagged
the `worker-review.md` / time-box-`/codex` work as follow-up #199; this spec is
that follow-up, generalized to cover the foreground-command family too.

## Goals

- Add an **"Anti-stall discipline"** section to **both**
  `.claude/agents/worker-implementation.md` and `.claude/agents/worker-review.md`
  stating the three rules:
  1. **Never foreground a long-lived / quiet command.** Prefer build-only
     verification that EXITS (`npm run build`, `npm test` / `vitest run`) over
     anything that serves or watches.
  2. **To run a server for a runtime check:** background it, poll with `curl`,
     then KILL it — never leave it in the foreground.
  3. **Do not assume `timeout` exists** (absent on macOS → exit 127). To bound a
     command, use a backgrounded `sleep N && kill <pid>` watchdog pattern.
- In `worker-review.md` specifically: make **`/codex review` OFF by default**.
  The default review gate is `/review` + the worker's own structured read + a
  LOCAL build/test pass. Codex becomes **opt-in only**, and when opted in it must
  run with a bounded wait that emits periodic progress and falls back to posting
  a partial review. Document *why* (RC-3).
- Reinforce the **commit + push frequently** doctrine (early-PR #188) in both
  agent files so a stall is always recoverable.
- A self-test fixture asserts the anti-stall doctrine is present in both agent
  files and that the codex-off-by-default rule is documented in `worker-review.md`
  — and stays there.
- A **one-line** CLAUDE.md pointer to this spec (procedures live in the spec, per
  the CLAUDE.md scope rule).

## Non-goals

- **Changing the harness watchdog itself** (the 600s threshold, the rescue
  mechanism, `scripts/rescue-worker.sh`). This spec changes worker *behavior* so
  the watchdog stops firing on healthy workers; it does not touch the watchdog.
- **Removing `/codex review` from Hydra entirely.** Codex stays available as an
  opt-in adversarial second opinion; it is only removed from the *default* gate.
  Commander may still run codex out-of-band on a PR if it wants the second
  opinion without risking the review worker.
- **Auto-commit-on-completion (#219).** That is the separate recoverability
  ticket. This spec reinforces "commit + push frequently" as doctrine but does
  not add a worker-exit auto-commit hook.
- **The other worker types** (`worker-test-discovery`, `worker-conflict-resolver`,
  `worker-codex-implementation`, `worker-auditor`). The acute failures were in
  `worker-implementation` and `worker-review`; extending the discipline to the
  rest is a natural follow-up but is held out to keep blast radius small. The
  anti-stall rules are written generically enough to lift verbatim later.
- **Commander spawn-template wording** (#220's contributing factor: the spawn
  prompt literally asked for a "dev server smoke test"). The spawn template lives
  in `docs/specs/2026-04-17-slim-worker-prompts.md` and is Commander's contract;
  editing it risks colliding with concurrent template work and is a separate,
  Commander-side change. The agent-file discipline is the worker-side defense and
  is sufficient on its own: even if a spawn prompt asks for a foreground smoke
  test, the worker now knows to background-poll-kill instead. Filed as follow-up.

## Proposed approach

### 1. "Anti-stall discipline" section — both agent files

Add a new section, **"## Anti-stall discipline (no foreground-blocking commands)"**,
to both `worker-implementation.md` and `worker-review.md`. Placement: in
`worker-implementation.md`, immediately after the existing "Early-PR discipline"
section (the recoverability half pairs naturally with the prevention half); in
`worker-review.md`, immediately after the "Flow" section (so the worker reads the
review steps, then the discipline that keeps it alive while running them).

The section matches the existing voice (imperative, rationale-bearing, spec-cited)
and states:

- **The watchdog reality** — one sentence: the harness kills a worker that emits
  no stream output for ~600s, losing uncommitted work.
- **Rule 1 — never foreground a long-lived / quiet command.** Concrete blocklist:
  dev servers, `vite`, `npm run dev`, anything with `--watch`, anything that does
  not return. Concrete allowlist: build-only verification that EXITS — `npm run
  build`, `npm test` / `vitest run` (NOT `vitest` interactive watch, NOT `vitest
  --watch`).
- **Rule 2 — server for a runtime check: background → curl-poll → kill.** A short
  inline pattern (background the server with `&`, capture `$!`, poll
  `curl --fail http://localhost:PORT/health` in a bounded loop, `kill "$pid"` in
  a `trap … EXIT`).
- **Rule 3 — do not assume `timeout` exists.** State the macOS gap explicitly
  (no `timeout`, no `gtimeout`, exit 127) and give the portable
  `sleep N && kill <pid>` backgrounded-watchdog pattern.
- **Reinforce commit + push frequently** — one line cross-referencing the
  Early-PR doctrine (#188): each increment on the remote means a stall is always
  recoverable.

Both files get the same core rules; `worker-review.md`'s copy is scoped to the
review context (it runs `/review`, `/codex review`, local build/test — all of
which can stall) and leads into the codex change below.

### 2. `worker-review.md` — `/codex review` OFF by default

This is the targeted #222 fix. The current `worker-review.md` Flow has
**step 6: "Run `/codex review` for an adversarial second opinion"** as an
unconditional default step. That step is RC-3 — the reliable killer.

Change:

- **Reframe Flow step 6** from "Run `/codex review`" to "**`/codex review` is
  OFF by default** — skip it unless the spawn prompt explicitly opts in
  (`codex: on` or equivalent). The default review gate = `/review` + the worker's
  own structured read of the diff + a LOCAL build/test pass. This already
  produces CLEAN-quality reviews."
- **Add an opt-in subsection** describing how to run codex *safely* if opted in:
  run it with a **bounded wait** that emits periodic progress (so the stream
  stays alive past 600s) and, if codex has not finished by the bound, **post a
  partial review** (the `/review` + local-build/test findings) rather than
  waiting silently and losing everything. Use the Rule-3 `sleep N && kill`
  pattern to bound the codex process; never poll an output file in a tight silent
  loop.
- **Document why** inline (RC-3 + the #181/#182/#187/#8 recurrence) so a future
  worker does not "helpfully" re-add codex to the default gate.
- The `classify-pr-for-review` skill currently documents the codex step as part
  of scoping. To avoid a same-PR collision and keep blast radius small, this spec
  updates **only the agent file's Flow**; the skill is updated in lock-step *only
  if* its prose mandates codex unconditionally (checked during implementation).
  If the skill merely references codex as one available engine, it is left as-is
  and the agent file's "off by default" gate governs. (The adversarial-gate steps
  7–9, which only run for security PRs and already presuppose codex *may* run as
  one critic family, are unaffected: with codex off by default, a security PR's
  cross-family critic falls back to Claude's own re-examination, which the
  existing step-8 prose already permits — "for a finding raised by `/codex
  review` itself, the critic is Claude's own reasoning". No security finding is
  lost; the adversarial pass simply uses the available engines.)

### 3. Self-test fixture (`anti-stall-discipline/run.sh`)

A standalone static-assertion fixture at
`self-test/fixtures/anti-stall-discipline/run.sh`, modeled byte-for-byte on the
shape of `self-test/fixtures/early-pr-skeleton/run.sh` (same `set -euo pipefail`
+ grep + section-extraction pattern; no worker spawn). Assertions:

1. `worker-implementation.md` has an "Anti-stall" section header.
2. `worker-review.md` has an "Anti-stall" section header.
3. Each anti-stall section mandates the three rules: (a) no foreground / dev
   server / `--watch`; (b) background → curl-poll → kill; (c) the `timeout`-is-
   absent + `sleep N && kill` portability rule.
4. `worker-review.md` documents `/codex review` as **off by default** (grep for
   the off-by-default phrasing scoped to the file), AND its Flow no longer states
   codex as an unconditional default step (the step-6 line names "off by default"
   / "opt-in", not a bare "Run `/codex review`").
5. This spec file exists at its expected path (frontmatter contract).

Exit 0 if all assertions hold, 1 otherwise.

### 4. CLAUDE.md one-line pointer

Per the CLAUDE.md scope rule, only a one-line spec pointer goes in CLAUDE.md.
The natural home is the **"Worker timeout watchdog"** section (it already owns
the stall/rescue topic). Append one sentence pointing at this spec. Re-run
`scripts/check-claude-md-size.sh` to stay under the gate (currently NOTICE band,
~1959 chars of headroom; a one-liner is well within budget).

### Alternatives considered

- **Keep `/codex review` in the default gate but always time-box it.** Rejected
  as the default: codex is the single most reliable killer and time-boxing still
  spends a worker's budget on a step that adds little over `/review` + local
  build/test for the common (non-security) PR. Off-by-default with safe opt-in
  is lower-risk; the time-box pattern is preserved for the opt-in path.
- **Put the discipline only in CLAUDE.md.** Rejected: workers read their own
  agent definition for their flow, not CLAUDE.md, and the CLAUDE.md scope rule
  pushes procedures to specs. The agent file is the right home.
- **Wrap slow commands in `timeout`.** Rejected outright — RC-2: `timeout` does
  not exist on macOS (exit 127). The portable `sleep N && kill` pattern replaces
  it.
- **Have Commander run codex out-of-band for every PR** (#222 option 3).
  Reasonable and not precluded — but it is a Commander-side change, out of scope
  here. The agent-file change (codex off by default) is the worker-side fix and
  is sufficient to stop the kills; Commander can layer out-of-band codex on top
  later.

## Test plan

All checks are LOCAL — GitHub Actions is dark account-wide at time of writing, so
this PR is verified by running the CI-equivalent checks by hand:

1. `bash self-test/fixtures/anti-stall-discipline/run.sh` → exit 0 (all
   assertions pass). Red→green: the fixture fails before the agent-file edits
   land and passes after.
2. `bash -n self-test/fixtures/anti-stall-discipline/run.sh` → exit 0 (the new
   fixture is syntactically valid; this is what CI's `syntax-check.sh` runs).
3. `bash scripts/check-claude-md-size.sh` → exits 0 / stays under the 18000-char
   ceiling after the one-line pointer is added.
4. Frontmatter contract: this spec has `status:` + `date:` (what CI's
   `syntax-check.sh` step 3 enforces on `docs/specs/*.md`).
5. Grep both agent files for the "Anti-stall" section header → matches.

## Risks / rollback

1. **A worker still needs a real running server for a genuine runtime check**
   (rare for these doc-class repos, common for app repos). Mitigated by Rule 2:
   the background → curl-poll → kill pattern *does* let a worker stand a server
   up; it just forbids leaving it in the foreground. No capability is removed.
2. **Dropping `/codex review` from the default gate weakens reviews.** Low risk:
   the #220/#222 evidence is that the default gate already produces CLEAN-quality
   reviews from `/review` + local build/test + the worker's own read; codex
   mostly added *risk* (the kill) without proportional signal on common PRs. For
   the PRs where codex matters most — security-adjacent diffs — the adversarial
   gate (steps 7–9) still runs, and opt-in codex remains available. Rollback is a
   one-line revert of the step-6 reframe.
3. **The portable `sleep N && kill` pattern is cruder than `timeout`** (it does
   not distinguish a clean exit from a kill as precisely). Acceptable: it is the
   only portable option on the operator's macOS host, and bounding the command at
   all is the goal. Workers that detect a real `timeout`/`gtimeout` may use it,
   but must not *assume* it.
4. **Rollback.** `git revert` the agent-file + CLAUDE.md commits — workers fall
   back to the prior flow (codex in the default gate, no anti-stall section). The
   fixture would then fail, signalling the doctrine regressed; remove the fixture
   in the same revert for a full rollback. No state or schema changes to unwind.

## Follow-up

- **Commander spawn-template** (`docs/specs/2026-04-17-slim-worker-prompts.md`):
  stop instructing foreground dev-server smoke tests; prefer "background-poll" or
  build-only verification language. Commander-side change, deferred to avoid
  template collision.
- **#219** auto-commit-on-completion — the recoverability sibling. With anti-
  stall prevention (this spec) + early-PR recoverability (#188) + #219, a worker
  both avoids the kill and survives one if it happens.
- Extend the anti-stall section to the other implementing workers
  (`worker-codex-implementation.md`, `worker-test-discovery.md`,
  `worker-conflict-resolver.md`) once they are no longer being edited
  concurrently.
