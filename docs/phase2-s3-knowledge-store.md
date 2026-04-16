# Phase 2 — Knowledge Store on S3

**Status:** planned, not implemented. Phase 1 uses local disk.

## The problem

Phase 1 keeps all of the commander's learned knowledge on the operator's Mac:

```
$COMMANDER_ROOT/
├── memory/learnings-<repo>.md   ← per-repo gotchas, citations, escalation answers
├── memory/archive/              ← compacted older entries
├── state/memory-citations.json  ← what's earned its keep
├── state/active.json            ← in-flight workers
└── logs/<ticket>.json           ← per-ticket audit
```

This breaks as soon as:
- The commander itself moves to a cloud VM (Phase 2 end state)
- Multiple operators want to share learnings across their commanders
- The operator's laptop dies

## The fix: mount `memory/` and `state/` from S3

AWS ships **[S3 Files](https://aws.amazon.com/blogs/aws/launching-s3-files-making-s3-buckets-accessible-as-file-systems/)** — S3 buckets exposed as a POSIX-ish filesystem. The commander doesn't need to know it's hitting S3; it just writes to `memory/learnings-CLI.md` and the file lands in a bucket.

**Proposed layout:**

```
s3://my-commander-knowledge/
├── $COMMANDER_INSTANCE_ID/        ← isolation per commander (dev, staging, prod)
│   ├── memory/
│   │   ├── learnings-*.md
│   │   └── archive/
│   └── state/
│       ├── active.json            ← runtime; consider moving to DynamoDB instead
│       ├── memory-citations.json
│       └── repos.json
└── shared/                        ← cross-instance learnings (FAQ, lifecycle rules)
    ├── escalation-faq.md
    ├── memory-lifecycle.md
    └── tier-edge-cases.md
```

**What lives where:**

| File | Phase 1 | Phase 2 | Why |
|---|---|---|---|
| `memory/escalation-faq.md` | local | `shared/` on S3 | Cross-operator wisdom; everyone benefits |
| `memory/memory-lifecycle.md` | local | `shared/` on S3 | Framework-level rules |
| `memory/learnings-<repo>.md` | local | `<instance>/memory/` on S3 | Operator-specific; sensitive |
| `memory/archive/` | local | `<instance>/memory/` on S3 | Operator-specific |
| `state/repos.json` | local | `<instance>/state/` on S3 | Operator-specific config |
| `state/memory-citations.json` | local | `<instance>/state/` on S3 | Operator-specific |
| `state/active.json` | local | **DynamoDB**, not S3 | High-churn; S3 eventual consistency hurts lock semantics |
| `state/budget-used.json` | local | **DynamoDB**, not S3 | Same reason |
| `logs/<ticket>.json` | local | `<instance>/logs/` on S3 | Append-only, low churn, fine for S3 |
| `CLAUDE.md` / `policy.md` / `budget.json` / `.claude/agents/*` | local (git) | still local (git) | Framework code, not data |

## Why S3 Files rather than rolling our own sync

- **Zero code change** — the commander writes to `memory/learnings-X.md`, same as today. The mount layer handles persistence.
- **POSIX semantics** — `fopen`, `fstat`, `ls`, `grep` all work. No rewriting workers to use an API.
- **Concurrent access** — multiple commander instances can read the shared/ namespace simultaneously. Writes to an instance's own directory are isolated.
- **Backup + versioning** — S3 versioning enabled on the bucket → every change recoverable.
- **Cheap** — memory dir is tiny (<10MB likely); S3 costs cents/month.

## What S3 is bad at (reasons for DynamoDB on hot state)

- **High-churn writes with lock semantics** — `state/active.json` is updated on every worker spawn/complete; S3 eventual consistency + no conditional-put-with-lease makes this race-prone
- **Fast reads of small records** — DynamoDB GetItem is single-digit ms; S3 GetObject is tens of ms

So the split:
- Slow, append-ish, large-ish, read-mostly → S3 Files mount
- Fast, small, write-heavy, lock-ish → DynamoDB (or Redis / any k/v with compare-and-swap)

## Migration plan (when Phase 2 arrives)

1. Provision S3 bucket + DynamoDB tables (`commander-active`, `commander-budget`)
2. Mount the bucket at `$COMMANDER_ROOT/memory/` and `$COMMANDER_ROOT/logs/` via S3 Files
3. Add a thin abstraction in CLAUDE.md: `state/active.json` reads/writes → DynamoDB wrapper. Worker subagent prompts don't change (they don't touch active.json directly).
4. First commander instance writes initial `shared/` files
5. Flip over; keep local fallback path for air-gapped operation

## Open questions (decide at Phase 2 start)

- **Per-operator or per-org bucket?** Operator seems right — learnings are private. Cross-operator sharing can be opt-in via pointing multiple instances at the same `shared/` prefix.
- **Encryption at rest?** Yes — SSE-KMS with operator-owned key. Memory files may contain sensitive snippets (ticket bodies can reference internal systems).
- **Retention?** Logs > 90 days → Glacier. Memory → indefinite. Archive → indefinite (cheap).
- **Auth?** The commander VM gets IAM role-based access. No keys in `.env`.
