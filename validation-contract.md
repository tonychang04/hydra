# Validation contract — #271

> README enhancement (docs). Assertions derived from the ticket's acceptance
> criteria: every claim verifiable in-repo, reads tighter, links resolve.
> Phase 1 written before edits (Verdict UNVERIFIED); Phase 2 fills evidence.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | Every relative link in README.md resolves to an existing in-repo path | `while read -r t; do [ -e "$t" ] \|\| echo "DEAD: $t"; done < <(grep -oE '\]\(([^)#]+)' README.md \| sed -E 's/^\]\(//' \| grep -vE '^https?:' \| grep -vE '^#'); echo scan-done` | only `scan-done`, no `DEAD:` lines | PASS | ran it -> printed only `scan-done`, zero `DEAD:` lines. (Caught one mid-edit: an `](state/memory-citations.json)` link to a gitignored file — fixed to inline code, re-ran clean.) |
| 2 | "Three worker types" stale claim removed | `grep -c 'Three worker types' README.md` | `0` | PASS | ran it -> `0`. Heading is now "Worker types". |
| 3 | Invented confirmation string removed | `grep -c 'hydra picked up its first ticket' README.md` | `0` | PASS | ran it -> `0`. Replaced with the real outcome ("a worker spawns … Commander reports a one-line status"). |
| 4 | Worker roster reconciled with the 7 files in `.claude/agents/` | `grep -cE 'worker-validator\|worker-auditor\|worker-conflict-resolver\|worker-codex-implementation' README.md` | `>= 1` | PASS | ran it -> `1` (the line naming all four on-demand workers; `ls .claude/agents/` = 7 files, README no longer claims three). |
| 5 | Dead staged-rollout spec link gone | `grep -c 'docs/superpowers/specs/2026-04-16-commander-agent-design.md' README.md` | `0` | PASS | ran it -> `0`. `find docs -iname '*commander-agent-design*'` returns nothing; pointer dropped (the five rungs are self-contained). |
| 6 | Learning-loop section names a real, on-disk code pointer | `grep -oE 'scripts/promote-citations.sh\|scripts/parse-citations.sh\|docs/specs/2026-04-17-skill-promotion-automation.md' README.md \| head -1 \| xargs -I{} test -e {} && echo OK` | `OK` | PASS | ran it -> `OK`. README "Memory & learning" now links `scripts/parse-citations.sh`, `scripts/promote-citations.sh`, and `docs/specs/2026-04-17-skill-promotion-automation.md` — all present on disk. |
| 7 | README is tighter (fewer lines than the 650-line start) | `awk 'END{print (NR < 650) ? "TIGHTER" : "NOT"}' README.md` | `TIGHTER` | PASS | ran it -> `605 lines -> TIGHTER` (down from 650; cut the duplicate "Try it in 10 minutes" section and the redundant ASCII "Mental model" diagram). |
