---
name: worker-emit-memory-citations
description: |
  Emit MEMORY_CITED: markers at the end of a worker report. Use when finishing
  any worker ticket (implementation, review, test-discovery, conflict-resolver,
  codex-implementation) that applied a learning from memory/learnings-<repo>.md,
  memory/escalation-faq.md, or the Memory Brief. Teaches the exact line format
  that scripts/parse-citations.sh accepts, how to pick the citation quote, and
  how to self-check the output before closing the worker. Skip this skill
  only if the ticket genuinely used zero memory entries. (Hydra)
---

# Emit `MEMORY_CITED:` markers correctly

## Overview

Every Hydra worker must cite the memory entries it used, so Commander can increment `state/memory-citations.json` and the skill-promotion pipeline ([#145](https://github.com/tonychang04/hydra/issues/145)) can detect load-bearing learnings. Workers get the format slightly wrong often enough that the parser silently drops lines — the citation never increments, the promotion pipeline never sees the signal, and the learning stays un-promoted forever. This skill pins down the format and gives a one-shot self-check.

The canonical parser is `scripts/parse-citations.sh`. It matches this regex (paraphrased):

```
^[[:space:]]*MEMORY_CITED:[[:space:]]*<key>[[:space:]]*$
```

where `<key>` is everything after the colon on that line, whitespace-trimmed. The key is the literal dedup identifier used in `state/memory-citations.json`. There is no tolerance for prose after the key, inline commentary, or alternative delimiters.

## When to Use

- At the end of every worker ticket that touched any file in `memory/`, or that was shaped by the Memory Brief prepended to the prompt.
- Before emitting your final report (so the citation block is complete and self-checked).
- When you promote a new learning to memory AND also used a prior learning in the same ticket — emit citations for the prior ones; the new one will pick up citations on future tickets.

Skip when:

- The ticket was pure greenfield (no relevant prior learning existed).
- The only "memory" you read was CLAUDE.md, README.md, or docs/specs/ — those are not cited via `MEMORY_CITED:` (they're repo documentation, not citation-tracked memory).

## Process / How-To

1. **Identify each memory entry that materially shaped your implementation.** "Read and moved on" does not count; "used to avoid a rewrite" or "used to decide a tier" does.

2. **Find a verbatim ~3-8 word quote from the entry.** Not a paraphrase. The quote is the human-readable identifier and is used for dedup in `state/memory-citations.json`. Short is better: 3-5 words beats a full sentence.

3. **Compose the line:**

   ```
   MEMORY_CITED: <file>#"<quote>"
   ```

   Rules:
   - `<file>` is the basename only (`learnings-hydra.md`, `escalation-faq.md`, `tier-edge-cases.md`). No `memory/` prefix; no path.
   - `#` separates file from quote. Literal character, no escaping.
   - Quote is wrapped in **straight double quotes** (`"..."`). Not smart quotes, not single quotes.
   - Nothing after the closing quote on that line.

4. **Emit one line per cited entry** in a block near the bottom of your final report. Separate from other report content with a blank line above and below. A `TICKET:` line above the block attaches ticket ref to each citation:

   ```
   TICKET: hydra#150
   MEMORY_CITED: memory-lifecycle.md#"3+ workers across 3+ distinct tickets"
   MEMORY_CITED: escalation-faq.md#"no CLAUDE.md or .claude/skills/"
   ```

5. **Self-check** before closing the worker. Paste the report through `scripts/parse-citations.sh` mentally (or, if possible, actually run it) and confirm each line produces a key in the output JSON. If `jq '.citations | keys | length'` does not equal your number of `MEMORY_CITED:` lines, something is malformed — most likely a stray space, a curly quote, or missing the `#` delimiter.

## Examples

### Good (three citations, one ticket ref)

```
TICKET: hydra#150
MEMORY_CITED: memory-lifecycle.md#"3+ workers across 3+ distinct tickets"
MEMORY_CITED: escalation-faq.md#"no CLAUDE.md or .claude/skills/"
MEMORY_CITED: tier-edge-cases.md#"default to the more restrictive"
```

Round-trips through `parse-citations.sh`:

```
$ cat report.txt | scripts/parse-citations.sh
{
  "citations": {
    "memory-lifecycle.md#\"3+ workers across 3+ distinct tickets\"": {
      "count_delta": 1,
      "tickets_added": ["hydra#150"]
    },
    ...
  }
}
```

All three keys present. Each has `count_delta: 1` and `tickets_added: ["hydra#150"]`.

### Good (single citation from the Memory Brief)

```
TICKET: insforge-sdk-js#56
MEMORY_CITED: learnings-InsForge-sdk-js.md#"npm install strips peer markers"
```

The Memory Brief is a curated excerpt of `memory/learnings-<repo>.md`. Cite the **source file**, not "the brief" — the brief isn't a file the parser knows about.

### Bad — trailing prose

```
MEMORY_CITED: learnings-hydra.md#"rescue stale index lock" (used when probing)
```

The parse regex trims trailing whitespace but does not strip parenthetical prose. The key becomes `learnings-hydra.md#"rescue stale index lock" (used when probing)` — a new unique key that won't match any prior citation. Dedup fails silently.

**Fix:** drop the trailing prose. Put commentary OUTSIDE the `MEMORY_CITED:` block.

### Bad — smart quotes

```
MEMORY_CITED: memory-lifecycle.md#“3+ workers across 3+ distinct tickets”
```

Curly quotes (`“ ”`) are not `"`. The key will be stored as a distinct entity from the straight-quote version, fragmenting the citation count.

**Fix:** always use straight double quotes. Most IDEs auto-correct; turn that off for this file, or paste from a plain-text buffer.

### Bad — paraphrase instead of verbatim quote

```
MEMORY_CITED: escalation-faq.md#"always use REST for labels"
```

The actual entry in `escalation-faq.md` says "Labels on PRs always use the REST API". Your paraphrase creates a fresh key that only you will ever cite.

**Fix:** grep the memory file. Use a 3-8 word contiguous quote from the actual text.

### Bad — missing `#`

```
MEMORY_CITED: memory-lifecycle.md "3+ workers across 3+ distinct tickets"
```

Parser will read the key as everything after `MEMORY_CITED: ` through end-of-line — i.e. the file and quote become one blob with a space between them. Distinct key per-worker; no dedup.

**Fix:** insert the `#` between file and quote. No spaces around it.

## Verification

This skill's examples round-trip cleanly through the canonical parser. To confirm locally:

```
cat <<'EOF' | scripts/parse-citations.sh
TICKET: hydra#150
MEMORY_CITED: memory-lifecycle.md#"3+ workers across 3+ distinct tickets"
MEMORY_CITED: escalation-faq.md#"no CLAUDE.md or .claude/skills/"
EOF
```

Expected: JSON with `.citations | keys | length == 2`, each entry has `tickets_added: ["hydra#150"]`, each has `count_delta: 1`.

The parser also prints a stderr warning if a cited filename does not exist under `memory/` (for `memory-lifecycle.md` etc. it won't, since those files are real). That warning does not change exit code and does not prevent commander from ingesting the delta.

## Related

- `scripts/parse-citations.sh` — the canonical parser. Source of truth for the format.
- `memory/memory-lifecycle.md` — defines the promotion threshold (3+ citations across 3+ distinct tickets).
- `docs/specs/2026-04-17-memory-preloading.md` — the Memory Brief feature; citations are how workers feed its input stream.
- `state/schemas/memory-citations.schema.json` — shape of the aggregated citation store.
- Issue [#145](https://github.com/tonychang04/hydra/issues/145) — the skill-promotion pipeline that consumes this data.
