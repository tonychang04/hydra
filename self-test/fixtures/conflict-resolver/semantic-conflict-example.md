# Semantic conflict example (STOP + escalate — do NOT auto-resolve)

This fixture documents what a NON-additive conflict looks like. The
`worker-conflict-resolver` subagent MUST NOT resolve this automatically.
Instead, it emits a `QUESTION:` block and exits without committing.

## Base (common ancestor)

```
| `merge #501` | Tier-aware; T1 auto-merge if CI green; T2 requires the operator confirmation. |
```

## PR #C (changes the same line)

```
| `merge #501` | T1 auto-merge if CI green; T2 requires supervisor attestation via MCP. |
```

## PR #D (also changes the same line, differently)

```
| `merge #501` | Tier-aware; T1 auto-merge if CI green AND commander-review passed; T2+ refuse. |
```

## Why this is semantic

Both PRs edited the SAME LINE with DIFFERENT content. Neither side added a new
row; both rewrote the same existing row. Picking automatically between them would
silently discard one author's intent — probably breaking behavior.

The allow-list for additive resolution is narrow and explicit:

1. Both sides added rows to the same markdown table
2. Both sides appended new sections to the same file
3. Both sides added elements to the same JSON array
4. Both sides added keys to the same JSON object (if they collide on the same key
   with different values, STOP — that's semantic too)

This example fits NONE of those. The resolver emits:

```
QUESTION: semantic conflict between #C and #D at CLAUDE.md commands table (merge row)
CONTEXT: Both PRs rewrote the same `merge #501` row with different merge-gating policies.
  #C: "T1 auto-merge if CI green; T2 requires supervisor attestation via MCP."
  #D: "Tier-aware; T1 auto-merge if CI green AND commander-review passed; T2+ refuse."
OPTIONS:
  1. Take #C — narrower change, aligns with the supervisor MCP work (ticket #50).
  2. Take #D — stricter policy, aligns with commander-review-gate hardening.
  3. Manual merge — the two policies are not compatible; a human must reconcile.
RECOMMENDATION: none — genuinely need a human. The two diffs encode different
  policy intents and both should not be silently picked.
```

Commander answers the question (from memory, FAQ, or by escalating to the
supervisor agent). The resolver never guesses on semantic conflicts.

## Contrast with the additive case

`expected-resolution.md` shows the additive case, where the resolver confidently
keeps both rows. The difference is structural:

- Additive: two sides added NEW things at the same anchor → concatenate.
- Semantic: two sides modified the SAME thing differently → cannot concatenate,
  must pick one or synthesize a third.

If you're writing a new resolver rule, it belongs in the additive list ONLY if
you can justify it with the structural test above.
