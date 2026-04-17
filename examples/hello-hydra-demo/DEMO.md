# Hydra in 10 Minutes

This is the fastest path from "I just heard about Hydra" to "I've watched it clear three tickets end-to-end." The demo is deliberately tiny: one Node file, one test file, three fixture issues that exercise all three tier outcomes (T1 auto-merge, T2 human-merge, T3 refusal).

**Time budget:** roughly 10 minutes of wall-clock. Most of it is Hydra thinking while you watch.

## Prerequisites

- Node 18+ on your PATH (`node --version` prints v18 or higher). That's the only runtime dep — the demo has zero `npm install` baggage.
- The `gh` CLI installed and authenticated (`gh auth status` green).
- A working Hydra install on your laptop per the top-level [INSTALL.md](../../INSTALL.md). `./hydra doctor` should exit 0.
- A GitHub fork of `tonychang04/hydra` (or of this `hello-hydra-demo` directory extracted into its own repo — either works; see step 1 for both variants).

## Expected outcome

By the end of the walkthrough you'll have:

- **2 PRs merged** — one T1 auto-merged by Commander, one T2 merged by you after `worker-review` cleared it.
- **1 issue refused** — the T3 JWT-rotation fixture sits on `commander-stuck` with a comment from Commander explaining why.
- **1 learnings file** on disk — `memory/learnings-hello-hydra-demo.md` with whatever pattern the worker captured during ticket #1.

No code written by hand. No `npm install`. No manual test runs. That's the pitch.

## Step 1 — Fork (pick one variant)

You have two ways to get a sandbox repo:

**Variant A — fork all of Hydra.** Fork `https://github.com/tonychang04/hydra` to your GitHub. The demo lives at `examples/hello-hydra-demo/`. File issues against your fork's top-level repo; Commander will see them and workers will operate inside the `examples/hello-hydra-demo/` subtree.

**Variant B — standalone demo repo.** Copy the `examples/hello-hydra-demo/` subtree into its own fresh GitHub repo (e.g. `alice/hello-hydra-demo`). Simpler, tighter blast radius, and closer to "what it feels like when you add a real repo to Hydra."

Both work. Variant B is recommended for a first run because the diffs stay small.

## Step 2 — Wire the demo into Hydra

Clone your fork locally (if you haven't already), then add it to `state/repos.json`:

```json
{
  "repos": [
    {
      "owner": "alice",
      "name": "hello-hydra-demo",
      "local_path": "/absolute/path/to/your/clone/of/hello-hydra-demo",
      "enabled": true,
      "ticket_trigger": "assignee"
    }
  ]
}
```

Flip `enabled: true`. Save.

## Step 3 — File the three fixture issues

From inside your clone of the demo directory:

```bash
./gh-filings.sh alice/hello-hydra-demo
```

The script reads the three files under `fixture-issues/` and opens matching GitHub issues on the target repo, assigning each to the gh-auth'd user (you). It's idempotent — if you run it twice, the second run sees the existing titles and skips them. Expected output is three issue URLs.

- `fixture-issues/01-t1-typo.md` → issue #1: **"Fix typo in README (hollo -> hello)"**
- `fixture-issues/02-t2-farewell.md` → issue #2: **"Add farewell() function matching greet() style + tests"**
- `fixture-issues/03-t3-rotate-key.md` → issue #3: **"Rotate JWT signing key in src/auth/keys.js"**

## Step 4 — Launch Hydra and let autopickup engage

From your Hydra clone:

```bash
./hydra
```

Commander's session greeting reports: "`3` tickets ready across `1` repo". With autopickup default-on (interval 30m, but the first scheduled tick waits the full interval), you can either wait for the tick or nudge it with:

```
pick up 3
```

Commander preflights, classifies each ticket's tier, and spawns `worker-implementation` on the two pickup-eligible ones. Issue #3 is refused up front per tier classification — see step 7.

## Step 5 — Watch worker-implementation fix the typo

Issue #1 is classified T1 (doc fix). A worker subagent spawns in an isolated worktree, reads the repo, fixes the `hollo → hello` swap in `README.md`, removes the stale explanatory note, and opens a draft PR titled something like `Fix typo in README (hollo -> hello) (closes #1)`. This usually lands in under 2 minutes.

During this step, `worker-implementation` also appends any non-obvious pattern it learned to `memory/learnings-hello-hydra-demo.md`. For a clean T1 it may write nothing — that's fine.

## Step 6 — Commander auto-merges the T1 PR

Per `policy.md`, T1 PRs with CI green (and for this demo, "CI green" means the two `greet` tests still pass under node:test) auto-merge without human confirm. Commander:

1. Spawns `worker-review` against the draft PR.
2. On clean review, flips the PR out of draft.
3. Merges it. You'll see a one-line status in chat.

Issue #1 closes. Total wall-clock so far: ~3-4 minutes.

## Step 7 — Observe Commander refuse issue #3

Issue #3 references `src/auth/keys.js` and says "rotate signing key" — three separate T3 tripwires:

- Path matches `*auth*` (file path contains `auth`)
- Description discusses secrets / crypto material
- Title uses the word "signing key"

Commander classifies T3 during the pickup phase, **before** any worker spawns, and applies the `commander-stuck` label to the issue with an explanatory comment. Check:

```bash
gh issue view 3 --repo alice/hello-hydra-demo
```

You should see the `commander-stuck` label and a comment like "Tier 3 — refused per policy.md. Path `src/auth/keys.js` matches `*auth*`; title matches `signing key`." No worker was spawned. The referenced file (`src/auth/keys.js`) doesn't even exist in the demo — the path *shape* in the ticket body was enough to trip the refusal.

## Step 8 — Issue #2 goes through the T2 human-merge gate

Issue #2 is T2 (feature + tests). `worker-implementation` writes `src/farewell.js`, adds `src/farewell.test.js`, tweaks `package.json` to run both test files, and opens a draft PR. Then:

1. `worker-review` runs against the draft PR.
2. On clean review, Commander surfaces: "PR #4 passed commander review. Ready for your merge."
3. You eyeball the diff and type `merge #4` in chat. Commander merges.

Total wall-clock so far: ~8-10 minutes. Adjust expectations upward if your Claude session is cold-starting or if `worker-review` needs a second pass.

## Step 9 — Inspect the learnings file

```bash
cat memory/learnings-hello-hydra-demo.md
```

You should see one or more entries the worker captured during the run — e.g. "node:test runs from any directory that has a `src/*.test.js` pattern; no config required" or "package.json `scripts.test` with `node --test src/` picks up all test files matching the node:test convention." These are the seeds of the learning loop. Cited 3+ times across future tickets, they'd graduate into a skill PR.

Also peek at `state/memory-citations.json` — you'll see the counts tick up.

## Expected outcome summary

| Ticket | Tier | Final state | Who merged |
|---|---|---|---|
| #1 — typo | T1 | merged | Commander (auto) |
| #2 — farewell | T2 | merged | You (after review worker cleared it) |
| #3 — rotate key | T3 | refused, labeled `commander-stuck` | Nobody |

Wall-clock: ~10 minutes on a warm Claude session. Human-touch points: one `merge #4` confirmation. That's the loop.

## Troubleshooting

- **Tests fail on the demo before Hydra even starts.** Run `node --version` — you need 18+. Anything older doesn't have `node:test` built in.
- **`./gh-filings.sh` errors with `gh: not authenticated`.** Run `gh auth login` and retry. The script is idempotent so re-running is safe.
- **Commander doesn't pick up any tickets.** Check `state/repos.json` has `enabled: true` for your demo fork, and that the issues were assigned to the gh-auth'd user (`gh issue list --assignee @me --repo alice/hello-hydra-demo`).
- **Issue #3 gets picked up instead of refused.** Verify `policy.md` hasn't been edited locally to remove `*auth*` from the T3 tripwire list — the refusal depends on that policy being intact.

## What to try next

- Delete the PRs + reopen the issues, then run `./hydra` and let autopickup run on its natural interval instead of hand-dispatching.
- Add a fourth fixture issue (new file under `fixture-issues/04-...`) and watch the script stay idempotent on re-run.
- Add `tonychang04/hydra` to your `state/repos.json` alongside the demo repo and let Hydra attempt framework tickets in parallel with the demo tickets. That's the dogfood loop.
