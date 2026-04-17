---
title: "Add farewell() function matching greet() style + tests"
tier: T2
kind: feature
labels: []
---

## Summary

Mirror the existing `greet(name)` function with a `farewell(name)` counterpart that returns `"Goodbye, <name>!"` and follows the same fallback behavior (falsy / non-string / whitespace-only → `"world"`). Add two passing `node:test` cases covering the same two shapes as `greet.test.js`.

## Expected change

1. `src/farewell.js` — new file, exports `{ farewell }`. Same style as `src/greet.js`.
2. `src/farewell.test.js` — new file, two passing tests under `node:test`.
3. No changes to `package.json` dependencies (still zero-dep).
4. `package.json` `scripts.test` should run BOTH test files. Acceptable patterns: change to `node --test src/` (directory mode) OR add a second script and keep both runnable from `npm test`.

## Acceptance

- `node --test src/` exits 0 with 4 passing tests total.
- `farewell('Ada')` returns `"Goodbye, Ada!"`.
- `farewell('')`, `farewell(undefined)`, and `farewell('   ')` all return `"Goodbye, world!"`.
- No new `node_modules/` and no `package-lock.json` — zero-dep is load-bearing for this demo.

## Why this is T2

This is a small feature addition — new source file, new tests, small change to the test-runner config. It's not infra, not auth, not a migration. Commander will spawn a worker, the worker will open a draft PR, the review worker will gate it, and the operator will merge after eyeballing.
