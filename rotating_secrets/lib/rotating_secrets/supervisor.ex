defmodule RotatingSecrets.Supervisor do
  @moduledoc """
  Supervision tree for RotatingSecrets.

  Starts a `Registry` for local process name lookup and a `DynamicSupervisor`
  for managing `RotatingSecrets.Registry` children. Add this module to your
  application's supervision tree:

      # In your application.ex
      children = [
        RotatingSecrets.Supervisor,
        # ...
      ]

  ## Distributed deployments (Horde)

  Pass `registry_via: {:via, Horde.Registry, {MyApp.HordeRegistry, name}}`
  to `register/2` to route process registration through Horde instead of the
  built-in local registry.
  """

  use Supervisor

  @dynamic_sup RotatingSecrets.DynamicSupervisor
  @process_registry RotatingSecrets.ProcessRegistry

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a secret process under the supervisor and registers it by `name`.

  `opts` are forwarded to `RotatingSecrets.Registry.start_link/1`. At minimum
  `:source` must be provided.

  The process is registered under `name` in `RotatingSecrets.ProcessRegistry`
  by default. Pass `registry_via:` to use a custom registry (e.g. Horde) for
  distributed deployments.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec register(name :: atom(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  def register(name, opts) when is_atom(name) do
    server_name =
      Keyword.get(opts, :registry_via, {:via, Registry, {@process_registry, name}})

    child_opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:server_name, server_name)
      |> Keyword.delete(:registry_via)

    DynamicSupervisor.start_child(@dynamic_sup, {RotatingSecrets.Registry, child_opts})
  end

  @doc """
  Terminates the secret registered under `name`.

  Returns `:ok` on success or `{:error, :not_found}` if no secret with that
  name is registered.
  """
  @spec deregister(name :: atom()) :: :ok | {:error, :not_found}
  def deregister(name) when is_atom(name) do
    case Registry.lookup(@process_registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(@dynamic_sup, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @process_registry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: @dynamic_sup,
       max_restarts: 3,
       max_seconds: 30}
    ]

    # :rest_for_one ensures the DynamicSupervisor restarts if the ProcessRegistry
    # crashes, since all registered names would be lost.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
