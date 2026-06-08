# Validation contract — #275 (new Hydra skill: respond-to-review)

> Written from the ticket's acceptance criteria, then filled with captured
> EVIDENCE (command + exit code + output snippet) before finalizing the PR.
> Hydra's own ticket → committed (validator re-runs it). Offline, no network.
> Spec: docs/specs/2026-06-07-skill-respond-to-review.md

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | Skill has valid frontmatter (`name` matches dir, `version`, `description` ends `(Hydra)`) — AC #1 | `awk '/^---$/{c++;next} c==1' .claude/skills/respond-to-review/SKILL.md \| grep -E '^(name\|version\|description):' && grep -q 'name: respond-to-review' .claude/skills/respond-to-review/SKILL.md && grep -qE '\(Hydra\)' .claude/skills/respond-to-review/SKILL.md && echo FRONTMATTER_OK` | exit 0 / `FRONTMATTER_OK` | UNVERIFIED | |
| 2 | Matches sibling skill format — six canonical H2 sections in order (Overview, When to Use, Process / How-To, Examples, Verification, Related) — AC #1 | `grep -nE '^## ' .claude/skills/respond-to-review/SKILL.md` | the six sections in canonical order | UNVERIFIED | |
| 3 | Under the ~150-line ceiling (sibling-format constraint from README) | `wc -l < .claude/skills/respond-to-review/SKILL.md` | <= 150 | UNVERIFIED | |
| 4 | A re-spawned worker would match + read it — discoverable via the dispatcher's enumerate-and-match mechanism (file present + roster line present) — AC #2 | `test -f .claude/skills/respond-to-review/SKILL.md && grep -q 'respond-to-review' .claude/skills/using-hydra-skills/SKILL.md && echo DISCOVERABLE` | exit 0 / `DISCOVERABLE` | UNVERIFIED | |
| 5 | No duplication/contradiction with existing memory; no edits to the four files other workers own (worker-implementation.md, CLAUDE.md, README.md, worker-review.md) | `git diff --name-only origin/main \| grep -E 'worker-implementation.md\|^CLAUDE.md\|^README.md\|worker-review.md'; echo "rc=$?"` | rc=1 (no match → none of those files touched) | UNVERIFIED | |
| 6 | CI syntax check is green (spec frontmatter + all scripts/agents parse) | `bash scripts/preflight-syntax.sh` | exit 0 / "syntax-check: OK" | UNVERIFIED | |
| 7 | THIS ticket's own contract passes the #255 presence gate | `bash scripts/validate-contract.sh --file validation-contract.md` | exit 0 | UNVERIFIED | |
