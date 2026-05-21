---
name: classify-pr-for-review
description: |
  Scope a PR diff before reviewing it: decide which files matter (source,
  tests, specs), which are noise to ignore (lockfiles, generated output,
  snapshots, dist/), and when the diff is security-adjacent and needs a
  `/cso` pass (`*auth*`, `*security*`, `*crypto*`, migrations). Use when you
  are `worker-review` and have just fetched a diff via `gh pr diff`, before
  running `/review`. Also teaches how to fold `/review` + `/codex review` +
  conditional `/cso` into one structured comment (Blockers / Concerns /
  Nits). Reduces reviewer-to-reviewer variance. (Hydra)
---

# Classify a PR diff for review

## Overview

`worker-review` must answer three questions before spending review budget on a
diff: which files matter, which are noise to skip, and is this security-adjacent
(→ add `/cso`). Getting it wrong wastes turns on lockfile churn, or — worse —
skips a `/cso` pass on an auth change. This skill pins the decisions into a table
+ worked examples so every reviewer scopes the same way. It is the extracted,
testable form of the scoping prose once inlined in `.claude/agents/worker-review.md`,
which now points here.

## When to Use

- You are `worker-review`, ran `gh pr view <n> --json files` + `gh pr diff <n>`,
  and are about to run `/review`.
- You need to decide whether to add a `/cso` pass, or want the comment template.

Skip when you are an implementation worker (you scope by the ticket, not a
review rubric).

## Process / How-To

1. **List changed files** from `gh pr view <n> --json files`.
2. **Bucket each file** with the decision table below: `include`, `exclude`, or
   `security-trigger`. A file can be both `include` and `security-trigger`.
   **Default to `include`** — a file is `exclude` only if it matches an explicit
   noise row (lockfile / generated / snapshot). Anything else (config YAML,
   `Dockerfile`, `state/*.json`, schemas, infra) is `include`.
3. **If ANY file is `security-trigger`**, the PR is security-adjacent: run `/cso`
   in addition to `/review` + `/codex review`.
4. **Review every `include` file in depth.** Mention `exclude` files only if their
   *presence* is the problem (a committed `.env`, a lockfile change in a docs-only
   PR — a scope smell worth a Concern).
5. **Build the EVIDENCE TABLE** (the two gates — see "Evidence-bound review"
   below): extract the ticket's acceptance criteria (approval gate), then attach
   a verdict + concrete evidence per criterion (verification gate). No `PASS`
   without evidence.
6. **Synthesize** `/review` + `/codex review` (+ `/cso` if run) into ONE comment
   using the template below; deduplicate findings the tools both raise. The
   evidence table sits between the `Commander review` header and `**Blockers**`.
7. **Validate the comment body** through `scripts/validate-evidence-table.sh`
   before posting (exit 0 required — see "Verification").
8. **Post** per `.claude/agents/worker-review.md` flow (post + label steps):
   blockers → `--request-changes`; `SECURITY:` blocker → also label
   `commander-stuck`.

### Decision table: file-path glob → action

| Glob | Action | Why |
|---|---|---|
| source (`src/**`, `lib/**`, `*.py` `*.ts` `*.go` `*.rs` `*.sh`, `scripts/**`); tests (`**/*test*`, `**/*spec*`); specs/docs (`docs/specs/**`, hand-written `*.md`); **and anything not matched by an exclude row below** (config YAML, `Dockerfile`, `state/*.json`, schemas) | `include` | Code, tests, specs, config — include is the default. |
| `*.lock`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `poetry.lock`, `go.sum` | `exclude` | Lockfile churn is noise; flag only if it appears in an unrelated PR. |
| `dist/**`, `build/**`, `**/*.min.js`, `**/*.map`, `**/generated/**`, `**/__generated__/**` | `exclude` | Generated output — review the source, not the artifact. |
| `**/__snapshots__/**`, `*.snap`, recorded fixtures/cassettes | `exclude` | Mechanical; review the code that produced them. |
| `*auth*`, `*security*`, `*crypto*` (path or filename) | `security-trigger` (and `include`) | Trust-boundary code → `/cso`. |
| migrations: `**/migrations/**`, `**/migrate/**`, `*.sql` *under* a migrations dir | `security-trigger` (and `include`) | Schema/data changes carry SQL-injection + data-loss risk. |

The four `security-trigger` categories — `*auth*`, `*security*`, `*crypto*`,
migrations — are verbatim the set in `.claude/agents/worker-review.md` and the
`worker-implementation` hard rule; identical on purpose, so the table never
disagrees with the pointer. **Optional heuristic (judgment, not the canonical
set):** a `*secret*` / `*token*` / `*password*` path, or a bare `*.sql` outside
migrations, is *also* worth a `/cso` pass if it reads credentials or runs raw
SQL.

### Evidence-bound review: the two gates (required)

A "clean" verdict is no longer a judgment call — it must be **evidence-bound**.
For EACH acceptance criterion the reviewer attaches concrete evidence, or marks
it explicitly unverified. **No criterion gets a clean PASS without evidence.**
This is the operator's "verify, don't trust" rule made mechanical (ticket #196,
spec `docs/specs/2026-05-21-evidence-based-review-gate.md`; EviBound /
Coordinator-Implementor-Verifier pattern).

1. **Approval gate (a) — extract the criteria.** Before reviewing, read the
   ticket (`gh issue view <n>` or the PR's `Closes #<n>` target) and pull its
   acceptance criteria into a list — one row per criterion. If the ticket has no
   explicit "acceptance criteria" section, derive them from the ticket's stated
   goals / "Output:" / test-for-real instructions (each becomes one criterion).
2. **Verification gate (b) — attach evidence per criterion.** For each row, pick
   a verdict and cite the evidence that justifies it:
   - `PASS` — REQUIRES concrete evidence: a command + its output, a test name +
     its pass line, or a diff `file:line`. Never `PASS` on "looks right".
   - `FAIL` — the criterion is not met; say what's wrong (evidence optional).
   - `UNVERIFIED` — you could not verify it (no fixture, needs a live service,
     out of review scope); say why. **A criterion you can't verify is
     `UNVERIFIED`, never `PASS`.**
3. **Encode it as the EVIDENCE TABLE** in the comment (template below).
4. **Validate before posting** — run the comment body through
   `scripts/validate-evidence-table.sh` (reads stdin or `--file`). It exits
   non-zero if any `PASS` row lacks evidence, a verdict is illegal, or the table
   is empty. Fix the table until it exits 0, THEN post. (See "Verification"
   below for the exact invocation.)

> **#197 extension point.** Evidence today is a command+output, a test+pass
> line, or a diff `file:line`. When #197 (session trace) lands, a fourth kind —
> `trace:<step-id>` pointing at a recorded session-trace step — becomes an
> *additional* evidence source. The checker already treats any non-empty
> Evidence cell as valid regardless of kind, so `trace:` references will work
> with NO checker change. Do NOT depend on #197 being present — gather evidence
> from test output / diffs / command output directly until it lands.

### Review-comment template

```markdown
Commander review of PR #<n>

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | <criterion text, from the ticket> | PASS | `<cmd>` -> `<output>` / test `<name>` -> `1 passed` / diff `file:line` |
| 2 | <criterion text> | FAIL | <what's wrong> |
| 3 | <criterion text> | UNVERIFIED | <why you couldn't verify it> |

**Blockers** (must fix before merge)
- <issue> — <file:line> — <which tool flagged it>
- SECURITY: <issue> — <file:line>   ← only for a genuine trust-boundary issue

**Concerns** (should address)
- <issue> — <file:line>

**Nits** (optional polish)
- <issue> — <file:line>

**Signed-off by** commander-review · skills run: /review, /codex review[, /cso]
```

The body MUST start with the literal `Commander review` — the timeout watchdog
recognizes a landed review via `(.body) | startswith("Commander review")`
(`rescue-worker.sh:391`); any other first line makes it dispatch a duplicate.
**The evidence table goes AFTER that first line** (between the header and
`**Blockers**`), so the body-prefix contract is preserved. Verdicts are
`PASS` / `FAIL` / `UNVERIFIED` (case-insensitive). A literal `|` inside an
Evidence cell must be escaped as `\|`. Use `(none)` under any empty
Blockers/Concerns/Nits section. Prefix a blocker with `SECURITY:` only for
genuine trust-boundary issues — that drives the `commander-stuck` label and
pages the operator.

## Examples

### Should trigger `/cso` — auth + SQL touched

```
 src/middleware/auth_session.ts  | 40 +++--
 migrations/0007_add_token.sql   | 12 ++
 package-lock.json               | 88 ++++----
```

`auth_session.ts` matches `*auth*`; `migrations/*.sql` matches the migration
globs. → security-adjacent: run `/cso`. Review the two source/migration files in
depth; `package-lock.json` is `exclude` (don't review it, but note it's expected
churn from a dep the PR adds).

### Should NOT trigger `/cso` — feature with an auth-shaped name in prose only

```
 docs/specs/2026-05-01-author-bio.md   | 30 ++
 src/components/AuthorCard.tsx         | 55 +++
 src/components/AuthorCard.test.tsx    | 40 +++
```

`AuthorCard` contains the substring "Author", not "auth" as a trust boundary —
no session/credential/crypto code. All three are `include`; none is
`security-trigger`. Run `/review` + `/codex review`, skip `/cso`. When unsure,
open the file: if it doesn't read credentials, sign/verify, or gate access,
it's not a trigger.

### Files to ignore as noise

```
 src/parser.ts                    | 18 ++
 dist/parser.min.js               | 1  +
 __snapshots__/parser.test.ts.snap| 6  ++
 yarn.lock                        | 24 +-
```

Only `src/parser.ts` is `include`. `dist/parser.min.js` (generated),
`__snapshots__/*.snap` (mechanical), and `yarn.lock` (lockfile) are all
`exclude` — reviewing them burns turns and adds nit noise. A docs-only PR that
*still* touched `yarn.lock` would warrant a Concern (scope smell), per the
lockfile-drift rule in `escalation-faq.md`.

## Verification

- **Shape:** `name:` matches the directory; `description:` ends in `(Hydra)`.
- **Table completeness:** every category the ticket names (source/tests/specs;
  lockfile/generated/snapshot/dist; `*auth*`/`*crypto*`/migrations) is covered.
- **Worked examples:** one positive `/cso` case, one negative, one noise case.
- **Evidence table enforced:** the review comment carries an EVIDENCE TABLE and
  passes the checker. Validate the body before posting:

  ```bash
  # body in a file:
  bash scripts/validate-evidence-table.sh --file /tmp/review-comment.md
  # or pipe it:
  printf '%s' "$comment_body" | bash scripts/validate-evidence-table.sh
  ```

  Exit 0 = every `PASS` carries evidence (post it). Exit 1 = a `PASS` lacks
  evidence / illegal verdict / zero criteria (fix the table). Exit 2 = no table
  found (you forgot it). Regression test: `bash scripts/test-validate-evidence-table.sh`.
- **Non-contradiction:** the canonical security-trigger set, "flag-don't-fix",
  `SECURITY:` → `commander-stuck`, and lockfile/baseline-noise rules all match
  the sources linked below — nothing here overrides them.

## Related

- `.claude/agents/worker-review.md` — the review flow this skill scopes; now
  points here instead of inlining the scoping prose.
- `memory/escalation-faq.md`: "I'm a review worker but spotted a bug" (flag,
  never fix); "My review found a security issue" (REQUEST_CHANGES + `SECURITY:`
  + `commander-stuck`); "A `/cso` review finds a blocker" (supervisor-loop
  trigger); pre-existing baseline lint + lockfile drift (out-of-scope noise).
- `apply-label-via-rest` — apply `commander-stuck` / `commander-reviewed` via REST.
- `scripts/rescue-worker.sh` — `--probe-review` matches the `Commander review` body prefix.
- `scripts/validate-evidence-table.sh` (+ `test-validate-evidence-table.sh`) —
  the deterministic checker enforcing "no clean PASS without evidence."
- `docs/specs/2026-05-21-evidence-based-review-gate.md` — the two-gate design
  (approval + verification) and the #197 extension point.
- gstack globals `/review`, `/codex`, `/cso` — the engines this orchestrates.
