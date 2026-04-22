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
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP
  import RotatingSecrets.Source.Vault.Opts, only: [fetch_required_string: 2, validate_namespace: 1]

  @impl RotatingSecrets.Source
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount} <- fetch_required_string(opts, :mount),
         {:ok, path} <- fetch_required_string(opts, :path),
         {:ok, token} <- fetch_required_string(opts, :token),
         {:ok, key} <- fetch_required_string(opts, :key),
         :ok <- validate_namespace(Keyword.get(opts, :namespace)) do
      {:ok,
       %{
         address: address,
         mount: mount,
         path: path,
         token: token,
         key: key,
         namespace: Keyword.get(opts, :namespace),
         req_options: Keyword.get(opts, :req_options, [])
       }}
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(state) do
    url_path = "/v1/#{state.mount}/#{state.path}"

    case state |> Map.to_list() |> HTTP.base_request() |> HTTP.get(url_path) do
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
