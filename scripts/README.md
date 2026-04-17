# Commander helper scripts

These are **helper scripts invoked by Commander during memory lifecycle operations** (see `memory/memory-lifecycle.md`). They are not standalone tools — Commander calls them from its operating loop and merges / interprets their output.

## Overview

| Script | Who calls it | Purpose |
|---|---|---|
| `parse-citations.sh` | Commander, after every worker report comes back | Extract `MEMORY_CITED:` markers from a worker report and emit a JSON delta that Commander merges into `state/memory-citations.json` |
| `validate-learning-entry.sh` | Commander, before appending/committing a learnings file; pre-commit hook material | Sanity-check a `learnings-<repo>.md` file against the schema (frontmatter keys, section headings, line length, date format) |
| `validate-citations.sh` | Commander, during `compact memory` / `promote learnings` hygiene passes | Walk `state/memory-citations.json`, check every citation quote still exists in its referenced file. Flags stale references that need cleanup. |

Each script is self-contained bash with a `usage()` block. `jq` is the only non-standard dependency — it's already required by Hydra at install time (`INSTALL.md`).

## Memory directory resolution

Each script accepts an optional `--memory-dir <path>` argument. When absent, the scripts resolve the memory directory in this order:

1. `$HYDRA_EXTERNAL_MEMORY_DIR` (from `.hydra.env`, set by `setup.sh` in the future external-memory-split refactor — see `docs/specs/2026-04-16-external-memory-split.md`)
2. `./memory/` (current behaviour — framework + operational memory both live in-repo)

This lets the scripts work today with in-repo memory AND keep working after the external memory split lands without changes.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / validation passed |
| 1 | Validation failure (clear error messages on stderr) |
| 2 | Usage error (bad flags / missing input) |

## How Commander wires them in

Rough shape of the citation-merge flow Commander runs after each worker report:

```bash
delta=$(scripts/parse-citations.sh < "logs/$ticket_num.report.txt")
jq -s '.[0] as $cur | .[1] as $delta | <merge-logic>' \
   state/memory-citations.json <(printf '%s' "$delta") > state/memory-citations.json.new
mv state/memory-citations.json.new state/memory-citations.json
```

Commander owns the merge semantics (incrementing counts, deduping tickets, flipping `promotion_threshold_reached`). The scripts stay stateless and composable.

## Adding a new script

Follow the existing convention:

- `#!/usr/bin/env bash` + `set -euo pipefail`
- A `usage()` function printed on `-h` / `--help` / bad args
- Accept `--memory-dir <path>` if the script touches memory files
- Exit codes per table above
- `bash -n` clean
- A matching fixture under `self-test/fixtures/memory-validator/`
- A case in `self-test/golden-cases.example.json`
