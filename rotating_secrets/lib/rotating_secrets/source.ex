defmodule RotatingSecrets.Source do
  @moduledoc """
  Behaviour for secret sources.

  A source encapsulates how a secret is loaded from an external system
  (file, environment variable, Vault, KMS, etc.). The `RotatingSecrets.Registry`
  owns the lifecycle of each secret; the source handles only the I/O.

  ## Callbacks

  ### Required

  - `init/1` — validate opts and build initial state. Must be fast; no I/O.
  - `load/1` — fetch the current secret material and metadata. Called on
    initial load and on each refresh. Must return `{:ok, material, meta, state}`
    or `{:error, reason, state}`. Errors are transient: the Registry serves
    last-known-good and schedules a retry.

  ### Optional

  - `subscribe_changes/1` — register for push notifications (e.g. inotify).
    Return `{:ok, ref, state}` to enable push-driven refresh, or
    `:not_supported` to fall back to TTL/interval polling.
  - `handle_change_notification/2` — called by the Registry when a message
    matching the subscription ref arrives. Return `{:changed, state}` to
    trigger an immediate refresh.
  - `terminate/1` — clean up subscriptions or handles on Registry shutdown.

  ## Meta map

  The `meta` map returned by `load/1` MAY include:

  - `:version` — an ordered term (integer preferred) for monotone tracking.
    Use `nil` when the source has no ordering concept (KV v1, dynamic secrets).
  - `:ttl_seconds` — positive integer; drives 2/3-lifetime refresh scheduling.
    Use `nil` when no TTL is known; Registry falls back to configured interval.
  - `:issued_at` — `DateTime.t()` when the material was issued.
  - `:content_hash` — hex-encoded SHA-256 of material; useful for change
    detection when `:version` is `nil`.
  - Any source-specific keys (e.g. `:lease_id` for Vault dynamic secrets).

  ## Example

      defmodule MyApp.Source.Static do
        @behaviour RotatingSecrets.Source

        @impl true
        def init(opts), do: {:ok, %{value: Keyword.fetch!(opts, :value)}}

        @impl true
        def load(state), do: {:ok, state.value, %{version: 1}, state}
      end
  """

  @type state :: term()
  @type material :: binary()
  @type meta :: %{
          optional(:version) => term() | nil,
          optional(:ttl_seconds) => pos_integer() | nil,
          optional(:issued_at) => DateTime.t(),
          optional(:content_hash) => binary(),
          optional(atom()) => term()
        }

  @doc """
  Initialise the source from `opts`. Must be fast — no blocking I/O.

  Return `{:ok, state}` on success or `{:error, reason}` on invalid
  configuration. Error reasons must not contain raw opts or secret values.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Load the current secret material.

  Returns `{:ok, material, meta, new_state}` on success or
  `{:error, reason, new_state}` on transient failure. The Registry
  treats all errors as transient: it serves last-known-good and
  schedules an exponential-backoff retry.
  """
  @callback load(state()) ::
              {:ok, material(), meta(), state()} | {:error, term(), state()}

  @doc """
  Optionally register for push change notifications.

  Return `{:ok, ref, new_state}` where `ref` identifies messages that
  the source will send to the Registry PID. The Registry stores `ref` and
  routes matching `handle_info` messages to `handle_change_notification/2`.

  Return `:not_supported` to fall back to TTL/interval polling.
  """
  @callback subscribe_changes(state()) ::
              {:ok, ref :: term(), state()} | :not_supported

  @doc """
  Handle a push notification message.

  Called by the Registry when an unrecognised `handle_info` message arrives
  that was previously associated with the subscription ref.

  - `{:changed, new_state}` — triggers an immediate refresh.
  - `:ignored` — no-op; Registry discards the message.
  - `{:error, reason}` — logged with structured metadata; Registry continues.
  """
  @callback handle_change_notification(msg :: term(), state()) ::
              {:changed, state()} | :ignored | {:error, term()}

  @doc """
  Clean up subscriptions or file handles on Registry shutdown.
  """
  @callback terminate(state()) :: :ok

  @optional_callbacks [
    subscribe_changes: 1,
    handle_change_notification: 2,
    terminate: 1
  ]
end
