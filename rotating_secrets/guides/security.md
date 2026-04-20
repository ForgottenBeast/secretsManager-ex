# Security

RotatingSecrets is designed to prevent accidental secret exposure at multiple layers. This guide describes the protections built into the library and the practices you should follow when deploying it.

## The Secret Struct is Opaque

`RotatingSecrets.Secret` prevents secret values from leaking through common Elixir and Phoenix paths.

### Inspect is redacted

```elixir
{:ok, secret} = RotatingSecrets.current(:db_password)
IO.inspect(secret)
# => #RotatingSecrets.Secret<db_password:redacted>
```

The raw value never appears in Logger output, IEx sessions, or crash dumps that use `inspect/1`.

### String interpolation raises

```elixir
secret = RotatingSecrets.current!(:api_key)
"key=#{secret}"   # raises ArgumentError
```

`String.Chars` is implemented to raise `ArgumentError`, so string interpolation fails at runtime rather than silently including the value in a log message or error response.

### JSON encoding raises

```elixir
Jason.encode!(%{secret: secret})  # raises ArgumentError
```

The `Jason.Encoder` protocol is implemented to raise, so secrets cannot be serialised into API responses or event payloads by accident.

### Phoenix.Param raises

```elixir
Routes.some_path(conn, :show, secret)  # raises ArgumentError
```

`Phoenix.Param` raises `ArgumentError`, preventing a secret from ending up in a URL.

### Explicit exposure

To access the raw value you must call `expose/1` explicitly:

```elixir
password = RotatingSecrets.Secret.expose(secret)
```

Keep the scope of `expose/1` calls as narrow as possible. Pass the exposed value directly to the function that needs it; do not store it in a variable that lives longer than the call.

## Registry Process is Sensitive

The `RotatingSecrets.Registry` GenServer calls `Process.flag(:sensitive, true)` on startup. This flag tells the BEAM to exclude the process from crash dumps and `:erlang.process_info/2` output. The in-memory secret value cannot be read by other processes via the introspection API.

## Rotation Notifications Never Carry the Value

Subscription messages contain only the secret name and version:

```elixir
{:rotating_secret_rotated, sub_ref, :db_password, version}
```

Callers must call `current/1` explicitly to read the new value. This means the secret is never sent over a message-passing channel, and a process that subscribes but crashes before calling `current/1` never had access to the material.

## Telemetry Events Never Carry the Value

All telemetry helper functions in `RotatingSecrets.Telemetry` accept only non-secret arguments by design. The raw binary returned by `source.load/1` is never a parameter to any emit function. This enforces the invariant at the call site rather than via a runtime check.

## Source.Env is Not for Production

`RotatingSecrets.Source.Env` reads secrets from environment variables. It emits a `[:rotating_secrets, :dev_source_in_use]` telemetry event and a Logger warning at `:warning` level whenever it initialises:

```
[warning] RotatingSecrets.Source.Env: reading secret from environment variable — not recommended for production
```

Environment variables are process-global, visible in `/proc/<pid>/environ` on Linux, and are not rotated at the OS level in the same way as files or Vault leases. Use `Source.File` or a Vault-backed source for production.

## File Permissions

`RotatingSecrets.Source.File` checks the permission bits of the secret file on `init/1`. If the file is group- or world-readable (mode bits `0o077` are non-zero), it emits a Logger warning:

```
[warning] RotatingSecrets.Source.File: secret file is group- or world-readable
```

The process does not crash — the warning is advisory. Set the correct permissions before deploying:

```bash
chmod 600 /run/secrets/db_password
chown app:app /run/secrets/db_password
```

For systemd-managed credentials (`LoadCredential=`, `LoadCredentialEncrypted=`), the runtime directory `/run/credentials/<unit>/` is already mode `0700` and owned by the service user. No extra `chmod` is needed.

### Watching parent directories

`Source.File` in `:file_watch` mode watches the **parent directory**, not the file itself. This is necessary to detect atomic renames, which tools like Vault Agent and systemd-creds use to update secret files safely. The directory watch does not expose other files in the directory — `handle_change_notification/2` filters events by the target filename.

## Vault-Backed Sources

When using a Vault or OpenBao source (e.g. the `rotating_secrets_vault` companion package):

- Store the Vault token or AppRole credentials in a systemd credential or an IAM-attached role, not in an environment variable.
- Use the shortest TTL appropriate for your threat model. Shorter TTLs reduce the window for a leaked lease.
- Enable Vault audit logging and alert on unexpected `read` calls to your secret paths.

## Distributing Secrets Across Nodes

By default, each node maintains its own secret process and loads directly from the source. Secret values are never transmitted between nodes.

`RotatingSecrets.cluster_status/1` returns only version and metadata — no secret values — when querying all nodes.

When using Horde for distributed process registration, the `Registry` child spec contains no closures, PIDs, or refs and is safe to migrate. The secret value is re-loaded from the source after migration; it is never carried in the child spec.

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
