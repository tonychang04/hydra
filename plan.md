# Plan — #316 autopickup default interval 30 → 15

Checklist (each item names its file path + proof command). Tick after the in-flight self-check passes.

- [ ] Task 1 — Skeleton: spec `docs/specs/2026-06-26-autopickup-default-interval.md` + this plan + contract. Proof: `bash .github/workflows/scripts/syntax-check.sh` → OK.
- [ ] Task 2 — `CLAUDE.md:61` `default 30` → `default 15`. Proof: `grep "default 15" CLAUDE.md` + `bash scripts/check-claude-md-size.sh` in-band.
- [ ] Task 3 — `state/autopickup.json.example` `interval_min: 30` → `15`. Proof: `jq .interval_min state/autopickup.json.example` == 15.
- [ ] Task 4 — `scripts/hydra-setup.sh` non-interactive default + `[30]` prompt → 15. Proof: `grep "autopickup_interval=15" scripts/hydra-setup.sh`.
- [ ] Task 5 — `scripts/hydra-watch.sh:211` + `scripts/hydra-status.sh:104` `// 30` → `// 15`. Proof: `grep "interval_min // 15"` both files.
- [ ] Task 6 — `scripts/hydra-mcp-server.py:280,311` interval_min fallbacks → 15. Proof: `grep "15" ` + `python3 -c "import ast; ast.parse(...)"`.
- [ ] Task 7 — `docs/specs/2026-04-16-scheduled-autopickup.md` + `2026-04-16-autopickup-default-on.md` `30` defaults → 15. Proof: `grep -c "interval_min: 30\|default 30"` == 0 in both.
- [ ] Task 8 — NEW `scripts/test-autopickup-interval-default.sh` drift-guard (reads default + threshold from source, asserts default < threshold). Proof: `bash scripts/test-autopickup-interval-default.sh` exit 0.
- [ ] Task 9 — Register golden case `autopickup-interval-default` in `self-test/golden-cases.example.json`. Proof: `self-test/run.sh --kind=script --case autopickup-interval-default` exit 0.
- [ ] Task 10 — Verify: default-config tick `interval_warn==false` (before/after), `validate-state-all.sh` OK, size-guard in-band, syntax-check OK. Fill contract evidence.
