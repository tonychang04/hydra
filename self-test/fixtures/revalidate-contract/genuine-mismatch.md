# Validation contract — #999 (fixture: GENUINE mismatch — no-regression guard)

> The load-bearing safety check: hardening the parser must NOT make it go quiet
> on REAL failures. This row's Command is fully self-contained (no placeholder,
> no unbound var), is marked PASS with a structured `exit 0` Expected, but the
> command genuinely exits 4. The gate must STILL catch this as a MISMATCH and
> exit 1 — a real lie about evidence, not an authoring error.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | claimed PASS but the command really exits nonzero | `sh -c 'exit 4'` | exit 0 | PASS | claimed it returns 0 |
