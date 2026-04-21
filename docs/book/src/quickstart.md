# Quickstart

This guide gets RotatingSecrets running in your application in about five minutes.

## 1. Add dependencies

Add `rotating_secrets` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:rotating_secrets, "~> 0.1"},
    {:telemetry, "~> 1.0"}
  ]
end
```

If you plan to use `Source.File` (the standard production source), also add the optional file-watching dependency:

```elixir
{:file_system, "~> 1.1"}
```

If you use Vault or OpenBao, add the vault companion:

```elixir
{:rotating_secrets_vault, "~> 0.1"}
```

Fetch dependencies:

```bash
mix deps.get
```

## 2. Add the supervisor to your application

`RotatingSecrets.Supervisor` manages the process registry and dynamic supervisor for all secret processes. Add it to your application's supervision tree **before** any processes that need secrets:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      RotatingSecrets.Supervisor,   # must come first
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

The supervisor uses a `:rest_for_one` strategy internally so the dynamic supervisor restarts if the process registry crashes.

## 3. Register a secret

Call `RotatingSecrets.register/2` with a name atom and source options. Registration is synchronous: the secret is loaded from the source before `register/2` returns. If the first load fails, `register/2` returns `{:error, reason}`.

### Production: file source

Use `Source.File` in production. Point it at a file written by systemd credentials, Vault Agent, or your secrets manager:

```elixir
{:ok, _pid} = RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.File,
  source_opts: [path: "/run/secrets/db_password"]
)
```

The file source watches the parent directory for atomic renames, so it picks up updates written by `mv` or `rename(2)` without any polling delay.

### Development: environment variable source

For local development, `Source.Env` reads from an environment variable. It emits a Logger warning — it is intentionally not for production:

```elixir
{:ok, _pid} = RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.Env,
  source_opts: [var_name: "DB_PASSWORD"]
)
```

### Handling registration in application startup

Register secrets once, typically in a startup module or in the application's `start/2` callback after the supervisor has started:

```elixir
def start(_type, _args) do
  children = [RotatingSecrets.Supervisor, MyApp.Repo, MyAppWeb.Endpoint]
  {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)

  case RotatingSecrets.register(:db_password,
         source: RotatingSecrets.Source.File,
         source_opts: [path: "/run/secrets/db_password"]) do
    {:ok, _} -> :ok
    {:error, reason} -> raise "Failed to load db_password secret: #{inspect(reason)}"
  end

  {:ok, sup}
end
```

## 4. Read a secret

Use `RotatingSecrets.current/1` to retrieve the current `RotatingSecrets.Secret` struct:

```elixir
{:ok, secret} = RotatingSecrets.current(:db_password)
password = RotatingSecrets.Secret.expose(secret)
```

`Secret.expose/1` is the only way to obtain the raw binary value. The struct itself is opaque: `inspect`, string interpolation, and JSON encoding all redact the value. See [Security Model](concepts/security_model.md) for why this matters.

There is also a bang variant that raises on error:

```elixir
secret = RotatingSecrets.current!(:db_password)
password = RotatingSecrets.Secret.expose(secret)
```

## 5. Use `with_secret/2`

`with_secret/2` combines `current/1` and `expose/1` into a scoped callback. The Secret struct is not retained outside the callback:

```elixir
{:ok, conn} = RotatingSecrets.with_secret(:db_password, fn secret ->
  MyApp.DB.connect(RotatingSecrets.Secret.expose(secret))
end)
```

This is the preferred pattern when the exposed value does not need to outlive a single function call.

## 6. Deregister a secret

When you no longer need a secret — for example, when a feature is disabled or in a test teardown — call `deregister/1`:

```elixir
:ok = RotatingSecrets.deregister(:db_password)
```

This terminates the secret's Registry GenServer. Subsequent calls to `current/1` will return an error because no process is registered under that name.

## What happens next

Once registered, RotatingSecrets manages the secret automatically:

- If the source returns `:ttl_seconds`, the Registry schedules a refresh at 2/3 of the TTL.
- If the file changes (for `Source.File`), the Registry reloads immediately.
- If a load fails, the Registry retries with exponential backoff while continuing to serve the last-known-good value.
- When the value changes, subscribers receive a `{:rotating_secret_rotated, ref, name, version}` message.

See [Secret Lifecycle](concepts/secret_lifecycle.md) for the full state machine, and [Reacting to Rotations](cookbook/subscriptions.md) for the subscription API.
