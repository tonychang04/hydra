---
status: draft
date: 2026-04-17
author: hydra worker (ticket #37)
---

# Asciinema demo recording tooling + README embed

## Problem

The README explains the Hydra auto-loop in prose and a Mermaid flowchart, but static
diagrams can't capture the "watch it work while you drink coffee" feeling that sells
dev tools. Aider, k9s, lazygit, the GitHub CLI, and Cursor all open their READMEs
with a terminal GIF or video because the end-to-end motion — issue filed, worker
spawns, PR opens, auto-merge — is the product. Hydra needs the same on-ramp.

The observed signal is ticket #37 ("Demo asciinema / GIF in README showing the
auto-loop in action"). Until now we've had no reproducible way to record the loop,
no scripted scenario (every operator would record something subtly different), and
no place in the repo where the cast file and its regeneration procedure live. If a
contributor wants to refresh the demo after a UX change they have no starting point.

Bonus signal: #29 shipped `examples/hello-hydra-demo/` — a deterministic 10-minute
walkthrough that produces the exact three-ticket outcome (T1 auto-merge, T2
human-merge, T3 refusal). That fixture is the obvious scenario for the recording;
without wiring it in we'd drift toward ad-hoc sessions that can't be re-run.

## Goals / non-goals

**Goals:**

- A scripted scenario (`scripts/record-demo.sh`) an operator runs to capture a
  live asciinema cast of the Hydra loop against `examples/hello-hydra-demo/`.
  Reproducible, minimal narration, ~60–90 seconds of motion.
- A canonical home for the recording artifacts: `docs/demo/demo.cast` (asciinema
  source) and optional `docs/demo/demo.svg` (GIF-equivalent for README embed).
- A `## Demo` section added near the top of `README.md` (after the intro
  paragraph, before the "Who's who" table) that either embeds the SVG inline or
  links to the asciinema.org cast — with a fallback comment for when the cast
  is still the placeholder.
- A self-test case (`demo-recording-valid`) that validates the cast is
  well-formed asciinema v2 JSON and records a scenario with the expected command
  count. SKIPs when the cast is still the placeholder so CI doesn't fail on an
  un-recorded branch.
- Honest placeholder behavior: if no real cast is shipped in this PR, `demo.cast`
  must be marked clearly as a placeholder with the one-line regeneration
  command.

**Non-goals:**

- Actually recording the polished, operator-ready cast in this PR. A headless
  worker can't drive a live `./hydra` session with real GitHub issue creation,
  worker spawns, and human-gated merges — that's inherently an operator task.
- Auto-regeneration of the cast on every PR (expensive, fragile, and a moving
  target would churn the README).
- Integration with any specific CI job. The self-test case is run by the
  operator or by the existing `self-test/run.sh` harness, not by a dedicated
  workflow.
- First-impression README rewrite. Ticket #98 owns that; this PR adds a single
  `## Demo` H2 block and nothing else.
- Embedding an interactive asciinema-player widget. GitHub Markdown doesn't
  render `<script>`, so the inline option is SVG-only today; a hosted-player
  variant is a follow-up ticket.

## Proposed approach

Three small, independent artifacts plus one documentation edit and one self-test
case. Everything is additive; nothing mutates behavior outside `docs/demo/`,
`scripts/`, `self-test/`, and `README.md`.

**`scripts/record-demo.sh`** — an executable shell script that drives a scripted
recording session. It calls `asciinema rec` (with configurable `--idle-time-limit`
and playback speed hooks via `HYDRA_DEMO_SPEED`) and writes to
`docs/demo/demo.cast`. Before starting the recording it preflights: asciinema
installed, gh authenticated, `examples/hello-hydra-demo/` present, the operator
has a target fork. The script does NOT actually run the Hydra flow — it prints
step-by-step instructions for the operator to follow while the recording is
capturing. That's how aider and lazygit do it: the script sets up the harness,
the human does the demo, the artifact comes out the other end.

The scripted scenario mirrors `examples/hello-hydra-demo/DEMO.md` exactly so the
operator already knows the flow: launch `./hydra`, show session greeting, file
three fixture issues via `gh-filings.sh`, type `pick up 3`, watch the T1
auto-merge, surface the T2 for human merge, observe the T3 refusal, inspect the
learnings file. Target duration is 90 seconds at 1x; operators can ship at 1x
or speed up to 2x at convert time.

**`docs/demo/demo.cast`** — a PLACEHOLDER asciinema v2 cast committed with this
PR. It contains a minimal valid v2 JSON header and 4–5 realistic lines so the
self-test parser has something to validate. Top-of-file comment (inside the
JSON header's `title` field, which asciinema supports) flags it as a placeholder
and points at `scripts/record-demo.sh` for regeneration. This preserves the
"honesty over optics" rule from the ticket: the file exists so the README embed
doesn't 404, but nobody is misled about its provenance.

**`docs/demo/demo.svg`** — skipped unless `agg` is installed and the worker can
render a real cast. For the placeholder cast, the SVG would be misleading, so
we ship a static `docs/demo/README.md` explaining how to regenerate both. Once
an operator records a real cast they run `agg docs/demo/demo.cast docs/demo/demo.svg`
and commit both.

**`README.md`** — a `## Demo` H2 block inserted after the opening intro
paragraph (line ~18) and before the "Who's who" table. The block shows:
- If `docs/demo/demo.svg` exists and is a real render: `<img src="docs/demo/demo.svg" alt="Hydra auto-loop demo">` plus a fallback link to the hosted asciinema.org URL.
- If only the placeholder cast exists: a single sentence — "Demo recording in progress; regenerate with `scripts/record-demo.sh`. See [docs/demo/README.md](docs/demo/README.md) for details." — and a link to `examples/hello-hydra-demo/DEMO.md` for the walkthrough users can run themselves today.

This PR ships the placeholder variant. When an operator records a real cast,
a follow-up PR flips the README block to the SVG embed.

**Self-test `demo-recording-valid` (kind: `script`)** — uses `jq`-style
assertions to verify `docs/demo/demo.cast`:
1. First line parses as JSON (asciinema v2 header).
2. `version` field equals 2.
3. Subsequent lines each parse as 3-element JSON arrays `[timestamp, event_type, data]`.
4. If the header's `title` contains the string `"placeholder"`, the case SKIPs
   the stricter content checks (placeholder is always valid-shape but may be
   minimal); otherwise the case enforces a minimum event count (≥20) to catch
   truncated recordings.

### Alternatives considered

- **Alternative A: Ship a pre-recorded cast generated non-interactively from a
  dummy script** — The worker could call `asciinema rec --command 'bash script.sh'`
  against a fake script that prints `./hydra` output verbatim. This produces a
  real-shaped cast file but the content would be a lie (the loop isn't actually
  running, the PRs aren't actually being opened). Rejected: violates the
  "don't fake the flow" acceptance criterion from the ticket. A placeholder
  clearly labeled as such is more honest than a fabricated cast that looks real.

- **Alternative B: Embed an interactive asciinema-player widget in README via
  `<script>` tag** — Allows scrubbing and pausing, which is nicer UX than a GIF.
  Rejected for this PR: GitHub Markdown sanitizes `<script>` tags, so the player
  wouldn't render on the README page. It could work on a dedicated docs site
  (GitHub Pages) but that's a separate product decision and a follow-up ticket.

- **Alternative C: Record with `vhs` (Charm's tape-based recorder) instead of
  asciinema** — vhs produces GIFs directly from a declarative `.tape` file,
  which would mean the worker could commit a real rendered artifact. Rejected:
  vhs requires a headless browser (chromium) and font packages that most
  operator laptops don't have, whereas asciinema is `pip install asciinema` and
  `agg` is a single Rust binary. Lower friction = more likely to be regenerated
  when the UX drifts.

- **Alternative D: Skip the cast file entirely and link straight to
  asciinema.org** — No bytes committed to the repo; asciinema.org hosts the
  cast. Rejected for this PR because the operator hasn't uploaded a real cast
  yet, so there's no URL to link to. Once a real cast is uploaded, the README
  could link out instead of embedding — that's a per-operator preference and
  the `## Demo` block makes both variants easy.

## Test plan

- **`bash -n scripts/record-demo.sh`** — shellcheck / syntax check (matches the
  pattern in the `hydra-cli-subcommands-valid` self-test case).
- **`scripts/record-demo.sh --help`** — prints usage, exits 0. Verifies the
  script's flag parser is wired.
- **`docs/demo/demo.cast` parses as valid asciinema v2** — `head -1
  docs/demo/demo.cast | jq -e '.version == 2'` exits 0. Catches malformed
  placeholders.
- **Self-test case `demo-recording-valid`** — as described in the proposed
  approach. SKIPs on placeholder, PASSes on a real recording.
- **README renders the `## Demo` block without breaking Mermaid** — `markdown`
  render in a sandbox (or visual inspection in the PR preview) confirms no
  anchor collision with existing H2s and no disruption to the Mermaid diagram
  below.

## Risks / rollback

- **Risk:** an operator runs `scripts/record-demo.sh` without `asciinema`
  installed and gets a confusing error.
  **Mitigation:** the script's first preflight step checks `command -v
  asciinema` and prints a one-line install hint (`pip install asciinema` or
  `brew install asciinema`).
- **Risk:** the placeholder `demo.cast` is mistaken for a real recording, gets
  rendered to SVG, and the SVG is embedded in README, misleading first-time
  viewers.
  **Mitigation:** the placeholder cast's header `title` field literally contains
  the word `"placeholder"`; `scripts/record-demo.sh` refuses to run `agg` on a
  placeholder input (detects via the title string).
- **Risk:** the README `## Demo` block pushes the H1 / intro below the fold on
  small viewports.
  **Mitigation:** the block is placed AFTER the intro paragraph, not before.
  The first 18 lines of README remain identical.

**Rollback:** revert the merge commit. All artifacts are additive; no existing
file's behavior depends on them. `git revert <sha>` is a one-step undo.

## Implementation notes

(Fill in after the PR lands.)
