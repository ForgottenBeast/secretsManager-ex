defmodule RotatingSecrets do
  @moduledoc """
  Public API for the RotatingSecrets secret lifecycle library.

  Each secret is managed by a dedicated `RotatingSecrets.Registry` GenServer process
  that handles loading, caching, TTL-based refresh, subscriber fan-out, and
  exponential-backoff error recovery. All reads are served from memory — no I/O
  on the hot path.

  ## Quick start

      # In your application.ex supervision tree:
      children = [RotatingSecrets.Supervisor, ...]

      # Register a secret (here using the built-in env source for development):
      {:ok, _pid} = RotatingSecrets.register(:db_password,
        source: RotatingSecrets.Source.Env,
        source_opts: [var_name: "DB_PASSWORD"]
      )

      # Read it:
      {:ok, secret} = RotatingSecrets.current(:db_password)
      password = RotatingSecrets.Secret.expose(secret)

  ## Rotation notifications

  Subscribers receive `{:rotating_secret_rotated, sub_ref, name, version}` messages
  whenever the secret rotates. They must call `current/1` explicitly to obtain the
  new value — the message never carries secret material.

      {:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)

      receive do
        {:rotating_secret_rotated, ^sub_ref, :db_password, _version} ->
          {:ok, secret} = RotatingSecrets.current(:db_password)
          ...
      end

      RotatingSecrets.unsubscribe(:db_password, sub_ref)
  """

  alias RotatingSecrets.Secret
  alias RotatingSecrets.Supervisor

  @process_registry RotatingSecrets.ProcessRegistry

  # ---------------------------------------------------------------------------
  # Secret access
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current secret for `name`, or an error if it is loading or expired.
  """
  @spec current(name :: atom()) :: {:ok, Secret.t()} | {:error, term()}
  def current(name) when is_atom(name) do
    GenServer.call({:via, Registry, {@process_registry, name}}, :current)
  end

  @doc """
  Returns the current secret for `name`, raising on error.
  """
  @spec current!(name :: atom()) :: Secret.t()
  def current!(name) when is_atom(name) do
    case current(name) do
      {:ok, secret} -> secret
      {:error, reason} -> raise "RotatingSecrets: #{name} unavailable: #{inspect(reason)}"
    end
  end

  @doc """
  Fetches the current secret for `name` and passes it to `fun`.

  Returns `{:ok, result}` on success or `{:error, reason}` if the secret is
  unavailable. The secret struct is not retained outside the function call.

  ## Examples

      RotatingSecrets.with_secret(:db_password, fn secret ->
        connect(RotatingSecrets.Secret.expose(secret))
      end)
  """
  @spec with_secret(name :: atom(), (Secret.t() -> result)) ::
          {:ok, result} | {:error, term()}
        when result: var
  def with_secret(name, fun) when is_atom(name) and is_function(fun, 1) do
    case current(name) do
      {:ok, secret} -> {:ok, fun.(secret)}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Subscriptions
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to rotation notifications for `name`.

  Returns `{:ok, sub_ref}` on success. The subscriber receives
  `{:rotating_secret_rotated, sub_ref, name, version}` messages on each rotation.
  The subscriber must call `current/1` explicitly — notifications never carry
  the secret value.

  Call `unsubscribe/2` with `name` and `sub_ref` to cancel the subscription.
  """
  @spec subscribe(name :: atom()) :: {:ok, reference()} | {:error, term()}
  def subscribe(name) when is_atom(name) do
    GenServer.call({:via, Registry, {@process_registry, name}}, {:subscribe, self()})
  end

  @doc """
  Cancels the subscription identified by `sub_ref` for secret `name`.

  Always returns `:ok`, even if the subscription does not exist.
  """
  @spec unsubscribe(name :: atom(), sub_ref :: reference()) :: :ok
  def unsubscribe(name, sub_ref) when is_atom(name) and is_reference(sub_ref) do
    GenServer.call({:via, Registry, {@process_registry, name}}, {:unsubscribe, sub_ref})
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts a secret process under the `RotatingSecrets.Supervisor`.

  `opts` must include `:source` (a module implementing `RotatingSecrets.Source`)
  and may include `:source_opts`, `:fallback_interval_ms`, `:min_backoff_ms`,
  `:max_backoff_ms`, and `:registry_via`.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec register(name :: atom(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  def register(name, opts) when is_atom(name) and is_list(opts) do
    Supervisor.register(name, opts)
  end

  @doc """
  Terminates the secret process registered under `name`.

  Returns `:ok` on success or `{:error, :not_found}` if no such secret is registered.
  """
  @spec deregister(name :: atom()) :: :ok | {:error, :not_found}
  def deregister(name) when is_atom(name) do
    Supervisor.deregister(name)
  end

  # ---------------------------------------------------------------------------
  # Cluster
  # ---------------------------------------------------------------------------

  @doc """
  Returns the version and metadata for `name` on every connected node.

  Calls `RotatingSecrets.Registry.version_and_meta/1` on each node in
  `Node.list/0` via `:rpc.multicall/5` with a 5-second timeout.

  The result map keys are node names. Unreachable nodes and RPC failures
  both map to `{:error, :noconnection}`. Secret values are never returned.

  ## Example

      %{
        :"a@host" => {:ok, 3, %{ttl_seconds: 300}},
        :"b@host" => {:error, :noconnection}
      } = RotatingSecrets.cluster_status(:db_password)
  """
  @spec cluster_status(name :: atom()) ::
          %{node() => {:ok, version :: term(), meta :: map()} | {:error, term()}}
  def cluster_status(name) when is_atom(name) do
    nodes = Node.list()
    {results, bad_nodes} =
      :rpc.multicall(nodes, RotatingSecrets.Registry, :version_and_meta, [name], 5_000)

    good_nodes = nodes -- bad_nodes

    good_results =
      good_nodes
      |> Enum.zip(results)
      |> Map.new(fn
        {node, {:badrpc, _}} -> {node, {:error, :noconnection}}
        {node, result} -> {node, result}
      end)

    bad_results = Map.new(bad_nodes, fn node -> {node, {:error, :noconnection}} end)

    Map.merge(good_results, bad_results)
  end
end
