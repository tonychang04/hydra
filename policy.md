# Risk Tier Policy

> Policy evolves. When it changes, update `policy.md` AND `CLAUDE.md`'s safety rules section in the same PR.
> Self-test #30 (state schema) will eventually enforce this.

Classify every ticket BEFORE spawning a worker. If classification is ambiguous, ask the operator.

## Tier 1 — auto-merge eligible

Commander may merge automatically after CI is green.

**Qualifies:**
- Typo, grammar, doc-only changes (`.md`, comment changes, README updates)
- Dependency patch bumps (semver `x.y.Z` only, never minor or major)
- Pure test additions with no source changes
- Dead code removal inside a single file, <50 lines

**Hard limits:**
- Files changed: < 10
- Lines changed: < 100
- No files in excluded paths (see Tier 3)

## Tier 2 — commander auto-merges after review-worker clears the PR

Commander opens a draft PR, spawns `worker-review` against it, and — on a clean review — auto-merges once CI is green. The human is not in the default merge path.

**Per-repo override:** set `merge_policy` to `human` for a given tier in `state/repos.json` (see #20) to force human-merge for this repo. Hydra's own self-hosted entry defaults to `{T1: human, T2: human}` because framework changes are high-impact.

**Qualifies:**
- Feature work (new endpoints, UI changes, business logic)
- Bug fixes with source changes
- Refactors
- Dependency minor/major bumps
- Anything that doesn't meet T1 and isn't T3

## Tier 3 — refuse

Commander refuses to work the ticket. Labels `commander-stuck` + comments "Tier 3: needs human".

**Triggers (any match):**

Paths/filenames:
- `.github/workflows/**`
- `.env*`, `**/secrets/**`, `**/credentials*`
- `infra/**`, `terraform/**`, `kubernetes/**`, `k8s/**`, `helm/**`
- Any file matching `*auth*`, `*security*`, `*crypto*`, `*session*`, `*token*`, `*password*`
- Database migration files (`migrations/**`, `*.sql` schema changes)
- `Dockerfile`, `docker-compose*.yml`
- CI config outside `.github/` (`.circleci/`, `.gitlab-ci.yml`, etc.)

Labels/keywords:
- GitHub labels: `security`, `infra`, `breaking-change`, `migration`, `urgent-prod`
- Ticket body mentions: "SQL injection", "RCE", "CVE", "vulnerability", "production data", "customer data"

Behaviors:
- Any ticket requiring deploying, rolling back, or restarting services
- Any ticket requesting changes to user roles, permissions, or access control
- Any ticket involving PII handling, GDPR, SOC2, compliance paths

## Classification procedure

For each ticket:

1. Read body + labels + linked files
2. Check Tier 3 triggers first (most restrictive wins)
3. If not T3, check T1 hard limits
4. If not T1, default to T2

**When uncertain:** default to the more restrictive tier. It is always safe to bump T1→T2 or T2→T3. Never downgrade.

## Worker-side enforcement

Worker re-checks tier once it has read the code. If the ticket description suggested T1 but the actual code touches auth/migration/infra, worker stops immediately, labels `commander-stuck`, and comments "escalated to Tier 3 after reading code".
