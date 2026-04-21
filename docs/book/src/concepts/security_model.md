# Security Model

RotatingSecrets is designed to prevent accidental secret exposure at multiple layers. This page explains each protection and the practices your application should follow to get the full benefit.

## The `RotatingSecrets.Secret` opaque type

`RotatingSecrets.Secret` is an opaque struct. Its internal fields are not part of the public API and you should not pattern-match on them directly. The struct implements several Elixir and Phoenix protocols to make accidental exposure a hard error rather than a silent leak.

### Inspect is redacted

```elixir
{:ok, secret} = RotatingSecrets.current(:db_password)
IO.inspect(secret)
# => #RotatingSecrets.Secret<db_password:redacted>
```

The raw value never appears in Logger output, IEx sessions, or crash dumps that call `inspect/1`.

### String interpolation raises

```elixir
secret = RotatingSecrets.current!(:api_key)
"Authorization: Bearer #{secret}"   # raises ArgumentError
```

`String.Chars` is implemented to raise `ArgumentError`. String interpolation fails at runtime rather than silently embedding the value in a log line or error response.

### JSON encoding raises

```elixir
Jason.encode!(%{token: secret})   # raises ArgumentError
```

`Jason.Encoder` is implemented to raise. Secrets cannot be serialised into API responses or event payloads by accident.

### Phoenix URL helpers raise

```elixir
Routes.some_path(conn, :show, secret)   # raises ArgumentError
```

`Phoenix.Param` raises `ArgumentError`, preventing a secret from ending up in a URL.

## The `expose/1` contract

`Secret.expose/1` is the only way to obtain the raw binary value:

```elixir
password = RotatingSecrets.Secret.expose(secret)
```

Follow these rules at every call site:

1. Call `expose/1` only at the point of use — the function that needs the raw value.
2. Pass the exposed binary directly to that function. Do not assign it to a module attribute, a process dictionary key, or a variable that lives longer than the single call.
3. Do not log the return value of `expose/1`.

`with_secret/2` makes this pattern easy to enforce:

```elixir
{:ok, conn} = RotatingSecrets.with_secret(:db_password, fn secret ->
  MyApp.DB.connect(RotatingSecrets.Secret.expose(secret))
end)
```

The struct is not retained outside the callback, and the exposed binary is only in scope inside `MyApp.DB.connect/1`.

## Registry process sensitivity

Each `RotatingSecrets.Registry` GenServer calls `Process.flag(:sensitive, true)` at startup. This flag instructs the BEAM to exclude the process from crash dumps and `:erlang.process_info/2` output. The in-memory secret value cannot be read by other processes via the standard introspection API.

## Rotation notifications never carry the value

Subscription messages contain only the secret name and version:

```elixir
{:rotating_secret_rotated, sub_ref, :db_password, version}
```

Callers must call `current/1` to read the new value. The secret binary is never transmitted over a message-passing channel. A subscriber process that crashes before calling `current/1` has never had access to the material.

## Telemetry events never carry the value

All internal emit helpers in `RotatingSecrets.Telemetry` accept only non-secret arguments. The raw binary returned by `source.load/1` is never a parameter to any emit function. This is enforced at the call site, not via a runtime assertion.

## File permissions

`Source.File` checks the permission bits of the secret file at `init/1`. If the file is group- or world-readable (mode bits `0o077` are non-zero), it emits a Logger warning:

```
[warning] RotatingSecrets.Source.File: secret file is group- or world-readable
```

The process does not stop — the warning is advisory. Set the correct permissions before deploying:

```bash
chmod 600 /run/secrets/db_password
chown app:app /run/secrets/db_password
```

For systemd-managed credentials (`LoadCredential=` or `LoadCredentialEncrypted=`), the runtime directory `/run/credentials/<unit>/` is already mode `0700` and owned by the service user. No extra `chmod` is needed for those files.

## `Source.Env` is not for production

`Source.Env` reads secrets from environment variables. Environment variables are process-global, visible in `/proc/<pid>/environ` on Linux, and are not rotated at the OS level the way files or Vault leases are. The source emits a Logger `:warning` and a `[:rotating_secrets, :dev_source_in_use]` telemetry event every time it initialises. Use `Source.File` or a Vault-backed source for production deployments.

## Secret values are never transmitted between nodes

By default, each node maintains its own secret process and loads directly from the source. When using Horde for distributed process registration, the `Registry` child spec contains no closures, PIDs, or raw values. After migration the secret is re-loaded from the source on the receiving node; it is never carried in the child spec.

`RotatingSecrets.cluster_status/1` returns only version and metadata — no secret values — when querying all nodes.

## Summary

| Risk | Mitigation |
|---|---|
| Secret logged via `inspect` | `Inspect` protocol renders `#RotatingSecrets.Secret<name:redacted>` |
| Secret leaked via string interpolation | `String.Chars` raises `ArgumentError` |
| Secret serialised to JSON | `Jason.Encoder` raises `ArgumentError` |
| Secret in URL | `Phoenix.Param` raises `ArgumentError` |
| Secret visible in crash dump | `Process.flag(:sensitive, true)` on Registry GenServer |
| Secret in telemetry event | Telemetry emit functions never accept raw secret material |
| Secret in rotation message | Notification messages carry only name and version |
| Env var source in production | Logger warning + `dev_source_in_use` telemetry event |
| World-readable secret file | Logger warning on `Source.File` init |

## API reference

See [`RotatingSecrets.Secret`](../../api/rotating_secrets/RotatingSecrets.Secret.html) for the full type documentation.
