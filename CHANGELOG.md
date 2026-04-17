# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-04-17

### Added
- Retro workflow (#1 / #3): weekly summaries to memory/retros/YYYY-WW.md
- Scheduled autopickup (#2 / #10): cron-ish auto-pickup, default ON since #17 / #23
- Memory layer plumbing (#6 / #12): scripts/parse-citations.sh, validate-learning-entry.sh, validate-citations.sh + fixtures
- Label application via REST API (#11 / #22)
- Self-test runner (#15 / #24): ./self-test/run.sh
- Linear MCP integration (#5 / #33): scripts/linear-poll.sh + contract + fixtures
- S3 knowledge store adapter (#13 / #34): scripts/state-get.sh, state-put.sh, memory-mount.sh, localstack e2e
- policy.md T2 auto-merge policy clarification (#27 / #39)
- Exercise worker-test-discovery (#32 / #43)
- State JSON schemas (partial for #30, PR #44)
- MCP agent-only interface contract (#50 / #52)
- Three worker types: worker-implementation, worker-review, worker-test-discovery
- Worker subagent definitions with isolation:worktree + memory:project
- Permission profile with self-modification denylist
- Spec-driven docs under docs/specs/
- Self-test harness with golden cases + runner
- setup.sh + install.sh + ./hydra launcher
- Badges, SECURITY.md, CONTRIBUTING.md, PR template, issue templates
- README Mermaid diagrams + glossary + learning-loop TL;DR

### Security
- Self-modification denylist (commander cannot edit its own CLAUDE.md / policy.md / budget.json mid-session)
- Worktree filesystem isolation per worker
- Tier 3 refusal (auth / migrations / infra / secrets / workflows)
- External URL curl denied (workers only hit localhost)

### Known limitations
- Webhook triggers pending (#40, #41)
- CI pending (#16)
- Conflict-resolver skill pending (#7)
- Cloud deployment (Fly.io) in flight (#48)
- Agent-only interface server binary pending (follow-up to #52)

[Unreleased]: https://github.com/tonychang04/hydra/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tonychang04/hydra/releases/tag/v0.1.0
