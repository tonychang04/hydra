---
title: "Fix typo in README (hollo -> hello)"
tier: T1
kind: doc-fix
labels: []
---

## Summary

The top-of-file heading in `README.md` currently reads `# hollo-hydra-demo`. It should read `# hello-hydra-demo`. Pure doc fix — no code changes.

## Expected change

In `README.md`:

- Replace the heading `# hollo-hydra-demo` with `# hello-hydra-demo`.
- Remove (or update) the explanatory "Note: there is an intentional typo..." paragraph directly underneath — once the typo is fixed, the note is stale.

## Acceptance

- `grep -i 'hollo' README.md` returns no matches.
- Tests still pass: `node --test src/greet.test.js`.
- No files outside `README.md` are touched.

## Why this is T1

Documentation-only change. No runtime behavior, no tests to author, no policy surface. Commander auto-merges on CI green.
