defmodule RotatingSecrets.Source.Env do
  @moduledoc """
  A `RotatingSecrets.Source` that reads a secret from an environment variable.

  **This source is intended for development and testing only.** It emits a
  `[:rotating_secrets, :dev_source_in_use]` telemetry event and a Logger warning
  on `init/1` to discourage use in production.

  Environment variables are process-global and not rotated at the OS level in the
  same way as files or Vault leases. Use `RotatingSecrets.Source.File` or a
  Vault-backed source for production workloads.

  ## Options

    * `:var_name` — name of the environment variable to read. Required.
    * `:name` — the secret name atom (injected automatically by the Registry).

  ## Example

      RotatingSecrets.register(:db_password,
        source: RotatingSecrets.Source.Env,
        source_opts: [var_name: "DB_PASSWORD"]
      )
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Telemetry

  require Logger

  @impl RotatingSecrets.Source
  def init(opts) do
    var_name = Keyword.fetch!(opts, :var_name)

    if is_binary(var_name) do
      secret_name = Keyword.get(opts, :name, __MODULE__)

      Telemetry.emit_dev_source_in_use(secret_name, __MODULE__)

      Logger.warning(
        "RotatingSecrets.Source.Env: reading secret from environment variable — not recommended for production",
        secret_name: secret_name,
        var_name: var_name
      )

      {:ok, %{var_name: var_name, name: secret_name}}
    else
      {:error, {:invalid_option, {:var_name, var_name}}}
    end
  end

  @impl RotatingSecrets.Source
  def load(state) do
    case System.fetch_env(state.var_name) do
      {:ok, value} ->
        {:ok, value, %{}, state}

      :error ->
        {:error, :enoent, state}
    end
  end
end
