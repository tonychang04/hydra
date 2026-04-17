---
status: proposed
date: 2026-04-17
author: hydra worker
ticket: 146
tier: T2
---

# Slim worker-spawn prompts: reference ticket URL instead of inlining body

**Ticket:** [#146 — Slim worker-spawn prompts](https://github.com/tonychang04/hydra/issues/146)

## Problem

Commander's spawn procedure today inlines the full ticket body — acceptance criteria, context, edge-case discussion, everything — into the worker prompt before dispatching the `Agent` tool. Every spawn costs hundreds of main-context tokens that the worker will re-read anyway via `gh issue view` (or its equivalent `gh api` fallback for repos with classic-projects deprecation). With 5 concurrent workers, this is the #2 bloat source after CLAUDE.md (#1 was ticket #138, now landed).

Quantitatively: a typical ticket body is 1500–3000 chars (≈400–800 tokens). Commander currently:

1. Reads the issue body via `gh` (one time, counts once).
2. Pastes it into the spawn prompt (second copy, counts again on the spawn).
3. Holds it in main-context transcript for the life of the spawn orchestration (third+ time).
4. The worker then re-fetches via `gh issue view` as its first step anyway (step 0 of `worker-implementation.md`'s orient procedure).

Steps 2 + 3 are pure duplication. Step 4 is the single authoritative read. Inlining the body is a net loss — the worker can't trust a body quoted to it second-hand anyway (ticket bodies mutate; a rebased or edited ticket after spawn would diverge), and the Memory Brief shipped in #141 already handles the pre-loaded context layer that inlining was informally trying to provide.

## Goals

- Standardize a slim worker-spawn prompt template. Body is a short header referencing the ticket URL + repo + tier; the worker fetches the authoritative body itself.
- Target prompt length ≤ **800 chars** BEFORE the Memory Brief is prepended (the Memory Brief adds up to 2000 chars per #141; the total spawn prompt is still bounded).
- Keep the coordinate-with-other-workers hint (one-liner — "also touching `CLAUDE.md`: #150, #151") because that's information the worker can't derive itself.
- Document the template canonically in this spec so future workers and reviewers can point at one place.
- Update every `worker-*.md` subagent definition to acknowledge the slim template: expect the ticket URL at the top, self-fetch the body, **do not complain** about "missing detail" if only the URL + tier is in the spawn prompt.
- Add a ≤ one-pointer-line + ≤ 5-line template block to `CLAUDE.md` — just enough for Commander to produce the format consistently. Full rationale stays in this spec.
- Regression test: static fixture under `self-test/fixtures/slim-worker-prompts/` that asserts the template is well-formed (contains required fields, under 800-char cap) and that the worker-agent files have been updated to acknowledge it.

## Non-goals

- **Changing the worker subagent contract on anything else.** Output format, skill chain, memory citations, PR body format all stay as-is. This is a prompt-shape ticket, not a contract ticket.
- **Changing what Commander reads before spawning.** Commander still fetches the issue via `gh issue view` / `gh api` to classify tier and check labels — it just doesn't paste the body into the spawn prompt afterwards.
- **Memory Brief pipeline.** #141 already shipped. We coordinate with it here (the brief sits between the `Ticket:` line and the `Fetch full body` instruction) but do not touch `scripts/build-memory-brief.sh` or the brief format.
- **Modifying the existing prompts that live in the worker agent md files** (the Step 0 / Flow / Hard rules prose). Those describe what the worker does, not what Commander sends. We only add one paragraph acknowledging the slim template.
- **Live worker-subagent self-test comparison (inlined vs slim on a fixture ticket).** A real side-by-side spawn test requires Claude auth + two real worker spawns + a diff of their outputs — out of scope for a unit-scale fixture. We instead validate the template's shape and the worker agents' acknowledgement-language via static assertions; the empirical comparison will accrue naturally via Commander logs over the next 5–10 tickets. See "Test plan" below.
- **Touching `self-test/golden-cases.example.json`.** Operator pinned this file as off-limits (pending operator edit). The fixture lives in `self-test/fixtures/slim-worker-prompts/` only; wiring into the shared test runner deferred until the operator reopens that file for writes.

## Proposed approach

### Canonical slim template

```
Ticket: https://github.com/<owner>/<repo>/issues/<n>
Repo: <owner>/<repo> @ <local_path>
Tier: T<n>

<Memory Brief from scripts/build-memory-brief.sh — 0–2000 chars — per #141>

Fetch full body via `gh issue view <n> --repo <owner>/<repo>` (fall back to `gh api /repos/<owner>/<repo>/issues/<n>` if classic-projects deprecation fires).
Worker type: <type>.
Coordinate-with hints: <1–2 lines listing in-flight tickets touching overlapping files, or "none">.
Done = draft PR with "Closes #<n>" + tests passing. Report: branch, PR #, test output, any QUESTION blocks.
```

Rules:

1. The four header lines (`Ticket:`, `Repo:`, `Tier:`, blank) and the four footer lines (`Fetch full body…`, `Worker type:`, `Coordinate-with hints:`, `Done =…`) are fixed. Commander substitutes the angle-bracketed fields.
2. The Memory Brief is spliced in between header and footer. When the brief is empty (fresh repo, per #141 failure mode), the region is a single blank line.
3. Linear-sourced spawns get an extra line immediately after `Tier:`, e.g. `Linear: LIN-123 — https://linear.app/...`. Worker agents already know to prepend `Closes LIN-123 — …` to the PR body when this line is present (existing behavior in `worker-implementation.md`).
4. Total length BEFORE the Memory Brief must be ≤ 800 chars. Header + footer of the fixed template is ~500 chars; the 300-char headroom absorbs typical repo paths + coordinate hints.

### Why ticket URL instead of ticket body

Four reasons, listed so future workers debating "shouldn't we just paste the body to save the worker one gh call?" have a written answer:

1. **Duplication.** The worker's Step 0 already says read the ticket — spawn-prompt paste is a second copy that makes the total spend go up, not down.
2. **Staleness.** If the operator edits the ticket after Commander spawns but before the worker starts, the pasted body is stale. The URL fetch is always live.
3. **Length variance.** Worst-case ticket bodies are 5000+ chars (design docs filed as issues). Inlining those blows past any reasonable spawn-prompt cap. URL is a constant.
4. **Contract clarity.** "The ticket is the source of truth; the spawn prompt tells you where to go" is a cleaner mental model than "the spawn prompt is a partial ticket and you re-read the full one at Step 0". Workers that drift on this today sometimes act on the inlined paste without re-reading — if the operator added a `QUESTION:` comment to the issue between body-write and spawn, the worker misses it.

### Worker subagent updates

For each of `worker-implementation.md`, `worker-codex-implementation.md`, `worker-test-discovery.md`, `worker-review.md`, `worker-conflict-resolver.md`, `worker-auditor.md`: add a small paragraph near the top (after the existing Memory Brief paragraph when present; otherwise immediately after the "You are a Commander … worker" opener) that says:

> **Slim spawn prompt (default):** Commander sends a slim prompt — `Ticket: <URL>`, `Repo:`, `Tier:`, the Memory Brief, a `Fetch full body…` instruction, and a coordinate-with hint. The full ticket body is NOT inlined. Fetch it yourself via `gh issue view <n> --repo <owner>/<repo>` (fall back to `gh api /repos/<owner>/<repo>/issues/<n>` on classic-projects deprecation errors) as your Step 0. If the spawn prompt looks minimal, that's by design — not a missing-detail bug. Spec: `docs/specs/2026-04-17-slim-worker-prompts.md`.

This paragraph makes the contract explicit. Prior to this change, a worker seeing a short spawn prompt might emit `QUESTION: ticket body not provided`, which this ticket explicitly rules out.

Workers that don't actually read the ticket body — `worker-review` (reads PR diff), `worker-conflict-resolver` (reads PR list), `worker-auditor` (reads CLAUDE.md + logs) — still get the paragraph, because the CLAUDE.md pointer line applies uniformly and the workers need a written reason why a short spawn prompt is correct for their role too. Their Step 0 already points at PR / log reads rather than ticket-body reads, so the acknowledgement paragraph just adds "don't QUESTION on absent body" — it doesn't change behavior.

### CLAUDE.md update

Add one section header + pointer line + template block under "Operating loop" step 5 (the "Spawn worker" step). Budget: ≤ 7 lines added, ≤ 600 chars. Total CLAUDE.md size target: stay under 16,500 chars (current 15,666; ceiling 18,000). Current draft:

```
### Slim spawn prompt

Spawn prompt is a short envelope, not the full ticket body. Template:

```
Ticket: https://github.com/<o>/<r>/issues/<n>
Repo: <o>/<r> @ <path>
Tier: T<n>

<Memory Brief>

Fetch full body via `gh issue view <n> --repo <o>/<r>`.
Worker type: <t>. Coordinate-with: <1–2 lines or "none">.
```

Spec: `docs/specs/2026-04-17-slim-worker-prompts.md`.
```

### Regression test

New fixture: `self-test/fixtures/slim-worker-prompts/run.sh`. Static assertions only (no worker spawn — spawn-based comparison is out of scope per Non-goals):

1. The canonical template in this spec is parseable — file a fixture `sample-spawn-prompt.txt` with a filled-in example, and verify the 4 header lines + 4 footer lines appear in the expected order.
2. Length of header + footer (before the Memory Brief placeholder) ≤ 800 chars.
3. Every `.claude/agents/worker-*.md` file contains the phrase `Slim spawn prompt` (case-sensitive — the acknowledgement paragraph must be present).
4. `CLAUDE.md` contains a pointer to `docs/specs/2026-04-17-slim-worker-prompts.md`.
5. `CLAUDE.md` size is still under 18,000 chars (overlap with existing `scripts/check-claude-md-size.sh` — we just invoke that helper).

Runs on local dev + CI. Exit 0 if all assertions hold, 1 otherwise. Same shell+grep+wc pattern as the other `self-test/fixtures/*/run.sh` scripts.

The fixture is **not** wired into `self-test/golden-cases.example.json` in this PR — the operator pinned that file as off-limits pending their edits. The fixture is still runnable standalone (`bash self-test/fixtures/slim-worker-prompts/run.sh`) and the existing `self-test/run.sh` infra can pick it up whenever the golden-cases file re-opens for writes.

## Test plan

1. Run `bash self-test/fixtures/slim-worker-prompts/run.sh` on a clean tree → expect exit 0 (all assertions pass).
2. Run `bash scripts/check-claude-md-size.sh` → expect exit 0 (CLAUDE.md stayed within ceiling after the additions).
3. Grep each `.claude/agents/worker-*.md` for the phrase `Slim spawn prompt` — should match in every file.
4. Manual read of CLAUDE.md around "Operating loop" step 5 — verify the template block is ≤ 7 lines and the pointer line points at this spec.
5. Sanity: `wc -c CLAUDE.md` < 18000.

Out of scope for this test plan (documented so future workers don't expect them):

- Empirical side-by-side worker output on a fixture ticket. Requires Claude auth + two real worker spawns; will accumulate organically via Commander logs over the next 5–10 tickets. If the slim template causes measurable regression (worker emits `QUESTION:` for missing-body more often, or PR quality drops), we file a follow-up rather than blocking this spec.

## Risks / rollback

1. **Worker misinterprets the slim prompt as "incomplete" and emits `QUESTION:`** — mitigated by the acknowledgement paragraph added to every `worker-*.md` file. If it happens anyway: answer the question from memory (`memory/escalation-faq.md` entry: "spawn prompt looks minimal — that's the slim template, self-fetch") and add a reminder to the worker prompt template.
2. **`gh issue view` fails.** Fallback documented in the template + spec: use `gh api /repos/<owner>/<repo>/issues/<n>`. This is the same workaround already noted in `memory/learnings-hydra.md` for the classic-projects deprecation error — nothing new.
3. **Rollback.** `git revert` the CLAUDE.md update commit — Commander falls back to the old (inlined) pattern described informally in the operating loop. The worker agent updates keep the acknowledgement paragraph as harmless extra documentation even on rollback. The fixture script keeps testing the agent-file shape; it will still pass.
4. **Coordinate with ticket #141 (Memory Brief).** Memory Brief is already landed; this spec assumes the brief sits between the `Ticket:` line and the `Fetch full body` line. If #141 were to be reverted, the template degrades gracefully — an empty brief region is a single blank line, which is still a legal prompt.
5. **CLAUDE.md size ceiling.** Current 15,666 chars, ceiling 18,000. Budget for this change: ≤ 600 chars added. Verified by `scripts/check-claude-md-size.sh` in both local and CI preflight.

## Out of scope (explicit)

- Modifying `self-test/golden-cases.example.json`.
- Worker subagent behavior changes beyond the acknowledgement paragraph.
- Live worker-spawn A/B test (slim vs inlined). Tracking via Commander logs.
- Auto-generating the Coordinate-with hints from `state/active.json`. Commander currently writes these by hand; automation is a follow-up (`scripts/active-overlap-hint.sh` stub candidate) if the workflow feels repetitive.
- Memory Brief format changes. #141 owns that.
