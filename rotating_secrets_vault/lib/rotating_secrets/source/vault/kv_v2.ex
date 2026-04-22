defmodule RotatingSecrets.Source.Vault.KvV2 do
  @moduledoc """
  Vault KV secrets engine v2 source for `RotatingSecrets`.

  Reads versioned secrets from `GET /v1/{mount}/data/{path}`.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — KV v2 mount path, e.g. `"secret"`. Required.
    * `:path` — Secret path within the mount, e.g. `"myapp/db"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:key` — field name to extract from the KV data map, e.g. `"value"`. Defaults to `"value"`.
    * `:namespace` — Vault Enterprise namespace (non-empty binary). Optional.
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP
  import RotatingSecrets.Source.Vault.Opts,
    only: [fetch_required_string: 2, validate_namespace: 1, validate_path: 1]

  @doc """
  Validates required options and builds the initial request configuration.

  Returns `{:ok, state}` on success, or `{:error, {:invalid_option, key}}` when
  a required option is missing or has an invalid type.

  ## Examples

      RotatingSecrets.register(:db_password,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: "http://127.0.0.1:8200",
          mount: "secret",
          path: "myapp/db",
          token: System.fetch_env!("VAULT_TOKEN")
        ]
      )
  """
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  @impl RotatingSecrets.Source
  def init(opts) do
    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount} <- fetch_required_string(opts, :mount),
         {:ok, path} <- fetch_required_string(opts, :path),
         {:ok, token} <- fetch_required_string(opts, :token),
         :ok <- validate_namespace(Keyword.get(opts, :namespace)),
         :ok <- (case validate_path(mount) do :ok -> :ok; _ -> {:error, {:invalid_option, :mount}} end),
         :ok <- (case validate_path(path) do :ok -> :ok; _ -> {:error, {:invalid_option, :path}} end) do
      state = %{
        address: address,
        mount: mount,
        path: path,
        token: token,
        key: Keyword.get(opts, :key, "value"),
        namespace: Keyword.get(opts, :namespace),
        req_options: Keyword.get(opts, :req_options, [])
      }
      {:ok, Map.put(state, :base_req, HTTP.base_request(Map.to_list(state)))}
    end
  end

  @doc """
  Fetches the current secret value from the Vault KV v2 endpoint.

  Returns `{:ok, value, meta, state}` on success, where `meta` contains
  `:version`, `:content_hash`, and optionally `:ttl_seconds`. Returns
  `{:error, reason, state}` on failure.
  """
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  @impl RotatingSecrets.Source
  def load(state) do
    url_path = "/v1/#{state.mount}/data/#{state.path}"

    case HTTP.get(state.base_req, url_path) do
      {:ok, body} ->
        material = get_in(body, ["data", "data", state.key])
        version = get_in(body, ["data", "metadata", "version"])
        custom_meta = get_in(body, ["data", "metadata", "custom_metadata"]) || %{}
        ttl_seconds = parse_ttl(custom_meta["ttl_seconds"])

        cond do
          is_nil(material) ->
            {:error, :not_found, state}

          not is_binary(material) ->
            {:error, {:invalid_value, material}, state}

          true ->
            meta =
              %{version: version, content_hash: sha256_hex(material)}
              |> then(fn m ->
                if ttl_seconds, do: Map.put(m, :ttl_seconds, ttl_seconds), else: m
              end)

            {:ok, material, meta, state}
        end

      {:error, :vault_secret_not_found} ->
        {:error, :not_found, state}

      {:error, :vault_auth_error} ->
        {:error, :forbidden, state}

      {:error, reason}
      when reason in [
             :vault_connection_refused,
             :vault_timeout,
             :vault_tls_error,
             :vault_unexpected_error
           ] ->
        {:error, {:connection_error, reason}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc """
  Vault KV v2 does not support push-based change notifications.

  Always returns `:not_supported`; the registry will fall back to polling.
  """
  @spec subscribe_changes(map()) :: :not_supported
  @impl RotatingSecrets.Source
  def subscribe_changes(_state), do: :not_supported

  @doc """
  Ignores all incoming change notification messages.

  Because `subscribe_changes/1` returns `:not_supported`, this callback
  should never be invoked in practice.
  """
  @spec handle_change_notification(term(), map()) :: :ignored
  @impl RotatingSecrets.Source
  def handle_change_notification(_msg, _state), do: :ignored

  @doc """
  Cleans up any resources held by this source.

  This source holds no external connections or processes, so this is a no-op.
  """
  @spec terminate(map()) :: :ok
  @impl RotatingSecrets.Source
  def terminate(_state), do: :ok

  defp parse_ttl(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_ttl(n) when is_integer(n) and n > 0, do: n
  defp parse_ttl(_), do: nil

  defp sha256_hex(data) do
    hash = :crypto.hash(:sha256, data)
    Base.encode16(hash, case: :lower)
  end
end
