# Sources

A source is a module that implements the `RotatingSecrets.Source` behaviour. It encapsulates all I/O for a single secret: how to initialise a connection, how to load the current value, and optionally how to receive push notifications when the value changes.

The Registry owns the secret lifecycle. The source handles only the I/O. This separation means you can swap sources without changing any other code.

## Required callbacks

### `init/1`

```elixir
@callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
```

Called once when the secret process starts. Validate options, build HTTP clients or open file handles, and return the initial source state. Do not perform blocking I/O in `init/1` — it runs inside the GenServer `init/1` callback and must return quickly.

Return `{:ok, state}` on success. Return `{:error, reason}` to abort startup with a permanent failure. The reason must not contain raw secret values.

### `load/1`

```elixir
@callback load(state()) ::
  {:ok, material(), meta(), state()} | {:error, term(), state()}
```

Called on initial load and on each scheduled or push-triggered refresh. Fetch the current secret material from the external system.

- `material` — the raw secret value as a binary.
- `meta` — a map with optional keys `:version`, `:ttl_seconds`, `:issued_at`, `:content_hash`, and any source-specific keys. The Registry uses `:ttl_seconds` to schedule the next refresh and `:version` for monotonicity enforcement.
- Return the updated `state` in both the success and error tuples.

## Optional callbacks

### `subscribe_changes/1`

```elixir
@callback subscribe_changes(state()) ::
  {:ok, ref :: term(), state()} | :not_supported
```

Register for push notifications from the external system. Return `{:ok, ref, new_state}` where `ref` identifies messages the source will send to the Registry PID. Return `:not_supported` to rely on TTL/interval polling only.

When the Registry receives a message matching `ref`, it calls `handle_change_notification/2`.

### `handle_change_notification/2`

```elixir
@callback handle_change_notification(msg :: term(), state()) ::
  {:changed, state()} | :ignored | {:error, term()}
```

Called when the Registry receives a message via `handle_info/2`. Return `{:changed, new_state}` to trigger an immediate `load/1`. Return `:ignored` for unrelated messages. Return `{:error, reason}` to log a warning and continue without reloading.

### `terminate/1`

```elixir
@callback terminate(state()) :: :ok
```

Called when the Registry GenServer is terminating. Use it to close file handles, cancel subscriptions, or stop watcher processes.

## Built-in sources

| Source | Use case | Push-driven? | Package |
|---|---|---|---|
| `Source.File` | Files on disk, systemd credentials | Yes (inotify / FSEvents) | `rotating_secrets` |
| `Source.Env` | Development and testing only | No | `rotating_secrets` |
| `Source.Memory` | In-process integration testing | Yes | `rotating_secrets` |
| `Source.Vault.KvV2` | OpenBao / Vault KV secrets engine v2 | No (TTL polling) | `rotating_secrets_vault` |
| `Source.Controllable` | Test suite rotation control | Yes | `rotating_secrets_testing` |

`Source.Env` emits a Logger warning and a `[:rotating_secrets, :dev_source_in_use]` telemetry event at initialisation. Do not use it in production.

## The meta map

The map returned as the third element of `{:ok, material, meta, state}` drives scheduling and version tracking:

| Key | Type | Effect |
|---|---|---|
| `:version` | `term() \| nil` | Version counter; must be monotonically non-decreasing. Use `nil` for sources with no ordering concept. |
| `:ttl_seconds` | `pos_integer() \| nil` | If set, the Registry refreshes at 2/3 of this value. If `nil`, falls back to `:fallback_interval_ms`. |
| `:issued_at` | `DateTime.t()` | When the material was issued; informational only. |
| `:content_hash` | `binary()` | Hex SHA-256 of the material; useful for change detection when `:version` is `nil`. |

All additional keys are passed through to the `Secret.meta/1` map unchanged.

## Error classification

| Reason | Classification | Consequence |
|---|---|---|
| `:enoent` | Permanent | Registry process stops |
| `:eacces` | Permanent | Registry process stops |
| `:not_found` | Permanent | Registry process stops |
| `:forbidden` | Permanent | Registry process stops |
| `{:invalid_option, _}` | Permanent | Registry process stops |
| Any other term | Transient | Exponential backoff retry |

Return permanent error atoms only when the configuration is irrecoverably wrong. Return transient errors for network timeouts, connection failures, and temporary unavailability.

## Next step

See [Writing a Custom Source](../cookbook/custom_source.md) to implement a source for your own backend.
