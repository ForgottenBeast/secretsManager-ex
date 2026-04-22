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
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.

  ## No TTL

  Transit keys have no inherent TTL. The Registry polls on `fallback_interval_ms`.
  Set a short `fallback_interval_ms` in `register/2` for prompt rotation detection.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP
  import RotatingSecrets.Source.Vault.Opts, only: [fetch_required_string: 2, validate_namespace: 1]

  @impl RotatingSecrets.Source
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount}   <- fetch_required_string(opts, :mount),
         {:ok, name}    <- fetch_required_string(opts, :name),
         {:ok, token}   <- fetch_required_string(opts, :token),
         :ok            <- validate_namespace(Keyword.get(opts, :namespace)) do
      state = %{
        address:     address,
        mount:       mount,
        name:        name,
        token:       token,
        namespace:   Keyword.get(opts, :namespace),
        req_options: Keyword.get(opts, :req_options, [])
      }
      {:ok, Map.put(state, :base_req, HTTP.base_request(Map.to_list(state)))}
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(state) do
    case HTTP.get(state.base_req, "/v1/#{state.mount}/keys/#{state.name}") do
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
