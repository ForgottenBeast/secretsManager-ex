# Telemetry

RotatingSecrets emits telemetry events for every significant operation: source loads, state transitions, rotations, subscriber changes, and degraded states. All events live under the `[:rotating_secrets]` namespace.

Secret material is **never** included in any event's measurements or metadata.

## Events reference

| Event | Measurements | Metadata |
|---|---|---|
| `[:rotating_secrets, :source, :load, :start]` | `%{}` | `%{name: atom, source: atom}` |
| `[:rotating_secrets, :source, :load, :stop]` | `%{}` | `%{name: atom, source: atom, result: :ok \| :error}` (+ `reason:` on error) |
| `[:rotating_secrets, :source, :load, :exception]` | `%{}` | `%{name: atom, source: atom, kind: atom, reason: term}` |
| `[:rotating_secrets, :rotation]` | `%{version: term}` | `%{name: atom}` |
| `[:rotating_secrets, :state_change]` | `%{}` | `%{name: atom, from: atom, to: atom}` |
| `[:rotating_secrets, :subscriber_added]` | `%{}` | `%{name: atom}` |
| `[:rotating_secrets, :subscriber_removed]` | `%{}` | `%{name: atom, reason: term}` |
| `[:rotating_secrets, :degraded]` | `%{}` | `%{name: atom, reason: term}` |
| `[:rotating_secrets, :dev_source_in_use]` | `%{}` | `%{name: atom, source: atom}` |

### Event descriptions

- **`:source, :load, :start` / `:stop` / `:exception`** — Bracketing events around every call to `source.load/1`. Use these to measure load latency and track failure rates by source module.
- **`:rotation`** — Emitted when a new value replaces the previous one. Includes the new version in measurements.
- **`:state_change`** — Emitted on every lifecycle state transition. The `from` and `to` atoms correspond to the states in the [Secret Lifecycle](concepts/secret_lifecycle.md) diagram.
- **`:subscriber_added` / `:subscriber_removed`** — Tracks the subscriber population for capacity planning.
- **`:degraded`** — Emitted when the Registry enters a degraded state (consecutive load failures, approaching expiry). Treat this as an alert-worthy signal.
- **`:dev_source_in_use`** — Emitted when `Source.Env` or another development-only source initialises. If you see this in production, a misconfiguration has occurred.

## Default handlers

For development and basic production observability, attach the default Logger-based handlers:

```elixir
RotatingSecrets.Telemetry.attach_default_handlers()
```

This attaches a single handler to all events. Each event is logged at `:debug` level using structured metadata. The function is idempotent: calling it a second time replaces the previously attached handler without error.

Place this call in your application startup or in a `config/runtime.exs` block gated on the environment:

```elixir
# In application.ex start/2, after the supervisor is running:
if Application.get_env(:my_app, :env) != :prod do
  RotatingSecrets.Telemetry.attach_default_handlers()
end
```

## Custom handler

Attach your own handler with the standard `:telemetry` API:

```elixir
:telemetry.attach(
  "myapp-secrets-rotation-handler",
  [:rotating_secrets, :rotation],
  fn _event, %{version: version}, %{name: name}, _config ->
    Logger.info("Secret #{name} rotated to version #{inspect(version)}")
  end,
  nil
)
```

To detach:

```elixir
:telemetry.detach("myapp-secrets-rotation-handler")
```

Attach all events at once with `:telemetry.attach_many/4`:

```elixir
events = RotatingSecrets.Telemetry.event_names()

:telemetry.attach_many(
  "myapp-secrets-all",
  events,
  fn event, measurements, metadata, _config ->
    MyApp.Metrics.count(event, measurements, metadata)
  end,
  nil
)
```

## Prometheus / Telemetry.Metrics integration

If your application uses `Telemetry.Metrics` and a reporter such as `PromEx` or `TelemetryMetricsPrometheus`, define metrics for the RotatingSecrets events:

```elixir
defmodule MyApp.Metrics do
  import Telemetry.Metrics

  def metrics do
    [
      # Count rotations by secret name
      counter("rotating_secrets.rotation.count",
        event_name: [:rotating_secrets, :rotation],
        tags: [:name]
      ),

      # Count load failures
      counter("rotating_secrets.source.load.stop.count",
        event_name: [:rotating_secrets, :source, :load, :stop],
        tag_values: fn meta ->
          %{name: meta.name, source: meta.source, result: meta.result}
        end,
        tags: [:name, :source, :result]
      ),

      # Alert on degraded secrets
      counter("rotating_secrets.degraded.count",
        event_name: [:rotating_secrets, :degraded],
        tags: [:name]
      ),

      # Track state transitions
      counter("rotating_secrets.state_change.count",
        event_name: [:rotating_secrets, :state_change],
        tags: [:name, :from, :to]
      )
    ]
  end
end
```

Pass this metrics list to your reporter at startup. Refer to your reporter's documentation for the exact wiring; the event names and metadata fields above are stable across RotatingSecrets releases.
