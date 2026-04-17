# Hydra demo recording

Lives here so the README can embed it without a network fetch. Refreshing this
artifact is a manual, operator-driven task — we don't regenerate on every PR
because the flow involves real GitHub issues, real worker spawns, and real
merges that don't repro deterministically in CI.

## Files

- `demo.cast` — asciinema v2 cast of the auto-loop end-to-end. **Currently a
  placeholder** (its `title` field contains the word `placeholder`).
  Regenerate via the script below.
- `demo.svg` — rendered SVG of the cast, used for the README embed. Not
  committed yet; ships alongside a real cast.

## Regenerate

```bash
# 1. install prerequisites (one-time)
pip install asciinema              # or: brew install asciinema
cargo install --git https://github.com/asciinema/agg   # for SVG conversion

# 2. record (follow the scenario the script prints)
./scripts/record-demo.sh

# 3. render to SVG
agg docs/demo/demo.cast docs/demo/demo.svg

# 4. (optional) upload to asciinema.org for a hosted player URL
asciinema upload docs/demo/demo.cast

# 5. flip the README '## Demo' block to embed the SVG
#    (edit README.md; change the placeholder-state sentence to <img src=...>)

# 6. commit everything together
git add docs/demo/demo.cast docs/demo/demo.svg README.md
git commit -m "docs: refresh demo recording"
```

One combined step for convenience:

```bash
./scripts/record-demo.sh --convert   # records + runs agg in one go
```

## Scenario

The recording targets the [`hello-hydra-demo`](../../examples/hello-hydra-demo/)
fixture repo. The scripted flow matches
[`DEMO.md`](../../examples/hello-hydra-demo/DEMO.md) exactly so viewers who
want to try it themselves can follow the same steps:

1. `./hydra` — session greeting
2. `./gh-filings.sh <fork>` — file the 3 fixture issues
3. `pick up 3` — Commander classifies and spawns
4. Watch the T1 auto-merge
5. Watch the T3 refusal (`gh issue view 3`)
6. `merge #<PR>` — the T2 human-merge gate
7. `cat memory/learnings-hello-hydra-demo.md` — the learning loop

Target duration: ~60–90 seconds at 1x. `HYDRA_DEMO_SPEED=2` renders at 2x for
a tighter README embed.

## Validation

The self-test case `demo-recording-valid` (in `self-test/golden-cases.example.json`)
enforces:

- `docs/demo/demo.cast` exists and its first line parses as asciinema v2 JSON
  (`.version == 2`).
- Every subsequent line parses as a 3-element JSON array.
- If the header's `title` contains `"placeholder"`, the case SKIPs the stricter
  event-count check (placeholder casts are minimal by design).

Run the case manually:

```bash
./self-test/run.sh --case demo-recording-valid
```

## Why placeholder-first?

A headless worker can't drive a live `./hydra` session with real issue
creation, real worker spawns, and human-gated merges. Rather than commit a
fabricated cast (which would violate the "don't fake the flow" acceptance
criterion on ticket #37), we ship a clearly-marked placeholder plus the
tooling to regenerate. The README embed degrades gracefully — it points at the
walkthrough users can run themselves instead of showing a fake GIF.

## Spec

[docs/specs/2026-04-17-asciinema-demo.md](../specs/2026-04-17-asciinema-demo.md)
