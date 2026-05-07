defmodule RotatingSecrets.Source.Scaleway.Secret do
  @moduledoc """
  Scaleway Secret Manager source for `RotatingSecrets`.

  Reads versioned secrets from the Scaleway Secret Manager API using a two-step
  lookup: first resolving the secret by name within a project, then fetching the
  current version payload.

  ## Options

    * `:secret_key` — Scaleway API secret key (`X-Auth-Token`). Required.
    * `:project_id` — Scaleway project UUID. Required.
    * `:region` — Scaleway region, e.g. `"fr-par"`, `"nl-ams"`, `"pl-waw"`. Required.
    * `:name` — Secret name, e.g. `"my-api-key"`. Required.
    * `:ttl_seconds` — Polling interval in seconds (positive integer). Required.
      Scaleway has no native TTL; this value drives the `rotating_secrets` refresh schedule.
    * `:path` — Secret path prefix, e.g. `"/my-app/"`. Optional, defaults to `"/"`.
    * `:key` — Field name to extract from a JSON-encoded payload, e.g. `"password"`.
      Optional. When set, the payload is JSON-decoded and the named key is returned.
    * `:req_options` — Keyword list merged into `Req.new/1`. For test injection only.
  """

  @behaviour RotatingSecrets.Source

  import RotatingSecrets.Source.Scaleway.Opts,
    only: [
      fetch_required_string: 2,
      fetch_required_positive_integer: 2,
      validate_name: 1,
      validate_path: 1,
      validate_region: 1,
      validate_key: 1
    ]

  alias RotatingSecrets.Source.Scaleway.HTTP

  @doc """
  Validates required options and builds the initial request configuration.

  Returns `{:ok, state}` on success, or `{:error, {:invalid_option, key}}` when
  a required option is missing or has an invalid type.

  ## Examples

      RotatingSecrets.register(:db_password,
        source: RotatingSecrets.Source.Scaleway.Secret,
        source_opts: [
          secret_key: System.fetch_env!("SCW_SECRET_KEY"),
          project_id: System.fetch_env!("SCW_DEFAULT_PROJECT_ID"),
          region: "fr-par",
          name: "db-password",
          ttl_seconds: 300
        ]
      )
  """
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  @impl RotatingSecrets.Source
  def init(opts) do
    with {:ok, secret_key} <- fetch_required_string(opts, :secret_key),
         {:ok, project_id} <- fetch_required_string(opts, :project_id),
         {:ok, name} <- fetch_required_string(opts, :name),
         {:ok, region} <- fetch_required_string(opts, :region),
         :ok <- validate_name(name),
         :ok <- validate_region(region),
         {:ok, ttl_seconds} <- fetch_required_positive_integer(opts, :ttl_seconds),
         :ok <- validate_path(Keyword.get(opts, :path)),
         :ok <- validate_key(Keyword.get(opts, :key)) do
      state = %{
        secret_key: secret_key,
        project_id: project_id,
        name: name,
        region: region,
        path: Keyword.get(opts, :path, "/"),
        ttl_seconds: ttl_seconds,
        key: Keyword.get(opts, :key),
        req_options: Keyword.get(opts, :req_options, []),
        secret_id: nil
      }

      {:ok, Map.put(state, :base_req, HTTP.base_request(Map.to_list(state)))}
    end
  end

  @doc """
  Fetches the current secret value from the Scaleway Secret Manager API.

  Uses a two-step lookup: first resolves the secret UUID by name (caching the result
  in state for subsequent calls), then fetches the current version payload.

  Returns `{:ok, value, meta, state}` on success, where `meta` contains
  `:version` (revision integer), `:content_hash`, and `:ttl_seconds`.
  Returns `{:error, reason, state}` on failure.
  """
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, term(), map()}
  @impl RotatingSecrets.Source
  def load(state) do
    case resolve_secret_id(state) do
      {:ok, secret_id, new_state} ->
        fetch_version(secret_id, new_state)

      {:error, reason, new_state} ->
        {:error, reason, new_state}
    end
  end

  @doc """
  Scaleway Secret Manager does not support push-based change notifications.

  Always returns `:not_supported`; the registry will fall back to polling.
  """
  @spec subscribe_changes(map()) :: :not_supported
  @impl RotatingSecrets.Source
  def subscribe_changes(_state), do: :not_supported

  @doc """
  Ignores all incoming change notification messages.
  """
  @spec handle_change_notification(term(), map()) :: :ignored
  @impl RotatingSecrets.Source
  def handle_change_notification(_msg, _state), do: :ignored

  @doc """
  Cleans up any resources held by this source. This source is stateless, so this is a no-op.
  """
  @spec terminate(map()) :: :ok
  @impl RotatingSecrets.Source
  def terminate(_state), do: :ok

  defp fetch_version(secret_id, state) do
    path = "/secrets/#{secret_id}/versions/current/access"

    case HTTP.get(state.base_req, path) do
      {:ok, body} ->
        case decode_payload(body, state.key) do
          {:ok, material} ->
            meta = %{
              version: body["revision"],
              content_hash: sha256_hex(material),
              ttl_seconds: state.ttl_seconds
            }

            {:ok, material, meta, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :scaleway_secret_not_found} ->
        # 404 on version access is transient -- version promotion race.
        # Invalidate cached secret_id so next load re-resolves.
        {:error, {:connection_error, :scaleway_version_not_found},
         Map.put(state, :secret_id, nil)}

      {:error, :scaleway_auth_error} ->
        {:error, :forbidden, state}

      {:error, :scaleway_rate_limited} ->
        {:error, :scaleway_rate_limited, state}

      {:error, :scaleway_server_error} ->
        {:error, :scaleway_server_error, state}

      {:error, reason} ->
        {:error, {:connection_error, reason}, state}
    end
  end

  defp resolve_secret_id(%{secret_id: id} = state) when not is_nil(id), do: {:ok, id, state}

  defp resolve_secret_id(state) do
    encoded_name = URI.encode_www_form(state.name)
    encoded_path = URI.encode_www_form(state.path)
    path = "/secrets?name=#{encoded_name}&path=#{encoded_path}&project_id=#{state.project_id}"

    case HTTP.get(state.base_req, path) do
      {:ok, %{"secrets" => [%{"id" => secret_id} | _]}} ->
        {:ok, secret_id, Map.put(state, :secret_id, secret_id)}

      {:ok, %{"secrets" => []}} ->
        {:error, :not_found, state}

      {:ok, body} when not is_map_key(body, "secrets") ->
        {:error, {:connection_error, :malformed_response}, state}

      {:error, :scaleway_secret_not_found} ->
        {:error, :not_found, state}

      {:error, :scaleway_auth_error} ->
        {:error, :forbidden, state}

      {:error, :scaleway_rate_limited} ->
        {:error, :scaleway_rate_limited, state}

      {:error, :scaleway_server_error} ->
        {:error, :scaleway_server_error, state}

      {:error, reason} ->
        {:error, {:connection_error, reason}, state}
    end
  end

  defp decode_payload(body, nil) do
    case Base.decode64(body["payload"]) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_payload}
    end
  end

  defp decode_payload(body, key) do
    with {:ok, decoded} <- Base.decode64(body["payload"]),
         {:ok, json} when is_map(json) <- Jason.decode(decoded) do
      if Map.has_key?(json, key) do
        {:ok, json[key]}
      else
        {:error, :key_not_found}
      end
    else
      :error -> {:error, :invalid_payload}
      {:ok, _} -> {:error, :invalid_payload}
      {:error, _} -> {:error, :invalid_payload}
    end
  end

  defp sha256_hex(data) do
    hash = :crypto.hash(:sha256, data)
    Base.encode16(hash, case: :lower)
  end
end
