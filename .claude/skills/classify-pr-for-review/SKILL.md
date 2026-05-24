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
   in addition to `/review`. (`/codex review` is OFF by default — it may still run
   as the opt-in step-8 cross-family security critic, but is not part of the
   default gate. See `.claude/agents/worker-review.md` Flow step 6.)
4. **Review every `include` file in depth.** Mention `exclude` files only if their
   *presence* is the problem (a committed `.env`, a lockfile change in a docs-only
   PR — a scope smell worth a Concern).
5. **Build the EVIDENCE TABLE** (the two gates — see "Evidence-bound review"
   below): extract the ticket's acceptance criteria (approval gate), then attach
   a verdict + concrete evidence per criterion (verification gate). No `PASS`
   without evidence.
6. **Synthesize** `/review` (+ `/codex review` only if opted in — it is OFF by
   default; see `.claude/agents/worker-review.md` Flow step 6) (+ `/cso` if run)
   into ONE comment using the template below; deduplicate findings the tools both
   raise. The evidence table sits between the `Commander review` header and
   `**Blockers**`.
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

1. **Approval gate (a) — extract the criteria.** Before reviewing, pull the
   acceptance criteria into a list — one row per criterion — from the best
   available source: a GitHub `Closes #<n>` ticket (`gh issue view <n>`), a
   Linear `Closes LIN-123` issue (via the `linear` MCP server), or — when the PR
   has no ticket reference at all (a `worker-test-discovery` /
   `worker-conflict-resolver` PR) — the PR body + commit messages
   (`gh pr view <n> --json body,title` + the commit log). If the source has no
   explicit "acceptance criteria" section, derive criteria from its stated goals
   / "Output:" / test-for-real instructions. The gate never stalls for lack of a
   GitHub ticket — the PR body is always a usable source.
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

### Adversarial pass for SECURITY findings only (Refute-or-Promote, #199)

The evidence table above binds *acceptance criteria* to evidence. Security
*findings* (the things `/cso` / `/review` / `/codex` flag as exploitable) get a
SECOND, adversarial gate before any of them reaches the operator. This runs
**only for a security-adjacent diff** (any `security-trigger` file — same scope
as the `/cso` trigger; never for a T1/non-security PR, so no extra cost there)
**and only when the first reviewer raised ≥1 security finding.**

The first reviewer (`/review` + `/codex review` + `/cso`) produces security
finding *claims*. For each claim, run a **critic** to try to KILL it:

1. **Kill mandate.** The critic's job is to **disprove the finding, not improve
   it.** It looks for a code-grounded reason the finding cannot occur (the
   "unsanitized" input is validated two lines up; the "missing" check exists in a
   guard; the algorithm is already constant-time). Default posture: *this finding
   is wrong until demonstrated.*
2. **Context asymmetry (anti-anchoring).** Give the critic ONLY the finding claim
   + the diff — NOT the proposer's reasoning, severity, or confidence. If the
   critic sees "HIGH severity, definitely exploitable" it anchors and
   rubber-stamps. Asymmetry forces an independent look.
3. **Cross-family critic — proposer ≠ critic family.** Run the critic on a
   DIFFERENT model family than whichever engine *raised* the finding. That
   directionality is the anti-anchoring point:
   - finding raised by `/review` or `/cso` (Claude family) → critic is
     `/codex review` (already wired; no new backend);
   - finding raised by `/codex review` itself → critic is Claude's own reasoning
     (re-examine the claim against the diff directly). Do NOT send a codex-raised
     finding back to `/codex review` — that would have the same family critique
     itself, defeating the gate.
4. **The load-bearing HARD RULE — unanimity is NOT confidence.** Two reviewers
   agreeing does not promote a finding. Belief changes ONLY on:
   - a **code-grounded empirical refutation** → the critic verdict is `REFUTED`;
     the finding is **DROPPED**; or
   - an **empirical oracle** — a PoC, a failing/added test, or a reproduction
     command + output — demonstrating the finding is real → the critic verdict is
     `SURVIVED` and, with the oracle attached, the finding is **REPORTED**.
   - A finding that survived critique but has NO oracle (only "looks
     exploitable", only agreement) is **DROPPED** — logged in the table so the
     operator can see the suspicion, but NOT escalated as a blocker. This is the
     anti-noise rule: the operator is only paged on findings backed by an oracle.
5. **Encode it as the FINDINGS TABLE** (template below) and **validate before
   escalating** — run the comment body through `scripts/validate-security-findings.sh`.
   It exits non-zero if a `REPORTED` finding lacks an oracle, a `REPORTED` finding
   was `REFUTED`, or a verdict/disposition is illegal. Fix the table until it
   exits 0, THEN post. Only `REPORTED` rows become `SECURITY:`-prefixed blockers.

> **Why this exists.** Raw AI security review gets muted as noise (the CodeForge /
> CodeRabbit landscape: 15% noise + 21% nitpicking → "engineers mute them"). A
> finding that costs an operator page but turns out to be nothing trains the
> operator to ignore the channel — the worst outcome for the safety pillar. The
> consensus/validation gate is what makes findings trusted. Spec:
> `docs/specs/2026-05-21-adversarial-consensus-review.md`.

### Review-comment template

```markdown
Commander review of PR #<n>

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | <criterion text, from the ticket> | PASS | `<cmd>` -> `<output>` / test `<name>` -> `1 passed` / diff `file:line` |
| 2 | <criterion text> | FAIL | <what's wrong> |
| 3 | <criterion text> | UNVERIFIED | <why you couldn't verify it> |

<!-- SECURITY PRs ONLY (security-trigger diff + ≥1 finding raised) — omit otherwise -->
**Security findings — adversarial pass (kill mandate)**

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | <finding claim, one line> | SURVIVED | PoC `<cmd>` -> `<observed>` / failing test `<name>` -> `1 failed` / diff `file:line` | REPORTED |
| 2 | <finding claim> | REFUTED | critic: <code-grounded refutation> — diff `file:line` | DROPPED |
| 3 | <finding claim> | SURVIVED | (none) | DROPPED |

**Blockers** (must fix before merge)
- <issue> — <file:line> — <which tool flagged it>
- SECURITY: <issue> — <file:line>   ← only for a genuine trust-boundary issue

**Concerns** (should address)
- <issue> — <file:line>

**Nits** (optional polish)
- <issue> — <file:line>

**Signed-off by** commander-review · skills run: /review[, /codex review][, /cso]
```

The body MUST start with the literal `Commander review` — the timeout watchdog
recognizes a landed review via `(.body) | startswith("Commander review")`
(`rescue-worker.sh:391`); any other first line makes it dispatch a duplicate.
**Both tables go AFTER that first line** (evidence table, then — for a security
PR — the findings table, then `**Blockers**`), so the body-prefix contract is
preserved. Evidence-table verdicts are `PASS` / `FAIL` / `UNVERIFIED`; findings-
table critic verdicts are `SURVIVED` / `REFUTED` and dispositions are
`REPORTED` / `DROPPED` (all case-insensitive). A literal `|` inside any cell must
be escaped as `\|`. Use `(none)` under any empty Blockers/Concerns/Nits section.
**The findings table is omitted entirely for non-security PRs and for security
PRs with zero raised findings** (do not emit an empty one — the checker rejects a
zero-row table). Prefix a blocker with `SECURITY:` only for genuine
trust-boundary issues — and only for findings the adversarial pass marked
`REPORTED` (survived + oracle); that drives the `commander-stuck` label and pages
the operator. A `DROPPED` finding never becomes a blocker.

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

### Adversarial pass — non-reproducible finding DROPPED, PoC-backed one KEPT (#199)

`/cso` on an auth PR raises three security findings. The critic (cross-family,
`/codex review`, kill mandate, sees only the claim + diff) processes each:

```markdown
**Security findings — adversarial pass (kill mandate)**

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | SQL injection via `name` query param | SURVIVED | PoC `curl 'localhost/u?name=%27;DROP--'` -> 500 + SQL stacktrace | REPORTED |
| 2 | Timing attack on token compare | REFUTED | critic: uses `crypto.timingSafeEqual`, diff `auth.ts:88` | DROPPED |
| 3 | Possible missing rate limit on /login | SURVIVED | (none) | DROPPED |
```

- **Finding 1** survived the critic AND has a working PoC → `REPORTED` → becomes
  a `SECURITY:` blocker and pages the operator. This is a finding worth a page.
- **Finding 2** the critic killed with a code-grounded refutation (the compare is
  already constant-time) → `REFUTED` → `DROPPED`. Reporting it would have paged
  the operator on a non-issue.
- **Finding 3** survived critique (nobody could disprove it) but nobody produced
  an oracle either → `DROPPED`. *Unanimity is not confidence* — it is logged so
  the operator can dig, but it does not page anyone. Marking it `REPORTED` would
  fail `validate-security-findings.sh` (REPORTED needs a non-empty Oracle).

Run `bash scripts/validate-security-findings.sh --file <comment>` before posting:
only after it exits 0 do the `REPORTED` rows become `SECURITY:` blockers.

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
- **Findings table enforced (security PRs only):** for a `security-trigger` diff
  with ≥1 raised finding, the comment carries a FINDINGS TABLE and passes the
  adversarial checker. Validate the body before escalating:

  ```bash
  bash scripts/validate-security-findings.sh --file /tmp/review-comment.md
  # or: printf '%s' "$comment_body" | bash scripts/validate-security-findings.sh
  ```

  Exit 0 = every `REPORTED` finding survived the critic + has an oracle (post it).
  Exit 1 = a `REPORTED` finding lacks an oracle / was `REFUTED` / illegal
  verdict-or-disposition / zero findings (fix the table). Exit 2 = no table found
  (omit the table for non-security PRs; for security PRs with findings it's
  required). Regression test: `bash scripts/test-validate-security-findings.sh`.
- **Non-contradiction:** the canonical security-trigger set, "flag-don't-fix",
  `SECURITY:` → `commander-stuck`, and lockfile/baseline-noise rules all match
  the sources linked below — nothing here overrides them. The adversarial pass is
  ADDITIVE: it only ever DROPS or REPORTS findings the existing reviewers raised;
  it never widens the trigger set or the `SECURITY:` semantics.

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
- `scripts/validate-security-findings.sh` (+ `test-validate-security-findings.sh`)
  — the deterministic checker enforcing the adversarial gate: a security finding
  is `REPORTED` only if it survived the critic AND carries an empirical oracle.
- `docs/specs/2026-05-21-evidence-based-review-gate.md` — the two-gate design
  (approval + verification) and the #197 extension point.
- `docs/specs/2026-05-21-adversarial-consensus-review.md` — the Refute-or-Promote
  design (kill mandate, context asymmetry, cross-family critic, the findings
  table + checker).
- gstack globals `/review`, `/codex`, `/cso` — the engines this orchestrates;
  `/codex review` doubles as the cross-family adversarial critic for #199.
