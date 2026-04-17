# ensure-repo-cloned fixture

Consumed by the `ensure-repo-cloned-idempotent` self-test case (kind: script)
in `self-test/golden-cases.example.json`.

The case builds its own `repos.json` in a tmpdir (so the target `cloud_local_path`
can be a tmpdir too — the repo is cloned and discarded within the test). This
directory is a placeholder — everything the test needs is generated inline.

See `docs/specs/2026-04-17-cloud-repo-clone.md` for the ticket-level spec.
