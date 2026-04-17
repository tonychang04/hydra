# Auto-filed issue template

> Skeleton body for issues filed by `worker-auditor`. The subagent fills each `{{PLACEHOLDER}}` and strips this header line before calling `gh issue create --body "$(cat <rendered>)"`.
>
> See the spec at `docs/specs/2026-04-17-worker-auditor-subagent.md` and the subagent definition at `.claude/agents/worker-auditor.md`.

---

## Problem

{{PROBLEM}}

<!--
One paragraph. What drift did the auditor observe between CLAUDE.md (or
another framework doc) and the actual state of the codebase? Concrete
observation, not aspiration. Example:

  CLAUDE.md's "Scheduled retro" section says auto-run every Monday 09:00
  local. No cron, /loop, or scheduler invocation currently triggers the
  retro command. Operators still have to type `retro` by hand.
-->

## Evidence

{{EVIDENCE}}

<!--
Specific, grep-able citations. Line numbers, file paths, and short
verbatim quotes. Future workers grepping the issue should be able to
re-find the drift without reading minds. Example:

  - CLAUDE.md:L285 — "Scheduled retro (when scheduled autopickup ships):
    auto-run every Monday 09:00 local."
  - No match for `retro` in .claude/agents/* or scripts/loop*.sh
  - state/autopickup.json has no `retro_schedule` field
-->

## Proposed fix

{{PROPOSED_FIX}}

<!--
A sketch, not a spec. One or two paragraphs suggesting the shape of the
fix; the worker-implementation that picks this ticket up will write the
real spec. Keep this hypothesis-flavored, because the auditor doesn't
implement — a later worker does, and over-specifying here locks them in.

Example:

  Extend the autopickup tick procedure to check `scripts/date +%u` for
  Monday; on a Monday tick where `last_retro < 7 days ago`, prepend a
  `retro` invocation to the normal pickup loop. Persist `last_retro` in
  state/autopickup.json alongside last_run. Alternative: spawn a
  dedicated weekly schedule worker instead of piggybacking on autopickup.
-->

## Tier

{{TIER}}

<!--
Exactly one of: T1, T2, T3. Classified per policy.md:

  - T1: docs-only gap (no source changes needed)
  - T2: source gap (new/changed behavior in a subagent, script, or
    state file)
  - T3: security/compliance/auth/migration/infra gap

When in doubt, round UP. Commander will refuse T3 on spawn.
-->

## Source

{{SOURCE}}

<!--
Attribution line, verbatim format:

  Source: auto-filed by worker-auditor on YYYY-MM-DD from CLAUDE.md:LXXX

Replace YYYY-MM-DD with the run date and CLAUDE.md:LXXX with the line
number that motivated the filing. If the evidence came from a log file
or memory doc instead, substitute that path. Multiple sources separated
by commas. Example:

  Source: auto-filed by worker-auditor on 2026-04-17 from CLAUDE.md:L285,
  memory/retros/2026-15.md
-->
