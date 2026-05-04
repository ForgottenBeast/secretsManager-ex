defmodule RotatingSecretsSops.Integration.TransitTest do
  use ExUnit.Case, async: false

  @moduletag :sops

  alias RotatingSecrets.Source.Sops.Transit
  alias RotatingSecrets.Source.Sops.Transit.Operations

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    dir = Path.join(System.tmp_dir!(), "sops_int_transit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    key_file = Path.join(dir, "age_key.txt")
    {_, 0} = System.cmd("age-keygen", ["-o", key_file])

    pubkey = extract_pubkey!(key_file)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, key_file: key_file, pubkey: pubkey}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp extract_pubkey!(key_file) do
    key_file
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "# public key:"))
    |> String.replace_prefix("# public key: ", "")
    |> String.trim()
  end

  # sops 3.x encrypt writes the envelope to stdout; we capture and write to file.
  defp encrypt_key!(key_bytes, enc_file, pubkey, key_file) do
    src = enc_file <> ".raw"
    File.write!(src, key_bytes)

    {envelope, 0} =
      System.cmd(
        "sops",
        ["encrypt", "--age", pubkey, "--input-type", "binary", "--output-type", "binary", src],
        env: [{"SOPS_AGE_KEY_FILE", key_file}]
      )

    File.write!(enc_file, envelope)
    File.rm!(src)
    enc_file
  end

  defp sops_cmd_fn(key_file) do
    fn bin, args, opts ->
      env = [{"SOPS_AGE_KEY_FILE", key_file}]
      System.cmd(bin, args, Keyword.put(opts, :env, env))
    end
  end

  # ---------------------------------------------------------------------------
  # Transit.load/1 — key material recovery
  # ---------------------------------------------------------------------------

  test "recovers exact 32-byte key material from sops-encrypted key file", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    raw_key = :crypto.strong_rand_bytes(32)
    enc_file = encrypt_key!(raw_key, Path.join(dir, "key.enc"), pubkey, key_file)

    {:ok, state} =
      Transit.init(
        path: enc_file,
        mode: {:interval, 60_000},
        cmd_fn: sops_cmd_fn(key_file)
      )

    assert {:ok, ^raw_key, meta, _state} = Transit.load(state)
    assert meta.key_length == 32
    assert meta.version == nil
    assert meta.ttl_seconds == nil
    assert is_binary(meta.content_hash)
  end

  test "returns :invalid_key_length when decrypted file is not 32 bytes", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    short_key = :crypto.strong_rand_bytes(16)
    enc_file = encrypt_key!(short_key, Path.join(dir, "short_key.enc"), pubkey, key_file)

    {:ok, state} =
      Transit.init(
        path: enc_file,
        mode: {:interval, 60_000},
        cmd_fn: sops_cmd_fn(key_file)
      )

    assert {:error, :invalid_key_length, _state} = Transit.load(state)
  end

  test "returns :not_found for a non-existent key file" do
    {:ok, state} =
      Transit.init(
        path: "/tmp/sops_int_transit_nonexistent_#{System.unique_integer([:positive])}.enc",
        mode: {:interval, 60_000}
      )

    assert {:error, :not_found, _state} = Transit.load(state)
  end

  # ---------------------------------------------------------------------------
  # Operations round-trip with key recovered from sops
  # ---------------------------------------------------------------------------

  test "Operations.encrypt/2 + decrypt/2 round-trip with sops-recovered key", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    raw_key = :crypto.strong_rand_bytes(32)
    enc_file = encrypt_key!(raw_key, Path.join(dir, "ops_key.enc"), pubkey, key_file)

    {:ok, state} =
      Transit.init(path: enc_file, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))

    {:ok, key, _meta, _state} = Transit.load(state)

    plaintext = "the quick brown fox"
    {:ok, ciphertext} = Operations.encrypt(key, plaintext)
    {:ok, recovered} = Operations.decrypt(key, ciphertext)

    assert recovered == plaintext
  end

  test "each encryption of the same plaintext produces a different ciphertext (random IV)", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    raw_key = :crypto.strong_rand_bytes(32)
    enc_file = encrypt_key!(raw_key, Path.join(dir, "iv_key.enc"), pubkey, key_file)

    {:ok, state} =
      Transit.init(path: enc_file, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))

    {:ok, key, _meta, _state} = Transit.load(state)

    plaintext = "same plaintext every time"
    {:ok, ct1} = Operations.encrypt(key, plaintext)
    {:ok, ct2} = Operations.encrypt(key, plaintext)

    refute ct1 == ct2
  end

  test "decryption fails when ciphertext is tampered", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    raw_key = :crypto.strong_rand_bytes(32)
    enc_file = encrypt_key!(raw_key, Path.join(dir, "tamper_key.enc"), pubkey, key_file)

    {:ok, state} =
      Transit.init(path: enc_file, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))

    {:ok, key, _meta, _state} = Transit.load(state)

    {:ok, ciphertext} = Operations.encrypt(key, "sensitive data")

    # Flip a bit in the ciphertext body (after the 12-byte IV, before the 16-byte tag)
    <<iv::binary-12, body::binary>> = ciphertext
    <<first_byte, rest::binary>> = body
    tampered = iv <> <<Bitwise.bxor(first_byte, 0xFF)>> <> rest

    assert {:error, :decryption_failed} = Operations.decrypt(key, tampered)
  end

  # ---------------------------------------------------------------------------
  # Key rotation: new key decrypts new ciphertext, fails on old
  # ---------------------------------------------------------------------------

  test "ciphertext encrypted with one key cannot be decrypted with a different key", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    key1 = :crypto.strong_rand_bytes(32)
    key2 = :crypto.strong_rand_bytes(32)

    enc1 = encrypt_key!(key1, Path.join(dir, "k1.enc"), pubkey, key_file)
    enc2 = encrypt_key!(key2, Path.join(dir, "k2.enc"), pubkey, key_file)

    {:ok, s1} = Transit.init(path: enc1, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))
    {:ok, s2} = Transit.init(path: enc2, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))

    {:ok, loaded_key1, _meta, _state} = Transit.load(s1)
    {:ok, loaded_key2, _meta, _state} = Transit.load(s2)

    {:ok, ciphertext} = Operations.encrypt(loaded_key1, "secret message")
    assert {:error, :decryption_failed} = Operations.decrypt(loaded_key2, ciphertext)
  end
end
