defmodule RotatingSecrets.Source.Vault.Transit.Operations do
  @moduledoc """
  Stateless OpenBao/Vault Transit engine operations.

  Functions accept a `base_req` (`Req.Request.t()` built by `HTTP.base_request/1`)
  plus mount and key_name, and return tagged tuples.

  ## Operations

    * `create_key/3` — idempotent key creation (POST .../keys/{name}, 204/400 both ok)
    * `delete_key/3` — set deletion_allowed then DELETE key (idempotent)
    * `encrypt/4` — encrypt plaintext bytes, returns ciphertext string
    * `decrypt/4` — decrypt ciphertext string, returns plaintext bytes
    * `rotate_key/3` — rotate to next key version
    * `rewrap/4` — re-encrypt ciphertext under latest key version
  """

  alias RotatingSecrets.Source.Vault.HTTP

  @type base_req :: Req.Request.t()
  @type mount :: String.t()
  @type key_name :: String.t()

  @doc "Create (or ensure existence of) a Transit AES-256-GCM96 key. Idempotent."
  @spec create_key(base_req(), mount(), key_name()) :: :ok | {:error, atom()}
  def create_key(base_req, mount, key_name) do
    path = "/v1/#{mount}/keys/#{key_name}"
    case HTTP.post(base_req, path, %{"type" => "aes256-gcm96"}) do
      {:ok, _} -> :ok
      # 400 means key already exists — idempotent
      {:error, :vault_client_error} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete a Transit key. Sets deletion_allowed=true first. Idempotent."
  @spec delete_key(base_req(), mount(), key_name()) :: :ok | {:error, atom()}
  def delete_key(base_req, mount, key_name) do
    config_path = "/v1/#{mount}/keys/#{key_name}/config"
    delete_path = "/v1/#{mount}/keys/#{key_name}"
    with {:ok, _} <- HTTP.put(base_req, config_path, %{"deletion_allowed" => true}) do
      HTTP.delete(base_req, delete_path)
    end
  end

  @doc "Encrypt plaintext bytes with the org's Transit key. Returns ciphertext string."
  @spec encrypt(base_req(), mount(), key_name(), binary()) ::
          {:ok, ciphertext :: String.t()} | {:error, atom()}
  def encrypt(base_req, mount, key_name, plaintext) when is_binary(plaintext) do
    path = "/v1/#{mount}/encrypt/#{key_name}"
    case HTTP.post(base_req, path, %{"plaintext" => Base.encode64(plaintext)}) do
      {:ok, %{"data" => %{"ciphertext" => ct}}} -> {:ok, ct}
      {:ok, _} -> {:error, :vault_unexpected_error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Decrypt a ciphertext string. Returns plaintext bytes."
  @spec decrypt(base_req(), mount(), key_name(), String.t()) ::
          {:ok, plaintext :: binary()} | {:error, atom()}
  def decrypt(base_req, mount, key_name, ciphertext) when is_binary(ciphertext) do
    path = "/v1/#{mount}/decrypt/#{key_name}"
    case HTTP.post(base_req, path, %{"ciphertext" => ciphertext}) do
      {:ok, %{"data" => %{"plaintext" => pt_b64}}} -> {:ok, Base.decode64!(pt_b64)}
      {:ok, _} -> {:error, :vault_unexpected_error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rotate to the next key version. Returns {:ok, new_version}."
  @spec rotate_key(base_req(), mount(), key_name()) ::
          {:ok, version :: pos_integer()} | {:error, atom()}
  def rotate_key(base_req, mount, key_name) do
    path = "/v1/#{mount}/keys/#{key_name}/rotate"
    case HTTP.post(base_req, path, %{}) do
      {:ok, _} ->
        meta_path = "/v1/#{mount}/keys/#{key_name}"
        case HTTP.get(base_req, meta_path) do
          {:ok, %{"data" => %{"latest_version" => v}}} -> {:ok, v}
          {:ok, _} -> {:ok, 1}
          {:error, reason} -> {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Re-encrypt ciphertext under the latest key version."
  @spec rewrap(base_req(), mount(), key_name(), String.t()) ::
          {:ok, new_ciphertext :: String.t()} | {:error, atom()}
  def rewrap(base_req, mount, key_name, ciphertext) when is_binary(ciphertext) do
    path = "/v1/#{mount}/rewrap/#{key_name}"
    case HTTP.post(base_req, path, %{"ciphertext" => ciphertext}) do
      {:ok, %{"data" => %{"ciphertext" => new_ct}}} -> {:ok, new_ct}
      {:ok, _} -> {:error, :vault_unexpected_error}
      {:error, reason} -> {:error, reason}
    end
  end
end
