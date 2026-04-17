# Bot-account mode (phase 1): per-repo `assignee_override`

**Ticket:** [#26](https://github.com/tonychang04/hydra/issues/26) · **Tier:** T2 · **Status:** draft

## Problem

Today the `assignee` pickup trigger hardcodes `@me`:

> CLAUDE.md "Operating loop" step 3 — `gh issue list --assignee @me --state open`

The operator's GitHub user is also the account they use for their own personal in-progress work. So "assigned to me" conflates two things:

1. "I'm working on this myself, don't touch it."
2. "Commander, take this."

Every personal ticket you self-assign gets grabbed by Hydra the next tick. You can't tell at a glance which tickets are yours vs Commander's. And in multi-operator setups, there's no way to scope what Hydra sees at all — everyone's personal tickets leak into the pool.

## Goals

- Per-repo, opt-in: a single string field `assignee_override` on the `state/repos.json` entry says "poll this username instead of `@me`".
- Fully backward-compatible: if `assignee_override` is absent, behavior is exactly today's `@me` flow. No migration needed.
- The `./hydra add-repo` CLI grows a `--assignee <user>` flag so setting the override is a one-command step.
- Documented in the phase 2 VPS runbook under a new "Using a dedicated bot account" section, so operators see the workflow when they're wiring up a cloud deployment.
- Self-test exercises the new field and the `--assignee` flag against a fixture, proving the override changes the pickup query without spawning a real worker.

## Non-goals (explicitly deferred)

The ticket body imagines a larger bot-account workflow (bot-token file at `~/.hydra/bot-token`, `./hydra set-bot` command, bot-authored PRs and comments, review-worker postings under the bot identity, token-expiry auto-pause, etc.). Those are **separate tickets**. This spec ships the one piece that is independently useful and genuinely back-compat: routing the pickup query through an override username.

Once `assignee_override` is in place, follow-up tickets can layer on:

- Bot-token management (where the token lives, permission model, expiry detection, auto-pause).
- PR / comment / label authorship via the bot account (requires the bot-token layer).
- Global "use this bot for every repo" convenience flag (we only ship per-repo override in phase 1 because it composes cleaner with `state/repos.json`'s existing per-repo shape).
- `./hydra unset-bot` / `--unset-assignee` ergonomics.

All of the above can be added without breaking anything this spec ships — the `assignee_override` field is additive at the schema level, and the pickup code fall-back is the same code path that exists today.

## Proposed approach

### Schema change

`state/schemas/repos.schema.json` gains one optional property on each `repos[]` entry:

```json
"assignee_override": {
  "type": "string",
  "minLength": 1,
  "pattern": "^[A-Za-z0-9-]+(\\[bot\\])?$",
  "description": "Optional. GitHub username (or `foo[bot]` app handle) to use with `gh issue list --assignee` instead of `@me`. Bot-account mode (ticket #26)."
}
```

- `minLength: 1` — explicit rejection of an empty string. If the field exists it must have a value; unset = fall back to `@me`.
- `pattern` — mirrors GitHub's login format (alphanumeric + dashes, optional `[bot]` suffix for GitHub Apps). Rejects obviously-invalid input like `foo/bar`, `@name`, or a URL. This is a cheap first-line sanity check; the real validation happens when `gh issue list --assignee <name>` returns an HTTP error, which commander already surfaces.
- Additive only. No existing required-fields list changes.
- Additional compatibility: existing entries without the field continue to validate with no edits.

### CLAUDE.md change

Single line in "Operating loop" step 3 to document the lookup:

> **assignee** (GitHub default): `gh issue list --assignee <user>` where `<user>` is the repo's `state/repos.json:assignee_override` if set, otherwise `@me` (today's behavior). Used to route tickets to a dedicated service account ("bot mode") so they're unambiguous vs. tickets the operator is actively working on themselves. See `docs/specs/2026-04-17-assignee-override.md`.

Everything else about the assignee trigger (state-label skip, `commander-working` / `commander-pause` / `commander-stuck` semantics) is unchanged.

### `./hydra add-repo --assignee <user>` flag

`scripts/hydra-add-repo.sh` grows a non-interactive flag and one prompt step. Same pattern as the existing `--trigger`:

```
  --assignee <user>       Optional. Username to poll instead of @me on the
                          assignee trigger. Enables bot-account mode for this
                          repo. See docs/specs/2026-04-17-assignee-override.md.
```

- In interactive mode, the wizard prompts for `assignee_override` only when the chosen `ticket_trigger` is `assignee` (the override is meaningless for `label` / `linear`). Default is "none / fall back to @me"; pressing Enter at the prompt keeps the override unset.
- Non-interactive mode accepts `--assignee <user>` (and omits the field if not given).
- Validation: the CLI applies the same regex as the schema locally (`^[A-Za-z0-9-]+(\[bot\])?$`) and exits 2 on invalid input, mirroring how `--trigger` rejects bad values.
- `--assignee ""` (empty string) is explicitly rejected (exit 2) — we don't want a way for the user to write a "null-like" override; unset and explicit-value are the only two states.
- The written JSON omits `assignee_override` entirely when no override is given. This keeps `state/repos.json` diffs minimal for operators who never use bot mode.

### Docs: `docs/phase2-vps-runbook.md` "Using a dedicated bot account"

New section explaining when and how to use `assignee_override`:

- **When:** you're running Hydra against repos you share with other collaborators OR you want clearer separation between "my in-progress tickets" and "tickets Commander should take".
- **How:** create a GitHub user (free plan is fine — `hydra-bot-<operator>`), grant it collab access to each repo in `state/repos.json`, then set the override per-repo via `./hydra add-repo <owner>/<name> --assignee hydra-bot-<operator>` (or edit `state/repos.json` by hand).
- **What this does NOT cover** (forward-refs the deferred tickets): bot-token storage, bot-authored PRs, etc. The runbook explicitly says "phase 1: the bot is the polling identity only; Commander still speaks as the operator's configured `GITHUB_TOKEN` when opening PRs and commenting".
- **Rollback:** remove the `assignee_override` field from the entry (or run `./hydra add-repo --force` without `--assignee`). Next tick, Commander is back to `@me`.

### Self-test: `repo-assignee-override`

Script-kind case under `self-test/golden-cases.example.json` + fixture at `self-test/fixtures/assignee-override/`.

Asserts:

1. A `state/repos.json` fixture with `assignee_override: "hydra-bot-example"` passes schema validation (current schema + the patched schema this PR ships).
2. The same fixture with an invalid value (`@me`, URL, or empty string) is rejected by `scripts/validate-state.sh` with a clear error.
3. Running `scripts/hydra-add-repo.sh foo/bar --local-path <tmp-repo> --non-interactive --assignee hydra-bot-foo --trigger assignee --state-file <tmpdir>/repos.json` (or the working-dir equivalent the script already supports) writes an entry containing `"assignee_override": "hydra-bot-foo"`. The exit code is 0.
4. Re-running without `--assignee` (fresh tmpdir) writes an entry without the field, proving absence-is-default.
5. Running with `--assignee ""` exits 2 — the empty-string rejection case.

No Claude auth required. No real `gh` call. The assertion is purely on the JSON state file. This lets the case run on every CI tick as a `script`-kind regression.

## Test plan

| Layer | How | Where |
|---|---|---|
| Schema | `jq empty state/schemas/repos.schema.json` + ajv-cli strict pass on the existing fixture and a new override-positive fixture | Exercised by the existing `state-schemas` self-test case + the new `repo-assignee-override` case. |
| CLI | `./scripts/hydra-add-repo.sh` smoke tests (help text includes `--assignee`; valid write; invalid rejection; absent-flag no-field) | `repo-assignee-override` case steps 3-5. |
| Docs | `docs/phase2-vps-runbook.md` new section renders + link-checks (existing CI `syntax-check.sh` covers this). | CI. |
| Behavior note | CLAUDE.md edit is a single documentation clause — no Commander behavior implementation file to test; self-test's `repo-assignee-override` proves the override is wired end-to-end through the schema + CLI. | `repo-assignee-override`. |

Manual verification is also possible on the operator's laptop:

```bash
# With override:
jq '.repos[0].assignee_override = "hydra-bot-example"' state/repos.json > /tmp/repos.json
scripts/validate-state.sh /tmp/repos.json --schema state/schemas/repos.schema.json
# → exit 0

# With invalid override:
jq '.repos[0].assignee_override = "@me"' state/repos.json > /tmp/repos.json
scripts/validate-state.sh /tmp/repos.json --schema state/schemas/repos.schema.json
# → exit non-zero, clear message
```

## Risks / rollback

**Risk 1 — operator misconfigures the bot account and Commander polls a user with no access.** Outcome: `gh issue list --assignee <bot>` returns an empty list; Commander quietly picks up zero tickets. This is the same symptom as "no tickets assigned" today — it's benign. The `./hydra doctor` script can grow a future check that `gh issue list --assignee <override>` doesn't 404; tracked as a small future ticket, not a blocker.

**Risk 2 — a phase-2 follow-up ticket assumes `assignee_override` implies bot-token storage.** Mitigated by the explicit "non-goals" section in this spec. Future tickets MUST use this spec as a reference when layering bot-token logic on top — the override field is the polling identity only.

**Risk 3 — schema pattern over-restricts valid GitHub logins.** GitHub logins are `^[A-Za-z0-9-]+$` with max length 39 and no leading/trailing dash, plus `[bot]` for apps. The spec's pattern covers the common case. Worst case: an operator with a rare login shape gets rejected by the schema and has to lift the pattern locally. The pattern is deliberately loose (no length bound) — we err on the side of accepting slightly more than GitHub does, because the real constraint is enforced by `gh` at poll time anyway.

**Rollback:**
- The change is additive at the schema level — remove the `assignee_override` field from any repo entry and you're back to `@me` behavior with no code change.
- The CLI flag is opt-in — absence is the existing behavior.
- The CLAUDE.md line is a documentation clause; reverting is a one-line edit.
- The self-test case is independent; it can be removed with no impact on other cases.

No migration path needed. Safe to revert without data loss.

## Out of scope (confirmed)

- Creating the bot GitHub account — operator's step.
- GitHub App registration — phase 2 / future.
- Bot-token storage, expiry detection, auto-pause on token death — separate ticket.
- Bot-authored PRs / comments / labels — separate ticket (needs the bot-token layer first).
- Multi-bot / team-mode — phase 2.
- Linear analogue (`assignee_override` for Linear pickup) — separate ticket; Linear has its own assignee model.
