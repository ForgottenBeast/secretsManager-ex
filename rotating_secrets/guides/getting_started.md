# Getting Started

RotatingSecrets is an Elixir secret lifecycle library. It manages loading, caching, and rotating secret values from pluggable sources. All reads are served from memory; no I/O occurs on the hot path.

## Installation

Add `rotating_secrets` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:rotating_secrets, "~> 0.1"},
    {:telemetry, "~> 1.0"}
  ]
end
```

For file-based secrets, also add the optional `file_system` dependency:

```elixir
{:file_system, "~> 1.1"}
```

Run `mix deps.get` to fetch dependencies.

## Add the Supervisor to Your Application

`RotatingSecrets.Supervisor` manages the process registry and dynamic supervisor for all secret processes. Add it to your application's supervision tree before any processes that need secrets:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      RotatingSecrets.Supervisor,
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Register a Secret

Call `RotatingSecrets.register/2` with a name atom and options. The `:source` option is required and must be a module implementing the `RotatingSecrets.Source` behaviour.

### Development: environment variable source

```elixir
{:ok, _pid} = RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.Env,
  source_opts: [var_name: "DB_PASSWORD"]
)
```

`Source.Env` emits a warning on init — it is for development and testing only.

### Production: file source

```elixir
{:ok, _pid} = RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.File,
  source_opts: [path: "/run/secrets/db_password"]
)
```

Registration is synchronous: the secret is loaded before `register/2` returns. If the source fails to load on the first attempt, `register/2` returns `{:error, reason}`.

## Read a Secret

Use `RotatingSecrets.current/1` to retrieve the current `RotatingSecrets.Secret` struct:

```elixir
{:ok, secret} = RotatingSecrets.current(:db_password)
password = RotatingSecrets.Secret.expose(secret)
```

`Secret.expose/1` is the only way to obtain the raw binary value. The struct itself is opaque: `inspect`, string interpolation, and JSON encoding all redact the value. See the [Security guide](security.md) for details.

### Bang variant

```elixir
secret = RotatingSecrets.current!(:db_password)
password = RotatingSecrets.Secret.expose(secret)
```

`current!/1` raises `RuntimeError` if the secret is unavailable (still loading, or expired with no fallback).

### Scoped access with `with_secret/2`

```elixir
{:ok, result} = RotatingSecrets.with_secret(:db_password, fn secret ->
  MyApp.DB.connect(RotatingSecrets.Secret.expose(secret))
end)
```

`with_secret/2` passes the `Secret` struct to the function and returns `{:ok, result}`. The struct is not retained outside the callback.

## Secret Metadata

Each secret carries a `meta` map from the source. Inspect it with `RotatingSecrets.Secret.meta/1`:

```elixir
meta = RotatingSecrets.Secret.meta(secret)
# => %{ttl_seconds: 300, version: 42, issued_at: ~U[2024-01-01 12:00:00Z]}
```

Available keys depend on the source. `:ttl_seconds` and `:version` are the most common.

## Remove a Secret

```elixir
:ok = RotatingSecrets.deregister(:db_password)
```

This terminates the secret's GenServer process. After deregistration, `current/1` will exit because no process is registered under that name.

## Configuration Options

The following options can be passed to `register/2` in addition to `:source` and `:source_opts`:

| Option | Default | Description |
|---|---|---|
| `:fallback_interval_ms` | `60_000` | Refresh interval when the source returns no `:ttl_seconds` in meta |
| `:min_backoff_ms` | `1_000` | Initial retry delay after a load failure |
| `:max_backoff_ms` | `60_000` | Maximum retry delay (exponential cap) |
| `:registry_via` | local registry | Custom registration term for distributed deployments (e.g. Horde) |

Example with custom backoff:

```elixir
RotatingSecrets.register(:api_key,
  source: MyApp.Source.Vault,
  source_opts: [path: "secret/api_key"],
  min_backoff_ms: 500,
  max_backoff_ms: 30_000,
  fallback_interval_ms: 120_000
)
```

## Next Steps

- [Rotation](rotation.md) — how TTL-driven and push-driven rotation works
- [Security](security.md) — secret leak prevention and file permission guidance
- [Writing a Source](writing_a_source.md) — implement a custom source module
- [Testing](testing.md) — how to test code that uses RotatingSecrets
