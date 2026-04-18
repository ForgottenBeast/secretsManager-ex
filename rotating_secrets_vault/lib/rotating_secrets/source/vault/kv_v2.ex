defmodule RotatingSecrets.Source.Vault.KvV2 do
  @moduledoc """
  Vault KV secrets engine v2 source for `RotatingSecrets`.

  Reads versioned secrets from `GET /v1/{mount}/data/{path}`.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — KV v2 mount path, e.g. `"secret"`. Required.
    * `:path` — Secret path within the mount, e.g. `"myapp/db"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:namespace` — Vault Enterprise namespace (non-empty binary). Optional.
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP

  @impl RotatingSecrets.Source
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount} <- fetch_required_string(opts, :mount),
         {:ok, path} <- fetch_required_string(opts, :path),
         {:ok, token} <- fetch_required_string(opts, :token),
         :ok <- validate_namespace(Keyword.get(opts, :namespace)) do
      {:ok,
       %{
         address: address,
         mount: mount,
         path: path,
         token: token,
         namespace: Keyword.get(opts, :namespace),
         req_options: Keyword.get(opts, :req_options, [])
       }}
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(state) do
    url_path = "/v1/#{state.mount}/data/#{state.path}"

    case state |> Map.to_list() |> HTTP.base_request() |> HTTP.get(url_path) do
      {:ok, body} ->
        material = get_in(body, ["data", "data"])
        version = get_in(body, ["data", "metadata", "version"])
        meta = %{version: version, content_hash: sha256_hex(material)}
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

  defp fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp validate_namespace(nil), do: :ok
  defp validate_namespace(ns) when is_binary(ns) and byte_size(ns) > 0, do: :ok
  defp validate_namespace(_), do: {:error, {:invalid_option, :namespace}}

  defp sha256_hex(data) do
    hash = :crypto.hash(:sha256, data)
    Base.encode16(hash, case: :lower)
  end
end
