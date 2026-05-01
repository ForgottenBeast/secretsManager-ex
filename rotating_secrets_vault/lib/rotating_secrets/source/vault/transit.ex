defmodule RotatingSecrets.Source.Vault.Transit do
  @moduledoc """
  Vault Transit secrets engine source for `RotatingSecrets`.

  Tracks encryption key versions via `GET /v1/{mount}/keys/{name}`.
  Material is the JSON-encoded key metadata map; `meta.version` is the
  integer key version used for rotation detection.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — Transit engine mount path, e.g. `"transit"`. Required.
    * `:name` — Key name, e.g. `"my-key"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:namespace` — Vault Enterprise namespace (non-empty binary). Optional.
    * `:unix_socket` — path to a UNIX domain socket (e.g. `"/run/bao.sock"`). When set, all connections route through this socket. Set `address:` to `"http://localhost"` when using this option. Optional.
    * `:agent_mode` — when true, token is not required (agent handles auth). Default false. Optional.
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.

  ## No TTL

  Transit keys have no inherent TTL. The Registry polls on `fallback_interval_ms`.
  Set a short `fallback_interval_ms` in `register/2` for prompt rotation detection.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP
  alias RotatingSecrets.Source.Vault.Auth.Dispatcher, as: AuthDispatcher
  import RotatingSecrets.Source.Vault.Opts,
    only: [fetch_required_string: 2, fetch_optional_token: 1, validate_namespace: 1, validate_path: 1, validate_unix_socket: 1, validate_auth: 1]

  @impl RotatingSecrets.Source
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    auth_raw = Keyword.get(opts, :auth)

    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount}   <- fetch_required_string(opts, :mount),
         {:ok, name}    <- fetch_required_string(opts, :name),
         {:ok, token}   <- fetch_optional_token(opts),
         :ok            <- validate_namespace(Keyword.get(opts, :namespace)),
         :ok            <- validate_unix_socket(Keyword.get(opts, :unix_socket)),
         :ok            <- (case validate_path(mount) do :ok -> :ok; _ -> {:error, {:invalid_option, :mount}} end),
         :ok            <- (case validate_path(name) do :ok -> :ok; _ -> {:error, {:invalid_option, :name}} end),
         {:ok, auth_validated} <- validate_auth(auth_raw) do
      state = %{
        address:     address,
        mount:       mount,
        name:        name,
        token:       token,
        namespace:   Keyword.get(opts, :namespace),
        unix_socket: Keyword.get(opts, :unix_socket),
        agent_mode: Keyword.get(opts, :agent_mode, false),
        req_options: Keyword.get(opts, :req_options, [])
      }
      base_req = HTTP.base_request(Map.to_list(state))

      with {:ok, auth_state} <- AuthDispatcher.init(auth_validated, base_req) do
        {:ok, state |> Map.put(:base_req, base_req) |> Map.put(:auth, auth_state)}
      end
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(%{auth: auth, base_req: base_req} = state) when not is_nil(auth) do
    case AuthDispatcher.ensure_fresh(auth, base_req) do
      {:ok, fresh_req, new_auth} -> do_load(fresh_req, %{state | auth: new_auth})
      {:error, reason} -> {:error, reason, state}
    end
  end
  def load(state), do: do_load(state.base_req, state)

  defp do_load(base_req, state) do
    case HTTP.get(base_req, "/v1/#{state.mount}/keys/#{state.name}") do
      {:ok, body} ->
        data    = body["data"]
        version = data["latest_version"]
        meta    = %{
          version:                version,
          key_type:               data["type"],
          min_decryption_version: data["min_decryption_version"]
        }
        {:ok, Jason.encode!(data), meta, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl RotatingSecrets.Source
  def subscribe_changes(_state), do: :not_supported

  @impl RotatingSecrets.Source
  def handle_change_notification(_msg, _state), do: :ignored

  @impl RotatingSecrets.Source
  def terminate(_state), do: :ok

end
