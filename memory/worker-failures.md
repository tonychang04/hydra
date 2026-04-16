---
name: Worker failure modes
description: Recurring ways workers get stuck. Commander surfaces these in worker prompts to prevent repeats.
type: feedback
---

# Worker Failure Modes

Append a bullet when a worker hits `commander-stuck`. Format: `YYYY-MM-DD <repo>#<n> — <failure mode> — <what would have helped>`.

## Observed so far

- (populated over time)

## How commander applies this

When spawning a new worker, read this file. If any failure matches the repo or ticket shape, prepend a "known gotcha" note to the worker prompt.
