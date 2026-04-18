defmodule RotatingSecrets.Telemetry do
  @moduledoc """
  Telemetry integration for RotatingSecrets.

  This module defines all telemetry event names emitted by the library
  and provides `attach_default_handlers/0` for consuming applications
  that want basic observability without writing custom handlers.

  ## Events

  All events live under the `[:rotating_secrets]` namespace.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:rotating_secrets, :source, :load, :start]` | `%{}` | `%{name, source}` |
  | `[:rotating_secrets, :source, :load, :stop]` | `%{}` | `%{name, source, result}` (+ `reason` on error) |
  | `[:rotating_secrets, :source, :load, :exception]` | `%{}` | `%{name, source, kind, reason}` |
  | `[:rotating_secrets, :rotation]` | `%{version: term}` | `%{name}` |
  | `[:rotating_secrets, :state_change]` | `%{}` | `%{name, from, to}` |
  | `[:rotating_secrets, :subscriber_added]` | `%{}` | `%{name}` |
  | `[:rotating_secrets, :subscriber_removed]` | `%{}` | `%{name, reason}` |
  | `[:rotating_secrets, :degraded]` | `%{}` | `%{name, reason}` |
  | `[:rotating_secrets, :dev_source_in_use]` | `%{}` | `%{name, source}` |

  Secret material (the raw binary value from `source.load/1`) is **never** included
  in any event's measurements or metadata.
  """

  @load_start [:rotating_secrets, :source, :load, :start]
  @load_stop [:rotating_secrets, :source, :load, :stop]
  @load_exception [:rotating_secrets, :source, :load, :exception]
  @rotation [:rotating_secrets, :rotation]
  @state_change [:rotating_secrets, :state_change]
  @subscriber_added [:rotating_secrets, :subscriber_added]
  @subscriber_removed [:rotating_secrets, :subscriber_removed]
  @degraded [:rotating_secrets, :degraded]
  @dev_source_in_use [:rotating_secrets, :dev_source_in_use]

  @all_events [
    @load_start,
    @load_stop,
    @load_exception,
    @rotation,
    @state_change,
    @subscriber_added,
    @subscriber_removed,
    @degraded,
    @dev_source_in_use
  ]

  @doc """
  Returns the list of all telemetry event names emitted by the library.
  """
  @spec event_names() :: [list(atom())]
  def event_names, do: @all_events

  @doc """
  Attaches default Logger-based handlers for all RotatingSecrets telemetry events.

  Useful for development and basic production observability. Each event is logged
  at `:debug` level using structured metadata. Safe to call multiple times; the
  previously attached handler is replaced on duplicate calls.

  Returns `:ok` on success.
  """
  @spec attach_default_handlers() :: :ok
  def attach_default_handlers do
    # Detach if already attached (idempotent)
    :telemetry.detach("rotating_secrets-default-logger")

    :telemetry.attach_many(
      "rotating_secrets-default-logger",
      @all_events,
      &__MODULE__.handle_default_event/4,
      nil
    )
  end

  @doc false
  def handle_default_event(event, measurements, metadata, _config) do
    :logger.debug(
      ~c"RotatingSecrets telemetry event",
      Map.merge(%{event: event, measurements: measurements}, metadata)
    )
  end

  # ---------------------------------------------------------------------------
  # Package-internal emit helpers
  #
  # Called by Registry and other internal modules. Each function accepts only
  # non-secret arguments by design: secret material (the raw binary from
  # source.load/1) is never a parameter. This enforces the security invariant
  # at the call site rather than via runtime assertion.
  # ---------------------------------------------------------------------------

  @doc false
  def emit_load_start(name, source) when is_atom(name) and is_atom(source) do
    :telemetry.execute(@load_start, %{}, %{name: name, source: source})
  end

  @doc false
  def emit_load_stop(name, source, :ok) when is_atom(name) and is_atom(source) do
    :telemetry.execute(@load_stop, %{}, %{name: name, source: source, result: :ok})
  end

  def emit_load_stop(name, source, {:error, reason}) when is_atom(name) and is_atom(source) do
    :telemetry.execute(@load_stop, %{}, %{name: name, source: source, result: :error, reason: reason})
  end

  @doc false
  def emit_load_exception(name, source, kind, reason)
      when is_atom(name) and is_atom(source) and kind in [:throw, :error, :exit] do
    :telemetry.execute(@load_exception, %{}, %{
      name: name,
      source: source,
      kind: kind,
      reason: reason
    })
  end

  @doc false
  def emit_rotation(name, version) when is_atom(name) do
    :telemetry.execute(@rotation, %{version: version}, %{name: name})
  end

  @doc false
  def emit_state_change(name, from, to) when is_atom(name) and is_atom(from) and is_atom(to) do
    :telemetry.execute(@state_change, %{}, %{name: name, from: from, to: to})
  end

  @doc false
  def emit_subscriber_added(name) when is_atom(name) do
    :telemetry.execute(@subscriber_added, %{}, %{name: name})
  end

  @doc false
  def emit_subscriber_removed(name, reason) when is_atom(name) do
    :telemetry.execute(@subscriber_removed, %{}, %{name: name, reason: reason})
  end

  @doc false
  def emit_degraded(name, reason) when is_atom(name) do
    :telemetry.execute(@degraded, %{}, %{name: name, reason: reason})
  end

  @doc false
  def emit_dev_source_in_use(name, source) when is_atom(name) and is_atom(source) do
    :telemetry.execute(@dev_source_in_use, %{}, %{name: name, source: source})
  end
end
