defmodule RotatingSecrets.Registry do
  @moduledoc """
  GenServer managing the lifecycle of a single named secret.

  The Registry runs the source through the five-state lifecycle modelled in
  `specs/registry.tla`: Loading → Valid → Refreshing → Valid / Expiring →
  Expired.  It fans out rotation notifications to subscribers, handles
  exponential back-off on failure, and delegates source-specific change
  notifications to `RotatingSecrets.Source`.

  ## Options

    * `:name` — atom that identifies the secret. Required.
    * `:source` — module implementing `RotatingSecrets.Source`. Required.
    * `:source_opts` — keyword list forwarded to `source.init/1`. Default `[]`.
    * `:server_name` — GenServer registration term (e.g. `{:via, Horde.Registry, …}`).
      Defaults to the `:name` atom for local registration.
    * `:fallback_interval_ms` — refresh interval when no `:ttl_seconds` in meta.
      Default #{60_000}.
    * `:min_backoff_ms` — initial retry delay on load failure. Default #{1_000}.
    * `:max_backoff_ms` — maximum retry delay (exponential cap). Default #{60_000}.
  """

  use GenServer

  alias RotatingSecrets.Secret

  @default_fallback_ms 60_000
  @default_min_backoff_ms 1_000
  @default_max_backoff_ms 60_000

  # ---------------------------------------------------------------------------
  # Child spec
  # ---------------------------------------------------------------------------

  @doc """
  Returns a fully-serializable child spec for use under a `DynamicSupervisor`.
  The spec contains no closures, PIDs, or refs so it survives Horde migration.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # ---------------------------------------------------------------------------
  # Start
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    server_name = Keyword.get(opts, :server_name, name)
    GenServer.start_link(__MODULE__, opts, name: server_name)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)

    name = Keyword.fetch!(opts, :name)
    source = Keyword.fetch!(opts, :source)
    source_opts = Keyword.get(opts, :source_opts, [])

    case source.init(source_opts) do
      {:ok, source_state} ->
        state = %{
          name: name,
          lifecycle: :loading,
          secret: nil,
          source: source,
          source_state: source_state,
          subscribers: %{},
          sub_refs: %{},
          refresh_timer: nil,
          base_backoff_ms: Keyword.get(opts, :min_backoff_ms, @default_min_backoff_ms),
          max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
          backoff_ms: Keyword.get(opts, :min_backoff_ms, @default_min_backoff_ms),
          fallback_ms: Keyword.get(opts, :fallback_interval_ms, @default_fallback_ms)
        }

        {:ok, state, {:continue, :initial_load}}

      {:error, reason} ->
        {:stop, {:source_init_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue(:initial_load, state) do
    case do_load(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:permanent_error, reason, new_state} ->
        {:stop, {:permanent_load_failure, reason}, new_state}

      {:transient_error, reason, new_state} ->
        {:stop, {:transient_load_failure, reason}, new_state}
    end
  end

  @impl GenServer
  def handle_call(:current, _from, state) do
    reply =
      case state.lifecycle do
        :loading -> {:error, :loading}
        :expired -> {:error, :expired}
        _ -> {:ok, state.secret}
      end

    {:reply, reply, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    monitor_ref = Process.monitor(pid)
    sub_ref = make_ref()

    new_state = %{
      state
      | subscribers: Map.put(state.subscribers, monitor_ref, {sub_ref, pid}),
        sub_refs: Map.put(state.sub_refs, sub_ref, monitor_ref)
    }

    :telemetry.execute([:rotating_secrets, :subscriber_added], %{}, %{name: state.name})

    {:reply, {:ok, sub_ref}, new_state}
  end

  def handle_call({:unsubscribe, sub_ref}, _from, state) do
    case Map.get(state.sub_refs, sub_ref) do
      nil ->
        {:reply, :ok, state}

      monitor_ref ->
        Process.demonitor(monitor_ref, [:flush])

        new_state = %{
          state
          | subscribers: Map.delete(state.subscribers, monitor_ref),
            sub_refs: Map.delete(state.sub_refs, sub_ref)
        }

        :telemetry.execute(
          [:rotating_secrets, :subscriber_removed],
          %{},
          %{name: state.name, reason: :unsubscribed}
        )

        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_info(:do_refresh, state) do
    case do_load(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {_class, _reason, new_state} ->
        {:noreply, schedule_backoff(new_state)}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.get(state.subscribers, monitor_ref) do
      nil ->
        {:noreply, state}

      {sub_ref, _pid} ->
        new_state = %{
          state
          | subscribers: Map.delete(state.subscribers, monitor_ref),
            sub_refs: Map.delete(state.sub_refs, sub_ref)
        }

        :telemetry.execute(
          [:rotating_secrets, :subscriber_removed],
          %{},
          %{name: state.name, reason: reason}
        )

        {:noreply, new_state}
    end
  end

  def handle_info(msg, state) do
    if function_exported?(state.source, :handle_change_notification, 2) do
      handle_change_notification(msg, state)
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    if function_exported?(state.source, :terminate, 1) do
      state.source.terminate(state.source_state)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_change_notification(msg, state) do
    case state.source.handle_change_notification(msg, state.source_state) do
      {:changed, new_source_state} ->
        new_state = %{state | source_state: new_source_state}

        case do_load(new_state) do
          {:ok, loaded_state} -> {:noreply, loaded_state}
          {_class, _reason, error_state} -> {:noreply, schedule_backoff(error_state)}
        end

      :ignored ->
        {:noreply, state}

      {:error, reason} ->
        :logger.warning(
          ~c"RotatingSecrets.Registry: source notification error",
          %{name: state.name, reason: inspect(reason)}
        )

        {:noreply, state}
    end
  end

  defp do_load(state) do
    :telemetry.execute(
      [:rotating_secrets, :source, :load, :start],
      %{},
      %{name: state.name, source: state.source}
    )

    case state.source.load(state.source_state) do
      {:ok, material, meta, new_source_state} ->
        :telemetry.execute(
          [:rotating_secrets, :source, :load, :stop],
          %{},
          %{name: state.name, source: state.source, result: :ok}
        )

        secret = struct!(Secret, name: state.name, value: material, meta: meta)
        version = Map.get(meta, :version)
        prev_lifecycle = state.lifecycle

        cancel_timer(state.refresh_timer)
        timer = schedule_refresh(meta, state)

        new_state = %{
          state
          | lifecycle: :valid,
            secret: secret,
            source_state: new_source_state,
            refresh_timer: timer,
            backoff_ms: state.base_backoff_ms
        }

        emit_load_telemetry(new_state.name, prev_lifecycle, version)
        fan_out_notifications(new_state.subscribers, new_state.name, version)

        {:ok, new_state}

      {:error, reason, new_source_state} ->
        :telemetry.execute(
          [:rotating_secrets, :source, :load, :stop],
          %{},
          %{name: state.name, source: state.source, result: :error, reason: reason}
        )

        {classify_error(reason), reason, %{state | source_state: new_source_state}}
    end
  end

  defp emit_load_telemetry(name, prev_lifecycle, version) do
    if prev_lifecycle == :valid do
      :telemetry.execute([:rotating_secrets, :rotation], %{version: version}, %{name: name})
    else
      :telemetry.execute(
        [:rotating_secrets, :state_change],
        %{},
        %{name: name, from: prev_lifecycle, to: :valid}
      )
    end
  end

  defp classify_error(:enoent), do: :permanent_error
  defp classify_error(:eacces), do: :permanent_error
  defp classify_error({:invalid_option, _}), do: :permanent_error
  defp classify_error(_), do: :transient_error

  defp schedule_refresh(meta, state) do
    delay =
      case Map.get(meta, :ttl_seconds) do
        nil ->
          state.fallback_ms

        ttl when is_integer(ttl) and ttl > 0 ->
          trunc(ttl * 1000 * 2 / 3)
      end

    Process.send_after(self(), :do_refresh, delay)
  end

  defp schedule_backoff(state) do
    timer = Process.send_after(self(), :do_refresh, state.backoff_ms)
    next_backoff = min(state.backoff_ms * 2, state.max_backoff_ms)
    %{state | refresh_timer: timer, backoff_ms: next_backoff}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp fan_out_notifications(subscribers, name, version) do
    Enum.each(subscribers, fn {_monitor_ref, {sub_ref, pid}} ->
      send(pid, {:rotating_secret_rotated, sub_ref, name, version})
    end)
  end
end
