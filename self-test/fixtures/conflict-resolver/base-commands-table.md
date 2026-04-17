# Commander — commands table fixture (base)

This is the starting state of a commands table in `CLAUDE.md` BEFORE either PR #A or PR #B
has been merged. Both PRs were opened off this base. It's the "common ancestor" for the
three-way merge that `worker-conflict-resolver` performs.

## Commands you understand

| the operator says | You do |
|---|---|
| `status` / `what's running` | Read `state/active.json` + recent logs, summarize. |
| `pick up N` | Main spawn loop, up to N `worker-implementation` agents |
| `pick up #42` | Spawn `worker-implementation` on that specific ticket |
| `review PR #501` | Spawn `worker-review` on that PR |
| `test discover <repo>` | Spawn `worker-test-discovery` on that repo |
