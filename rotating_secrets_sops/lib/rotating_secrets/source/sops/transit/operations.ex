defmodule RotatingSecrets.Source.Sops.Transit.Operations do
  @moduledoc """
  Stateless AES-256-GCM (AEAD) encrypt/decrypt operations.

  Key material is obtained by loading a `RotatingSecrets.Source.Sops.Transit`
  secret and calling `RotatingSecrets.Secret.expose/1`.

  ## Ciphertext envelope

  ```
  <<iv :: binary-size(12), ciphertext :: binary, tag :: binary-size(16)>>
  ```

  - **IV**: 12-byte random nonce, generated fresh for every `encrypt/2` call.
  - **Ciphertext**: AES-256-GCM encrypted payload.
  - **Tag**: 128-bit authentication tag (full GCM tag; no truncation).
  - **AAD**: empty binary. This is intentional — context-binding can be added
    in a future revision without breaking existing ciphertext.

  The tag-at-end layout matches the convention used by libsodium and TLS 1.3.

  ## Security properties

  - Cipher: AES-256-GCM only. No fallback or alternative path exists.
  - IV is never reused within a key lifetime (12-byte random provides
    negligible collision probability for any realistic message volume per key).
  - Authentication is unconditional — `decrypt/2` returns
    `{:error, :decryption_failed}` before exposing any bytes on tag mismatch.
  - Key material must be exactly 32 bytes; shorter or longer keys are rejected
    with `{:error, :invalid_key_length}`.

  ## Example

      secret   = RotatingSecrets.borrow(:enc_key)
      key      = RotatingSecrets.Secret.expose(secret)

      {:ok, ct} = Operations.encrypt(key, "my plaintext")
      {:ok, pt} = Operations.decrypt(key, ct)
  """

  @min_ciphertext_bytes 12 + 16

  @doc """
  Encrypts `plaintext` using AES-256-GCM with a fresh random IV.

  Returns `{:ok, ciphertext}` where `ciphertext` is
  `<<iv::12, encrypted_payload::n, tag::16>>`.

  Returns `{:error, :invalid_key_length}` if `key` is not exactly 32 bytes.
  """
  @spec encrypt(key :: binary(), plaintext :: binary()) ::
          {:ok, ciphertext :: binary()} | {:error, :invalid_key_length}
  def encrypt(key, plaintext) when is_binary(key) and is_binary(plaintext) do
    if byte_size(key) != 32 do
      {:error, :invalid_key_length}
    else
      iv = :crypto.strong_rand_bytes(12)
      {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, <<>>, true)
      {:ok, iv <> ct <> tag}
    end
  end

  @doc """
  Decrypts a `ciphertext` produced by `encrypt/2`.

  Returns `{:ok, plaintext}` on success.

  Returns:
  - `{:error, :invalid_key_length}` — key is not 32 bytes.
  - `{:error, :invalid_ciphertext}` — envelope is too short or malformed.
  - `{:error, :decryption_failed}` — authentication tag mismatch; the
    ciphertext was tampered with, the wrong key was supplied, or the data
    is corrupt.
  """
  @spec decrypt(key :: binary(), ciphertext :: binary()) ::
          {:ok, plaintext :: binary()}
          | {:error, :invalid_key_length | :invalid_ciphertext | :decryption_failed}
  def decrypt(key, ciphertext) when is_binary(key) and is_binary(ciphertext) do
    cond do
      byte_size(key) != 32 ->
        {:error, :invalid_key_length}

      byte_size(ciphertext) < @min_ciphertext_bytes ->
        {:error, :invalid_ciphertext}

      true ->
        <<iv::binary-size(12), rest::binary>> = ciphertext
        ct_size = byte_size(rest) - 16
        <<ct::binary-size(ct_size), tag::binary-size(16)>> = rest

        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, <<>>, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
          :error -> {:error, :decryption_failed}
        end
    end
  end
end
