# learnings-sample-bad (fixture — invalid)

This fixture intentionally violates the learnings schema. It has NO frontmatter block,
which `scripts/validate-learning-entry.sh` must reject.

## Conventions

- this file is malformed on purpose; the validator should complain.
