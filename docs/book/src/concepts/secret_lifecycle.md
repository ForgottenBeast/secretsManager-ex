# Secret Lifecycle

Every secret managed by RotatingSecrets runs as an independent `RotatingSecrets.Registry` GenServer. That process moves through a five-state machine that governs when values are loaded, refreshed, and expired.

## The five states

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

| State | What it means | Effect on callers |
|---|---|---|
| `Loading` | Initial load is in progress; no value is available yet | `current/1` returns `{:error, :loading}` |
| `Valid` | Secret is loaded and within its TTL; all reads succeed | `current/1` returns `{:ok, secret}` |
| `Refreshing` | TTL threshold has been crossed; a background reload is running | `current/1` still returns the previous value |
| `Expiring` | A refresh has failed and the TTL is dangerously close to elapsing | `current/1` still returns the last-known-good value |
| `Expired` | TTL has elapsed without a successful refresh | `current/1` returns `{:error, :expired}` |

The `Expired` state is terminal for a single run of the state machine, but the supervisor restarts the process, which re-enters `Loading`.

## TTL-driven refresh

When a source returns `:ttl_seconds` in its metadata, the Registry schedules a refresh at **two-thirds of the TTL**. This provides a buffer for the refresh to complete before the secret expires.

For a secret with a 300-second TTL:

```elixir
# Source returns:
{:ok, value, %{ttl_seconds: 300, version: 7}, state}

# Registry schedules refresh at:
trunc(300 * 1000 * 2 / 3) = 200_000 ms after the successful load
```

If no `:ttl_seconds` is present in meta, the Registry falls back to the `:fallback_interval_ms` option (default 60 000 ms).

## Push-driven refresh

Sources that implement `subscribe_changes/1` can signal that the external value has changed without waiting for a timer. `Source.File` uses this pattern: it watches the parent directory with inotify (Linux) or FSEvents (macOS) and triggers an immediate reload when the file changes.

Push-driven and TTL-driven refresh coexist. Whichever fires first triggers a reload. The timer is reset after each successful load.

## Load failure and exponential backoff

When `load/1` returns `{:error, reason, state}`, the Registry schedules a retry using exponential backoff:

- First retry: `:min_backoff_ms` (default 1 000 ms)
- Each retry: doubles the delay, up to `:max_backoff_ms` (default 60 000 ms)
- After a successful load: backoff counter resets

During retries the Registry continues to serve the last-known-good value, provided the TTL has not elapsed. Callers are unaffected unless the secret actually expires.

Errors classified as permanent (`:enoent`, `:eacces`, `:not_found`, `:forbidden`, `{:invalid_option, _}`) cause the process to stop immediately rather than retry. These indicate configuration errors that cannot resolve themselves.

## Version monotonicity

The `:version` field in source metadata tracks rotation order. The Registry enforces a monotone invariant: the version returned by successive loads must never decrease. This property is formally verified in the TLA+ specification:

```
[][version' >= version]_version
```

Sources that use integer versions (Vault KV v2, for example) satisfy this automatically. Sources with no ordering concept should return `nil` for `:version`.

Consumers can read the current version from the secret metadata:

```elixir
{:ok, secret} = RotatingSecrets.current(:db_password)
version = secret |> RotatingSecrets.Secret.meta() |> Map.get(:version)
```

Version is also included in rotation notification messages (see [Reacting to Rotations](../cookbook/subscriptions.md)), which allows consumers to skip redundant reconnects when they have already processed a given version.

## API reference

See [`RotatingSecrets.Registry`](../../api/rotating_secrets/RotatingSecrets.Registry.html) for the full process interface.
