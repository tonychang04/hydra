---
status: draft
date: 2026-04-17
author: hydra worker (issue #31)
---

# Permission inheritance audit

## Problem

`SECURITY.md` makes load-bearing claims — "worktree FS isolation",
"self-modification is blocked", "no external curl" — but those claims
are currently backed by rules in the permission profile, not by
receipts. Specifically, the three worker subagents
(`.claude/agents/worker-*.md`) do not declare `permissionMode`,
`tools`, or `disallowedTools`; they rely on inheriting the operator's
strict denylist from the Commander session.

From what the Claude Code subagent docs say, that inheritance is the
default behavior. But nobody has actually run a worker, had it attempt
`cat ~/.ssh/id_rsa`, and observed the denial fire. If inheritance is
broken or partial — due to an upstream Claude Code change, a subtle
interaction with subagent frontmatter, or a path-resolution bug — a
misbehaving worker could read secrets Commander itself is denied.

Observed signal: ticket #31 opened by operator explicitly flagging the
gap, plus the fact that `SECURITY.md` has been a documentation-only
artifact with no probe harness.

## Goals / non-goals

**Goals:**

- Document a reproducible permission probe: 9 actions, each with
  `{expected, observed}`, emitted as JSONL.
- Produce the probe fixture (`self-test/fixtures/permission-probe/`)
  and the audit doc
  (`docs/security-audit-2026-04-17-permission-inheritance.md`) that
  interprets probe output.
- Wire the probe into `self-test/golden-cases.example.json` under a
  SKIP'd `kind: worker-subagent` case so it becomes live the moment
  ticket #15's follow-up executor lands.
- Update `SECURITY.md` to mark each claim VERIFIED vs ASSUMED and
  reference the audit doc as evidence.
- Harden the three worker subagents' frontmatter with explicit
  `disallowedTools: [WebFetch, WebSearch]` as belt+suspenders defense
  in depth (workers never need to browse the web; the repo is the
  scope).

**Non-goals:**

- Actually EXECUTING the probe against a live Commander. That
  requires the operator's real `.claude/settings.local.json` and a
  live `./hydra` session; it's an operator step, not a PR step.
- Changing `.claude/settings.local.json*`. This is the operator's
  file; the audit PR is forbidden from touching it. Gaps identified
  by the audit (e.g. `git config --global` not in deny list) are
  documented as follow-up work.
- Changing `policy.md` or `budget.json`. Same reasoning.
- Running the probe against MCP tool calls (Linear, GitHub). That's
  a separate audit tracked in `docs/mcp-tool-contract.md`.
- Phase 2 cloud Commander. Sandboxed workers have a different
  permission model entirely.

## Proposed approach

Three deliverables in the same PR, each independently reviewable:

1. **Probe fixture** (`self-test/fixtures/permission-probe/`):
   - `probe-script.sh` — non-destructive bash probe, 9 actions
     corresponding to the 5 threat-model categories plus the worktree
     CLAUDE.md positive case plus the `git config --global` gap.
   - `expected-outcomes.json` — canonical expected result per action
     with the governing deny rule.
   - `README.md` — run instructions, safety rules, schema.

2. **Audit doc**
   (`docs/security-audit-2026-04-17-permission-inheritance.md`):
   - Threat model (what a rogue worker wants).
   - Inheritance theory (what the docs say).
   - The 9-action probe table.
   - Observed column marked PENDING pending operator run.
   - Findings (currently: `git config --global` gap, worktree
     CLAUDE.md false alarm, theoretical `$COMMANDER_ROOT` resolution).
   - Remediation checklist the operator fills in after the probe.

3. **Worker subagent hardening**:
   - Add `disallowedTools: [WebFetch, WebSearch]` to all three
     `.claude/agents/worker-*.md` frontmatter blocks.
   - Document rationale in each worker's body ("workers don't need
     the web; the repo IS the scope").
   - This is the ONLY actual permission-surface change in the PR.

4. **SECURITY.md** gets a VERIFIED/ASSUMED table plus a Verification
   procedure section linking to the probe fixture and audit doc.

5. **Self-test golden case** added as `permission-probe` kind
   `worker-subagent`, SKIP today, live when the executor ships.

### Alternatives considered

- **Run the probe directly in this PR.** Rejected because: (a) probe
  needs operator's real `.claude/settings.local.json` (gitignored);
  (b) worker-subagent spawn path doesn't exist in the shell runner
  yet; (c) running it from a dev agent's context produces different
  results than a real Commander session. The specification-first
  approach lets this PR land without a live execution, with the
  operator-side receipt landing separately.
- **Add `permissionMode: restrictive` to each worker frontmatter.**
  Rejected because: (a) we haven't established the current
  inheritance behavior is broken, so tightening mode pre-audit is
  premature; (b) `permissionMode` semantics may diverge from what
  operators expect. The audit is meant to inform whether that
  change is needed, not presume it.
- **Put the probe as a bash script under `scripts/`.** Rejected:
  the probe's job is to be run BY a worker subagent, not by the
  operator directly. `self-test/fixtures/` is the right home —
  fixtures are inputs to the self-test harness, which is exactly
  what we want.

## Test plan

Per the Tests section of the ticket brief:

- `bash -n self-test/fixtures/permission-probe/probe-script.sh` —
  syntax-clean.
- `jq . self-test/fixtures/permission-probe/expected-outcomes.json` —
  valid JSON.
- `jq . self-test/golden-cases.example.json` — valid JSON after the
  new case is appended.
- Grep each worker subagent frontmatter for `disallowedTools:` present
  and containing both `WebFetch` and `WebSearch`.
- Smoke-run the probe script as plain shell and confirm it emits 9
  JSONL lines, each valid JSON.

Full receipt (observed column of the audit doc) is operator work, not
covered by this PR's CI-style tests.

## Risks / rollback

- **Risk:** probe script has a bug that masks a real denial.
  Mitigation: the script uses `set -u` but intentionally NOT `set
  -e`, so each action runs independently; a probe bug on action N
  doesn't hide observations for actions N+1..9. The `classify`
  helper is small and unit-testable.
- **Risk:** adding `disallowedTools` to workers accidentally blocks
  a legitimate use case (e.g. a worker that needed to fetch an RFC
  URL via WebFetch). Mitigation: the three workers today never
  invoke `WebFetch` or `WebSearch` per their prompts; the repo IS
  the scope. If a future worker type needs the web, it declares its
  own frontmatter accordingly.
- **Risk:** the `git config --global` finding causes alarm without
  action. Mitigation: the audit doc classifies it as low-to-medium
  impact and proposes a follow-up, not a hotfix. No SECURITY
  advisory is warranted.
- **Rollback:** revert commit. The probe fixture is inert; the
  `disallowedTools` addition is the only active behavior change and
  it only removes capability from workers that already don't use it.

## Implementation notes

- The audit doc is explicitly dated 2026-04-17 (tomorrow in operator
  TZ when the PR is authored) so the doc header aligns with when the
  operator will actually run the receipt. If the operator runs it
  sooner, the date in the header is purely a version marker, not a
  timestamp — update in the follow-up PR that fills in Observed.
- The self-test case uses `worker_type: worker-implementation`
  (not a dedicated probe-worker type) because the simplest executor
  shape spawns a regular implementation worker and passes the probe
  script as its task. When the executor lands, if it needs a custom
  probe-worker subagent, that's a schema change for the case, not
  for the fixture.
- The probe tests are written to be idempotent and non-destructive:
  action 9 (`git config --global`) reads the original value first
  and restores it, even in the plain-shell smoke-run. Action 7
  (`write home`) removes the takeover file if it somehow succeeded.
