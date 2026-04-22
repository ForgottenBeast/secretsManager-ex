# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
# Registry orchestrates the full secret lifecycle across source, telemetry, subscriber,
# supervisor, and secret modules — the dependency count is inherent to its role.
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
  alias RotatingSecrets.Telemetry

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

  @doc """
  Starts the `RotatingSecrets.Registry` GenServer for a single named secret.

  `opts` must include `:name` (the secret atom) and `:source` (a module
  implementing `RotatingSecrets.Source`). Typically called by
  `RotatingSecrets.Supervisor.register/2` via the `DynamicSupervisor`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    server_name = Keyword.get(opts, :server_name, name)
    GenServer.start_link(__MODULE__, opts, name: server_name)
  end

  # ---------------------------------------------------------------------------
  # Public module-level function for cluster RPC
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current version and metadata for the named secret on this node.

  Intended to be called via `:rpc.multicall` from `RotatingSecrets.cluster_status/1`.
  Never returns secret values.
  """
  @spec version_and_meta(name :: atom()) ::
          {:ok, version :: term(), meta :: map()} | {:error, term()}
  def version_and_meta(name) when is_atom(name) do
    GenServer.call({:via, Registry, {RotatingSecrets.ProcessRegistry, name}}, :version_and_meta)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)
    # trap_exit ensures GenServer.terminate/2 is invoked when the supervisor
    # sends exit(Pid, :shutdown), allowing source.terminate/1 to run cleanup
    # (e.g. revoking Vault leases) before the process exits.
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)

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

        case do_load(state) do
          {:ok, new_state} ->
            {:ok, new_state}

          {:permanent_error, reason, _new_state} ->
            {:stop, {:permanent_load_failure, reason}}

          {:transient_error, reason, _new_state} ->
            {:stop, {:transient_load_failure, reason}}
        end

      {:error, reason} ->
        {:stop, {:source_init_failed, reason}}
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

    Telemetry.emit_subscriber_added(state.name)

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

        Telemetry.emit_subscriber_removed(state.name, :unsubscribed)

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:version_and_meta, _from, state) do
    reply =
      case state.lifecycle do
        s when s in [:loading, :expired] ->
          {:error, s}

        _ ->
          {:ok, Map.get(state.secret.meta, :version), state.secret.meta}
      end

    {:reply, reply, state}
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

  def handle_info({:DOWN, monitor_ref, :process, _pid, :noconnection}, state) do
    case Map.get(state.subscribers, monitor_ref) do
      nil ->
        {:noreply, state}

      {sub_ref, _pid} ->
        new_state = %{
          state
          | subscribers: Map.delete(state.subscribers, monitor_ref),
            sub_refs: Map.delete(state.sub_refs, sub_ref)
        }

        Telemetry.emit_subscriber_removed(state.name, :noconnection)

        {:noreply, new_state}
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

        Telemetry.emit_subscriber_removed(state.name, reason)

        {:noreply, new_state}
    end
  end

  def handle_info({:nodedown, node}, state) do
    {to_remove, _} =
      Enum.split_with(state.subscribers, fn {_mref, {_sub_ref, pid}} ->
        node(pid) == node
      end)

    Enum.each(to_remove, fn {mref, _} ->
      Process.demonitor(mref, [:flush])
      Telemetry.emit_subscriber_removed(state.name, :nodedown)
    end)

    remove_mrefs = Enum.map(to_remove, &elem(&1, 0))
    remove_sub_refs = Enum.map(to_remove, fn {_, {sub_ref, _}} -> sub_ref end)

    new_state = %{
      state
      | subscribers: Map.drop(state.subscribers, remove_mrefs),
        sub_refs: Map.drop(state.sub_refs, remove_sub_refs)
    }

    {:noreply, new_state}
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
    Telemetry.emit_load_start(state.name, state.source)

    result =
      try do
        state.source.load(state.source_state)
      rescue
        exception ->
          Telemetry.emit_load_exception(state.name, state.source, :error, exception)
          {:error, {:exception, exception}, state.source_state}
      catch
        kind, reason ->
          Telemetry.emit_load_exception(state.name, state.source, kind, reason)
          {:error, {:exception, {kind, reason}}, state.source_state}
      end

    case result do
      {:ok, material, meta, new_source_state} ->
        Telemetry.emit_load_stop(state.name, state.source, :ok)

        secret = struct!(Secret, name: state.name, value: material, meta: meta)
        version = Map.get(meta, :version)
        prev_lifecycle = state.lifecycle

        # On first load, enable push notifications if source supports them
        subscribed_source_state =
          if prev_lifecycle == :loading and
               function_exported?(state.source, :subscribe_changes, 1) do
            case state.source.subscribe_changes(new_source_state) do
              {:ok, _ref, sub_state} -> sub_state
              :not_supported -> new_source_state
            end
          else
            new_source_state
          end

        cancel_timer(state.refresh_timer)
        timer = schedule_refresh(meta, state)

        new_state = %{
          state
          | lifecycle: :valid,
            secret: secret,
            source_state: subscribed_source_state,
            refresh_timer: timer,
            backoff_ms: state.base_backoff_ms
        }

        emit_load_telemetry(new_state.name, prev_lifecycle, version)
        fan_out_notifications(new_state.subscribers, new_state.name, version)

        {:ok, new_state}

      {:error, reason, new_source_state} ->
        Telemetry.emit_load_stop(state.name, state.source, {:error, reason})

        {classify_error(reason), reason, %{state | source_state: new_source_state}}
    end
  end

  defp emit_load_telemetry(name, prev_lifecycle, version) do
    if prev_lifecycle == :valid do
      Telemetry.emit_rotation(name, version)
    else
      Telemetry.emit_state_change(name, prev_lifecycle, :valid)
    end
  end

  defp classify_error(:enoent), do: :permanent_error
  defp classify_error(:eacces), do: :permanent_error
  defp classify_error(:not_found), do: :permanent_error
  defp classify_error(:forbidden), do: :permanent_error
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

    maybe_pg_broadcast(name, version)
  end

  defp maybe_pg_broadcast(name, version) do
    if Application.get_env(:rotating_secrets, :cluster_broadcast, false) do
      group = Application.get_env(
        :rotating_secrets,
        :cluster_broadcast_group,
        :rotating_secrets_rotations
      )

      try do
        members = :pg.get_members(group)

        Enum.each(members, fn pid ->
          send(pid, {:rotating_secret_rotated_cluster, node(), name, version})
        end)
      rescue
        _ -> :ok
      end
    end
  end
end
