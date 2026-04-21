defmodule RotatingSecrets.Source.Memory do
  @moduledoc """
  A `RotatingSecrets.Source` that holds its secret value in memory.

  Intended for testing and development: `update/2` lets you programmatically
  rotate the secret in-process, triggering the normal subscription notification
  path without any external I/O.

  `Source.Memory` uses a named `Agent` registered in `RotatingSecrets.ProcessRegistry`
  to share the current value and subscription state between the source callbacks and
  the public `update/2` function.

  ## Options

    * `:name` — atom that identifies the secret (must match the name passed to
      `RotatingSecrets.register/2`). Required.
    * `:initial_value` — the starting binary value. Required.

  ## Example

      RotatingSecrets.register(:api_key,
        source: RotatingSecrets.Source.Memory,
        source_opts: [name: :api_key, initial_value: "initial-key"]
      )

      # Later, rotate in-process:
      RotatingSecrets.Source.Memory.update(:api_key, "rotated-key")
  """

  @behaviour RotatingSecrets.Source

  @process_registry RotatingSecrets.ProcessRegistry

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Updates the value for the named secret and triggers an immediate rotation.

  Sends a `{channel_ref, :updated}` message to the Registry process; the Registry
  routes it through `handle_change_notification/2`, which triggers a fresh `load/1`
  call that reads the new value from the Agent.

  Returns `:ok`. If the secret is not registered or not yet subscribed, the update
  is stored in the Agent but no notification is sent.
  """
  @spec update(name :: atom(), new_value :: binary()) :: :ok | {:error, :not_found}
  def update(name, new_value) when is_atom(name) do
    agent_key = {__MODULE__, name}

    case Registry.lookup(@process_registry, agent_key) do
      [{agent_pid, _}] ->
        {channel_ref, registry_pid} =
          Agent.get_and_update(agent_pid, fn s ->
            {{s.channel_ref, s.registry_pid}, %{s | value: new_value}}
          end)

        if channel_ref && registry_pid do
          send(registry_pid, {channel_ref, :updated})
        end

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Source behaviour
  # ---------------------------------------------------------------------------

  @doc """
  Starts a named `Agent` to hold the in-memory secret value and subscription state.
  Resets the agent if one already exists for `name`.
  """
  @impl RotatingSecrets.Source
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    initial_value = Keyword.fetch!(opts, :initial_value)

    agent_key = {__MODULE__, name}
    agent_name = {:via, Registry, {@process_registry, agent_key}}

    case Agent.start_link(
           fn -> %{value: initial_value, channel_ref: nil, registry_pid: nil} end,
           name: agent_name
         ) do
      {:ok, _pid} ->
        {:ok, %{name: name, channel_ref: nil}}

      {:error, {:already_started, _pid}} ->
        # Reset existing agent state on re-registration
        Agent.update(agent_name, fn _ ->
          %{value: initial_value, channel_ref: nil, registry_pid: nil}
        end)

        {:ok, %{name: name, channel_ref: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads the current value from the backing `Agent`.
  Always succeeds; returns `{:ok, value, %{}, state}`.
  """
  @impl RotatingSecrets.Source
  def load(state) do
    agent_name = {:via, Registry, {@process_registry, {__MODULE__, state.name}}}
    value = Agent.get(agent_name, & &1.value)
    {:ok, value, %{}, state}
  end

  @doc """
  Records the channel reference and Registry PID in the `Agent` so that `update/2`
  can send change notifications to the correct process.
  """
  @impl RotatingSecrets.Source
  def subscribe_changes(state) do
    channel_ref = make_ref()
    registry_pid = self()

    agent_name = {:via, Registry, {@process_registry, {__MODULE__, state.name}}}

    Agent.update(agent_name, fn s ->
      %{s | channel_ref: channel_ref, registry_pid: registry_pid}
    end)

    {:ok, channel_ref, %{state | channel_ref: channel_ref}}
  end

  @doc """
  Returns `{:changed, state}` when the message matches the registered channel reference,
  indicating that `update/2` has stored a new value. Returns `:ignored` otherwise.
  """
  @impl RotatingSecrets.Source
  def handle_change_notification({channel_ref, :updated}, state)
      when channel_ref == state.channel_ref do
    {:changed, state}
  end

  def handle_change_notification(_msg, _state), do: :ignored

  @doc """
  Stops the backing `Agent` for `state.name`, cleaning up registry entries.
  Returns `:ok`.
  """
  @impl RotatingSecrets.Source
  def terminate(state) do
    agent_name = {:via, Registry, {@process_registry, {__MODULE__, state.name}}}

    try do
      Agent.stop(agent_name)
    catch
      :exit, _ -> :ok
    end

    :ok
  end
end
