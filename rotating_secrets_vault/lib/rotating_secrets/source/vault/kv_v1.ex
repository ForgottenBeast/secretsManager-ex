defmodule RotatingSecrets.Source.Vault.KvV1 do
  @moduledoc """
  Vault KV secrets engine v1 source for `RotatingSecrets`.

  Reads unversioned secrets from `GET /v1/{mount}/{path}`.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — KV v1 mount path, e.g. `"secret"`. Required.
    * `:path` — Secret path within the mount, e.g. `"myapp/db"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:key` — The key name within the data map to read. Required.
    * `:namespace` — Vault Enterprise namespace (non-empty binary). Optional.
    * `:unix_socket` — path to a UNIX domain socket (e.g. `"/run/bao.sock"`). When set, all connections route through this socket. Set `address:` to `"http://localhost"` when using this option. Optional.
    * `:agent_mode` — when true, token is not required (agent handles auth). Default false. Optional.
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.
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
         {:ok, mount} <- fetch_required_string(opts, :mount),
         {:ok, path} <- fetch_required_string(opts, :path),
         {:ok, token} <- fetch_optional_token(opts),
         {:ok, key} <- fetch_required_string(opts, :key),
         :ok <- validate_namespace(Keyword.get(opts, :namespace)),
         :ok <- validate_unix_socket(Keyword.get(opts, :unix_socket)),
         :ok <- (case validate_path(mount) do :ok -> :ok; _ -> {:error, {:invalid_option, :mount}} end),
         :ok <- (case validate_path(path) do :ok -> :ok; _ -> {:error, {:invalid_option, :path}} end),
         {:ok, auth_validated} <- validate_auth(auth_raw) do
      state = %{
        address: address,
        mount: mount,
        path: path,
        token: token,
        key: key,
        namespace: Keyword.get(opts, :namespace),
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
    url_path = "/v1/#{state.mount}/#{state.path}"

    case HTTP.get(base_req, url_path) do
      {:ok, body} ->
        material = get_in(body, ["data", state.key])
        meta = %{version: nil, content_hash: sha256_hex(material)}
        {:ok, material, meta, state}

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

  defp sha256_hex(data) do
    hash = :crypto.hash(:sha256, data)
    Base.encode16(hash, case: :lower)
  end

end
