# secretsManager-ex — Claude Context

## Project structure

Multi-package Elixir monorepo. Each package is a standalone Mix project at the repo root:
- `rotating_secrets/` — core library + `RotatingSecrets.Source` behaviour
- `rotating_secrets_vault/` — Vault/OpenBao source backend
- `rotating_secrets_scaleway/` — Scaleway Secret Manager source backend
- `rotating_secrets_sops/` — SOPS source backend
- `rotating_secrets_testing/` — shared test helpers

New source packages use `{:rotating_secrets, path: "../rotating_secrets"}` as a path dep.

## Quality gate (run in each package directory)

`mix quality.check` — format + credo --strict + dialyzer (all must pass before merging)

## Credo --strict gotchas

- **SinglePipe vs NestedFunctionCalls conflict**: `a |> f()` and `f(a)` both trigger when `a` is a function call. Resolution: always use an intermediate variable.
- **`cond do` with one real condition + `true ->`**: use `if/else` instead — credo rejects single-condition cond.
- **StrictModuleLayout**: `use` → `import` → `alias` (strict order, module attributes after).
- **Nesting depth**: max 3 levels; split `decode_payload`-style functions into two-clause functions if exceeded.

## RotatingSecrets.Source behaviour

Callbacks: `init/1`, `load/1`, `subscribe_changes/1`, `handle_change_notification/2`, `terminate/1`.
`load/1` returns `{:ok, material, meta, state}` | `{:error, reason, state}`.
`meta` must include `:version`, `:content_hash` (SHA-256 hex of decoded material), `:ttl_seconds`.

## Testing patterns

- Req HTTP stubs: `req_options: [plug: {Req.Test, stub_name}]` in source opts, `Req.Test.stub/2` in tests.
- Integration tests gated by env vars: `@moduletag :scw_integration` excluded unless `SCW_INTEGRATION=1`.
- StreamData: beginless ranges (`integer(..0)`) are not supported — use `one_of([constant(0), map(positive_integer(), &(-&1))])`.

## CI

Two jobs: `openbao-integration` and `openbao-database-integration`. Both must pass to merge.
