---
status: draft
date: YYYY-MM-DD
author: <your-github-handle or "hydra worker">
---

# <Title>

## Problem

Why now? What's broken, missing, or suboptimal today? What observed signal triggered this spec (ticket, user complaint, incident, pattern in memory)?

Keep this concrete. "We should have better X" is not a problem statement; "Workers re-discover test commands on every ticket because no skill is promoted" is.

## Goals / non-goals

**Goals:** specific outcomes this spec delivers. Measurable if possible.

**Non-goals:** things people might assume are in scope but aren't. Saying "not doing X" here saves debates later.

## Proposed approach

One or two paragraphs describing the design. Include diagrams or small code sketches only if they clarify — don't ASCII-art for show.

### Alternatives considered

At least one. For each: what it is, what it'd cost, why it's not the pick.

- **Alternative A:** ...
- **Alternative B:** ...

## Test plan

How we'll know it works. At least one concrete check per goal listed above.

For Hydra framework changes specifically: reference the `self-test/` harness. A golden case that would have failed before and now passes is often the right test.

## Risks / rollback

- What could go wrong? (concrete scenarios, not "things could break")
- How do we back out if it does? (revert commit SHA? feature flag? update policy?)

## Implementation notes

(Fill in after the PR lands. Things that surprised you, gotchas future contributors should know.)
