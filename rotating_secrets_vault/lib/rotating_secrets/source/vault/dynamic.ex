defmodule RotatingSecrets.Source.Vault.Dynamic do
  @moduledoc """
  Vault dynamic secrets source for `RotatingSecrets`.

  Reads dynamic secrets (database, AWS, etc.) from `GET /v1/{mount}/creds/{path}`.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — Secrets engine mount path, e.g. `"database"`. Required.
    * `:path` — Role path within the mount, e.g. `"my-role"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:key` — The key name within the data map to read as material. Optional;
      when absent the full `data` object is JSON-encoded as material.
    * `:namespace` — Vault Enterprise namespace (non-empty binary). Optional.
    * `:unix_socket` — path to a UNIX domain socket (e.g. `"/run/bao.sock"`). When set, all connections route through this socket. Set `address:` to `"http://localhost"` when using this option. Optional.
    * `:agent_mode` — when true, token is not required (agent handles auth). Default false. Optional.
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.

  ## Lease revocation

  `terminate/1` revokes the active lease on shutdown. This is best-effort only:
  if the OTP process is killed with `:kill`, `terminate/1` does not run.
  Configure Vault's `default_lease_ttl` and `max_lease_ttl` as server-side safety nets.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP
  import RotatingSecrets.Source.Vault.Opts,
    only: [fetch_required_string: 2, fetch_optional_token: 1, validate_namespace: 1, validate_path: 1, validate_unix_socket: 1]

  @impl RotatingSecrets.Source
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount} <- fetch_required_string(opts, :mount),
         {:ok, path} <- fetch_required_string(opts, :path),
         {:ok, token} <- fetch_optional_token(opts),
         :ok <- validate_namespace(Keyword.get(opts, :namespace)),
         :ok <- validate_unix_socket(Keyword.get(opts, :unix_socket)),
         :ok <- (case validate_path(mount) do :ok -> :ok; _ -> {:error, {:invalid_option, :mount}} end),
         :ok <- (case validate_path(path) do :ok -> :ok; _ -> {:error, {:invalid_option, :path}} end) do
      state = %{
        address: address,
        mount: mount,
        path: path,
        token: token,
        key: Keyword.get(opts, :key),
        namespace: Keyword.get(opts, :namespace),
        unix_socket: Keyword.get(opts, :unix_socket),
        agent_mode: Keyword.get(opts, :agent_mode, false),
        req_options: Keyword.get(opts, :req_options, []),
        lease_id: nil,
        current_material: nil
      }

      {:ok, Map.put(state, :base_req, HTTP.base_request(Map.to_list(state)))}
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(state) do
    if state.lease_id != nil do
      renew_req = Req.merge(state.base_req, receive_timeout: 5000)

      case HTTP.put(renew_req, "/v1/sys/leases/renew", %{"lease_id" => state.lease_id}) do
        {:ok, renewal_body} ->
          new_ttl = renewal_body["lease_duration"]
          new_meta = %{
            version: nil,
            lease_id: state.lease_id,
            lease_duration_ms: new_ttl * 1_000,
            ttl_seconds: new_ttl
          }

          {:ok, state.current_material, new_meta, state}

        {:error, _} ->
          fetch_new_credentials(state)
      end
    else
      fetch_new_credentials(state)
    end
  end

  @impl RotatingSecrets.Source
  def subscribe_changes(_state), do: :not_supported

  @impl RotatingSecrets.Source
  def handle_change_notification(_msg, _state), do: :ignored

  @impl RotatingSecrets.Source
  def terminate(state) do
    if state.lease_id do
      try do
        req = Req.merge(state.base_req, receive_timeout: 2000)
        HTTP.put(req, "/v1/sys/leases/revoke", %{"lease_id" => state.lease_id})
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp fetch_new_credentials(state) do
    url_path = "/v1/#{state.mount}/creds/#{state.path}"

    case HTTP.get(state.base_req, url_path) do
      {:ok, body} ->
        material = extract_material(body, state.key)
        meta = build_meta(body)
        # current_material cached here for lease renewal (dynamic.ex load/1 renewal path); protected by Process.flag(:sensitive, true) set in Registry
        new_state = %{state | lease_id: body["lease_id"], current_material: material}
        {:ok, material, meta, new_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp extract_material(body, nil), do: Jason.encode!(body["data"])
  defp extract_material(body, key), do: get_in(body, ["data", key])

  defp build_meta(body) do
    lease_id = body["lease_id"]
    lease_duration = body["lease_duration"] || 0

    %{version: nil}
    |> maybe_add_lease_id(lease_id)
    |> maybe_add_lease_duration(lease_duration)
    |> maybe_add_ttl_seconds(lease_duration)
  end

  defp maybe_add_lease_id(meta, nil), do: meta
  defp maybe_add_lease_id(meta, ""), do: meta
  defp maybe_add_lease_id(meta, lease_id), do: Map.put(meta, :lease_id, lease_id)

  defp maybe_add_lease_duration(meta, 0), do: meta
  defp maybe_add_lease_duration(meta, duration), do: Map.put(meta, :lease_duration_ms, duration * 1_000)

  defp maybe_add_ttl_seconds(meta, 0), do: meta
  defp maybe_add_ttl_seconds(meta, duration), do: Map.put(meta, :ttl_seconds, duration)

end
