defmodule RotatingSecretsSops.Integration.SourceTest do
  use ExUnit.Case, async: false

  @moduletag :sops

  alias RotatingSecrets.Source.Sops

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    dir = Path.join(System.tmp_dir!(), "sops_int_src_#{System.unique_integer([:positive])}")
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

  # age-keygen writes the public key as a comment in the private key file:
  # "# public key: age1xxx"
  defp extract_pubkey!(key_file) do
    key_file
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "# public key:"))
    |> String.replace_prefix("# public key: ", "")
    |> String.trim()
  end

  # Encrypt a binary plaintext file using sops binary format.
  # sops 3.x encrypt writes the envelope to stdout; we capture and write to file.
  defp encrypt_raw!(plaintext, enc_file, pubkey, key_file) do
    src = enc_file <> ".plaintext"
    File.write!(src, plaintext)

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

  # Encrypt a JSON plaintext file using sops JSON format.
  # sops 3.x encrypt writes the envelope to stdout; we capture and write to file.
  defp encrypt_json!(json, enc_file, pubkey, key_file) do
    src = enc_file <> ".plaintext.json"
    File.write!(src, json)

    {envelope, 0} =
      System.cmd(
        "sops",
        ["encrypt", "--age", pubkey, "--input-type", "json", src],
        env: [{"SOPS_AGE_KEY_FILE", key_file}]
      )

    File.write!(enc_file, envelope)
    File.rm!(src)
    enc_file
  end

  # Build a cmd_fn that injects SOPS_AGE_KEY_FILE into the subprocess env.
  defp sops_cmd_fn(key_file) do
    fn bin, args, opts ->
      env = [{"SOPS_AGE_KEY_FILE", key_file}]
      System.cmd(bin, args, Keyword.put(opts, :env, env))
    end
  end

  # ---------------------------------------------------------------------------
  # :raw format
  # ---------------------------------------------------------------------------

  test "decrypts raw binary file", %{dir: dir, key_file: key_file, pubkey: pubkey} do
    plaintext = "my-super-secret-value"
    enc_file = encrypt_raw!(plaintext, Path.join(dir, "secret.enc"), pubkey, key_file)

    {:ok, state} =
      Sops.init(
        path: enc_file,
        mode: {:interval, 60_000},
        cmd_fn: sops_cmd_fn(key_file)
      )

    assert {:ok, ^plaintext, meta, _state} = Sops.load(state)
    assert meta.version == nil
    assert meta.ttl_seconds == nil
    assert is_binary(meta.content_hash)
    assert String.length(meta.content_hash) == 64
  end

  test "content hash is SHA-256 of the raw decrypted output", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    plaintext = "hash-check-value"
    enc_file = encrypt_raw!(plaintext, Path.join(dir, "hash.enc"), pubkey, key_file)

    {:ok, state} =
      Sops.init(path: enc_file, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))

    {:ok, _material, meta, _state} = Sops.load(state)

    expected = Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower)
    assert meta.content_hash == expected
  end

  test "content hash is stable across repeated loads", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    enc_file = encrypt_raw!("stable", Path.join(dir, "stable.enc"), pubkey, key_file)

    {:ok, state} =
      Sops.init(path: enc_file, mode: {:interval, 60_000}, cmd_fn: sops_cmd_fn(key_file))

    {:ok, _, meta1, state} = Sops.load(state)
    {:ok, _, meta2, _state} = Sops.load(state)

    assert meta1.content_hash == meta2.content_hash
  end

  # ---------------------------------------------------------------------------
  # :json format
  # ---------------------------------------------------------------------------

  test "decrypts JSON file and returns raw JSON binary", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    json = ~s({"password":"top-secret","user":"admin"})
    enc_file = encrypt_json!(json, Path.join(dir, "config.json"), pubkey, key_file)

    {:ok, state} =
      Sops.init(
        path: enc_file,
        mode: {:interval, 60_000},
        format: :json,
        cmd_fn: sops_cmd_fn(key_file)
      )

    assert {:ok, material, _meta, _state} = Sops.load(state)
    decoded = Jason.decode!(material)
    assert decoded["password"] == "top-secret"
    assert decoded["user"] == "admin"
  end

  # ---------------------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------------------

  test "returns :not_found for a non-existent file" do
    {:ok, state} =
      Sops.init(
        path: "/tmp/sops_int_nonexistent_#{System.unique_integer([:positive])}.enc",
        mode: {:interval, 60_000}
      )

    assert {:error, :not_found, _state} = Sops.load(state)
  end

  test "returns {:sops_error, code, _} for a corrupt file", %{dir: dir, key_file: key_file} do
    corrupt = Path.join(dir, "corrupt.enc")
    File.write!(corrupt, ~s({"not": "a valid sops file"}))

    {:ok, state} =
      Sops.init(
        path: corrupt,
        mode: {:interval, 60_000},
        cmd_fn: sops_cmd_fn(key_file)
      )

    assert {:error, {:sops_error, _, _}, _state} = Sops.load(state)
  end

  # ---------------------------------------------------------------------------
  # sops_args pass-through
  # ---------------------------------------------------------------------------

  test "sops_args are forwarded to the sops subprocess", %{
    dir: dir,
    key_file: key_file,
    pubkey: pubkey
  } do
    plaintext = "args-passthrough"
    enc_file = encrypt_raw!(plaintext, Path.join(dir, "args.enc"), pubkey, key_file)

    # Use --config pointing to an empty config file: a benign arg that exercises
    # the passthrough without mixing log output into the decrypted payload.
    config_file = Path.join(dir, ".sops.yaml")
    File.write!(config_file, "")

    {:ok, state} =
      Sops.init(
        path: enc_file,
        mode: {:interval, 60_000},
        sops_args: ["--config", config_file],
        cmd_fn: sops_cmd_fn(key_file)
      )

    assert {:ok, ^plaintext, _meta, _state} = Sops.load(state)
  end
end
