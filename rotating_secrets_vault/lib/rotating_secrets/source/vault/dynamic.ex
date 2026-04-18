defmodule RotatingSecrets.Source.Vault.Dynamic do
  @moduledoc """
  Vault dynamic secrets source for `RotatingSecrets`.

  Reads dynamic secrets (database, AWS, PKI, etc.) from `GET /v1/{mount}/creds/{path}`.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — Secrets engine mount path, e.g. `"database"`. Required.
    * `:path` — Role path within the mount, e.g. `"my-role"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:key` — The key name within the data map to read as material. Optional;
      when absent the full `data` object is JSON-encoded as material.
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
         key: Keyword.get(opts, :key),
         namespace: Keyword.get(opts, :namespace),
         req_options: Keyword.get(opts, :req_options, [])
       }}
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(state) do
    url_path = "/v1/#{state.mount}/creds/#{state.path}"

    case state |> Map.to_list() |> HTTP.base_request() |> HTTP.get(url_path) do
      {:ok, body} ->
        material = extract_material(body, state.key)
        meta = build_meta(body)
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

  defp extract_material(body, nil), do: Jason.encode!(body["data"])
  defp extract_material(body, key), do: get_in(body, ["data", key])

  defp build_meta(body) do
    lease_id = body["lease_id"]
    lease_duration = body["lease_duration"] || 0

    %{version: nil}
    |> maybe_add_lease_id(lease_id)
    |> maybe_add_lease_duration(lease_duration)
  end

  defp maybe_add_lease_id(meta, nil), do: meta
  defp maybe_add_lease_id(meta, lease_id), do: Map.put(meta, :lease_id, lease_id)

  defp maybe_add_lease_duration(meta, 0), do: meta
  defp maybe_add_lease_duration(meta, duration), do: Map.put(meta, :lease_duration_ms, duration * 1_000)

  defp fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp validate_namespace(nil), do: :ok
  defp validate_namespace(ns) when is_binary(ns) and byte_size(ns) > 0, do: :ok
  defp validate_namespace(_), do: {:error, {:invalid_option, :namespace}}
end
