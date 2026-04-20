# Rotation

RotatingSecrets refreshes secret values automatically. This guide explains the refresh lifecycle, TTL configuration, version monotonicity, and the subscription API for reacting to rotations.

## The Lifecycle State Machine

Each secret process (`RotatingSecrets.Registry`) runs a five-state machine:

```
[Loading] --LoadSucceeded--> [Valid] <--ExpiringRefreshSucceeded--+
    |                          |  |                               |
    |                     StartRefresh  StartExpiring             |
 LoadFailed                    |  |                               |
    |                          v  v                               |
    |                    [Refreshing] [Expiring] -----------------+
    |                          |          |
    |                  RefreshSucceeded   Expire
    |                  RefreshFailed -->  |
    |                          +--> [Expiring]
    |                                     |
    |                                  Expire
    v                                     v
[Expired] <--------------------------[Expired]
    |
    +-Restart--> [Loading]
```

| State | Description |
|---|---|
| `Loading` | First load in progress; `current/1` returns `{:error, :loading}` |
| `Valid` | Secret is loaded and within TTL; all reads succeed |
| `Refreshing` | TTL is approaching; refresh is in progress; old value is still served |
| `Expiring` | Refresh failed or TTL nearly elapsed; stale value may still be served |
| `Expired` | TTL has elapsed; `current/1` returns `{:error, :expired}` |

The formal TLA+ specification and TLC verification results are in the [Specifications](specs/README.md) section.

## TTL-Driven Refresh

When a source returns `:ttl_seconds` in its metadata, the Registry schedules a refresh at **2/3 of the TTL**. This gives the refresh time to complete before the secret expires.

For a secret with a 300-second TTL, refresh is triggered at 200 seconds:

```elixir
# Source returns:
{:ok, value, %{ttl_seconds: 300, version: 7}, state}

# Registry schedules refresh at: trunc(300 * 1000 * 2 / 3) = 200_000 ms
```

When no `:ttl_seconds` is present in meta, the Registry falls back to the configured `:fallback_interval_ms` (default 60 seconds).

## Push-Driven Refresh

Sources may implement `subscribe_changes/1` to receive push notifications instead of relying solely on the timer. `RotatingSecrets.Source.File` uses this to watch the parent directory with `inotify`/`FSEvents`:

```elixir
# File source watches /run/secrets/ for moved_to and modified events
RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.File,
  source_opts: [path: "/run/secrets/db_password"]
)
```

When the file changes, `FileSystem` sends an event to the Registry, which calls `handle_change_notification/2` on the source. If the source returns `{:changed, new_state}`, the Registry immediately calls `load/1` and updates the cached value.

Push-driven and TTL-driven refresh coexist: whichever fires first triggers a reload.

## Exponential Backoff on Failure

If `load/1` returns `{:error, reason, state}`, the Registry schedules a retry using exponential backoff:

- First retry: `:min_backoff_ms` (default 1 000 ms)
- Each subsequent retry: doubles up to `:max_backoff_ms` (default 60 000 ms)
- Backoff resets to `:min_backoff_ms` after a successful load

The last-known-good value continues to be served during retries (unless the secret has expired). Callers see no interruption unless the TTL elapses before a retry succeeds.

Configure backoff per secret:

```elixir
RotatingSecrets.register(:api_key,
  source: MyApp.Source.Vault,
  source_opts: [path: "secret/api_key"],
  min_backoff_ms: 500,
  max_backoff_ms: 30_000
)
```

## Version Monotonicity

The `:version` field in the source metadata is used to track rotation order. The Registry enforces a monotone invariant: the version returned by a source must never decrease across rotations.

This property is formally verified in the TLA+ specification (`MonotoneVersions`):

```
[][version' >= version]_version
```

In practice, sources that increment an integer version (Vault KV v2 metadata, for example) satisfy this automatically. Sources with no ordering concept (KV v1, dynamic secrets) should return `nil` for `:version`.

Callers can read the current version from the metadata:

```elixir
{:ok, secret} = RotatingSecrets.current(:db_password)
version = secret |> RotatingSecrets.Secret.meta() |> Map.get(:version)
```

## Subscribing to Rotation Notifications

Register any process to receive a message whenever a secret rotates:

```elixir
{:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)
```

When the secret rotates, the subscriber receives:

```elixir
{:rotating_secret_rotated, sub_ref, :db_password, version}
```

The message carries the version but **never the secret value**. Call `current/1` explicitly to obtain the new value:

```elixir
receive do
  {:rotating_secret_rotated, ^sub_ref, :db_password, _version} ->
    {:ok, secret} = RotatingSecrets.current(:db_password)
    new_password = RotatingSecrets.Secret.expose(secret)
    MyApp.DB.rotate_connection(new_password)
end
```

Cancel a subscription with the `sub_ref` returned by `subscribe/1`:

```elixir
RotatingSecrets.unsubscribe(:db_password, sub_ref)
```

`unsubscribe/2` always returns `:ok`, including if the subscription has already been cleaned up.

### Automatic cleanup

If a subscriber process crashes or disconnects (including across nodes), the Registry detects it via `Process.monitor` and removes the subscription automatically. No manual cleanup is required in the crash case.

## Telemetry Events for Rotation

The library emits telemetry on every rotation:

| Event | When |
|---|---|
| `[:rotating_secrets, :rotation]` | A new value replaces the previous one |
| `[:rotating_secrets, :state_change]` | Any state transition (Loading→Valid, Valid→Refreshing, etc.) |
| `[:rotating_secrets, :source, :load, :start]` | `load/1` is about to be called |
| `[:rotating_secrets, :source, :load, :stop]` | `load/1` returned |

Attach the default handlers for development:

```elixir
RotatingSecrets.Telemetry.attach_default_handlers()
```

See `RotatingSecrets.Telemetry` for the full event schema and measurement/metadata fields.
