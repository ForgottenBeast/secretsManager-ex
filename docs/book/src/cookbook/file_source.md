# File Source

`RotatingSecrets.Source.File` reads secret values from files on disk. It is the recommended source for production deployments where secrets are delivered by systemd credentials, Vault Agent, or an external rotation agent.

## Basic usage

```elixir
RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.File,
  source_opts: [path: "/run/secrets/db_password"]
)
```

The file must exist at registration time. If it is missing, `init/1` returns `{:error, :enoent}` and the Registry process stops permanently.

## systemd credentials

systemd's `LoadCredential=` and `LoadCredentialEncrypted=` directives write credential files to `/run/credentials/<unit>/<name>` at service startup. The directory is mode `0700` and owned by the service user, so no extra `chmod` is needed.

In your unit file:

```ini
[Service]
LoadCredential=db_password:/etc/myapp/db_password.enc
```

In your application:

```elixir
RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.File,
  source_opts: [path: "/run/credentials/myapp.service/db_password"]
)
```

If the credential is re-deployed (systemd restarts the unit with a new credential), the secret process will reload it automatically when the file changes.

## Atomic rename detection

Many secrets-management tools — Vault Agent, external rotation scripts, and systemd-creds itself — write new values using an atomic `rename(2)` (write to a temp file, then `mv` it into place). A watch on the file itself would miss these events.

`Source.File` watches the **parent directory**, not the file. On Linux it uses `inotify` via the `file_system` library; on macOS it uses FSEvents. When a `moved_to` or `create` event arrives for the target filename, `handle_change_notification/2` returns `{:changed, state}` and the Registry immediately calls `load/1`.

This means the following rotation script works without any polling lag:

```bash
# Write the new password atomically
echo -n "new-password-value" > /run/secrets/db_password.tmp
mv /run/secrets/db_password.tmp /run/secrets/db_password
```

## JSON secrets with the `:key` option

If the file contains JSON, use the `:key` option to extract a single field:

```elixir
RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.File,
  source_opts: [
    path: "/run/secrets/database.json",
    key: "password"
  ]
)
```

Given a file with content:

```json
{"username": "app", "password": "s3cr3t", "host": "db.internal"}
```

`Secret.expose/1` returns `"s3cr3t"`. Only the extracted field is stored in the Registry; the rest of the JSON is not retained.

If `:key` is not set, the entire file content is stored as the secret value.

## Example: database password rotated by an external agent

The following shows a complete setup where an external rotation agent (for example, a Kubernetes operator writing to a mounted secret volume) atomically replaces the password file.

```elixir
# In application.ex, after RotatingSecrets.Supervisor has started:
{:ok, _} = RotatingSecrets.register(:pg_password,
  source: RotatingSecrets.Source.File,
  source_opts: [path: "/run/secrets/pg_password"],
  fallback_interval_ms: 30_000   # poll as a backstop if the inotify event is missed
)

# In the module that opens connections:
defmodule MyApp.DB do
  def connect do
    {:ok, secret} = RotatingSecrets.current(:pg_password)
    Postgrex.start_link(
      hostname: "db.internal",
      username: "app",
      password: RotatingSecrets.Secret.expose(secret),
      database: "myapp"
    )
  end
end
```

When the external agent writes a new file, the Registry is notified within milliseconds. On the next `connect/0` call, `current/1` returns the updated value.

## Permissions checklist

Before deploying, verify the following:

- The file mode is `600` (readable only by owner): `chmod 600 /run/secrets/db_password`
- The file is owned by the user your application runs as: `chown app:app /run/secrets/db_password`
- The parent directory is not world-traversable if it contains only secret files: `chmod 700 /run/secrets`
- For systemd credentials: the `/run/credentials/<unit>/` directory is managed automatically; no manual permissions are needed.

`Source.File` logs a `:warning` if the file is group- or world-readable. The process continues to run — the warning is advisory.
