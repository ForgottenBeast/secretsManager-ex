defmodule RotatingSecrets.Source.Controllable do
  @moduledoc """
  A `RotatingSecrets.Source` for use in tests.

  Holds its secret value in memory and exposes `rotate/2` for manually
  triggering a rotation in-process, without any external I/O. The normal
  Registry subscription path fires, so `{:rotating_secret_rotated, sub_ref,
  name, version}` messages are delivered to all subscribers exactly as they
  would be from a real source.

  `Source.Controllable` uses a named `Agent` registered in its own
  `RotatingSecrets.Source.Controllable.Registry`. Start that registry before
  using this source by including `RotatingSecrets.Testing.Supervisor` in your
  test supervision tree, or by starting it manually:

      {:ok, _} = Registry.start_link(keys: :unique, name: RotatingSecrets.Source.Controllable.Registry)

  ## Options

    * `:name` — atom that identifies the secret (must match the name passed to
      `RotatingSecrets.register/2`). Required.
    * `:initial_value` — the starting binary value. Required.

  ## Example

      # In test setup:
      start_supervised!(RotatingSecrets.Supervisor)
      start_supervised!(RotatingSecrets.Testing.Supervisor)

      RotatingSecrets.register(:api_key,
        source: RotatingSecrets.Source.Controllable,
        source_opts: [name: :api_key, initial_value: "initial-key"]
      )

      # Later, rotate in-process:
      :ok = RotatingSecrets.Source.Controllable.rotate(:api_key, "rotated-key")
  """

  @behaviour RotatingSecrets.Source

  @registry RotatingSecrets.Source.Controllable.Registry

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Rotates the value for the named secret and triggers an immediate refresh.

  Sends a notification to the Registry process; the Registry routes it through
  `handle_change_notification/2`, which triggers a fresh `load/1` call that
  reads the new value from the Agent.

  Returns `:ok`, or `{:error, :not_found}` if the secret is not registered.
  """
  @spec rotate(name :: atom(), new_value :: binary()) :: :ok | {:error, :not_found}
  def rotate(name, new_value) when is_atom(name) and is_binary(new_value) do
    agent_key = {__MODULE__, name}

    case Registry.lookup(@registry, agent_key) do
      [{agent_pid, _}] ->
        {channel_ref, registry_pid} =
          Agent.get_and_update(agent_pid, fn s ->
            {{s.channel_ref, s.registry_pid}, %{s | value: new_value}}
          end)

        if channel_ref && registry_pid do
          send(registry_pid, {channel_ref, :rotated})
        end

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Source behaviour
  # ---------------------------------------------------------------------------

  @impl RotatingSecrets.Source
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    initial_value = Keyword.fetch!(opts, :initial_value)

    agent_key = {__MODULE__, name}
    agent_name = {:via, Registry, {@registry, agent_key}}

    case Agent.start_link(
           fn -> %{value: initial_value, channel_ref: nil, registry_pid: nil} end,
           name: agent_name
         ) do
      {:ok, _pid} ->
        {:ok, %{name: name, channel_ref: nil}}

      {:error, {:already_started, _pid}} ->
        Agent.update(agent_name, fn _ ->
          %{value: initial_value, channel_ref: nil, registry_pid: nil}
        end)

        {:ok, %{name: name, channel_ref: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl RotatingSecrets.Source
  def load(%{name: name} = state) do
    agent_name = {:via, Registry, {@registry, {__MODULE__, name}}}
    value = Agent.get(agent_name, & &1.value)
    {:ok, value, %{}, state}
  end

  @impl RotatingSecrets.Source
  def subscribe_changes(state) do
    channel_ref = make_ref()
    registry_pid = self()

    agent_name = {:via, Registry, {@registry, {__MODULE__, state.name}}}

    Agent.update(agent_name, fn s ->
      %{s | channel_ref: channel_ref, registry_pid: registry_pid}
    end)

    {:ok, channel_ref, %{state | channel_ref: channel_ref}}
  end

  @impl RotatingSecrets.Source
  def handle_change_notification({channel_ref, :rotated}, state)
      when channel_ref == state.channel_ref do
    {:changed, state}
  end

  def handle_change_notification(_msg, _state), do: :ignored

  @impl RotatingSecrets.Source
  def terminate(%{name: name} = _state) do
    agent_name = {:via, Registry, {@registry, {__MODULE__, name}}}

    try do
      Agent.stop(agent_name)
    catch
      :exit, _ -> :ok
    end

    :ok
  end
end
