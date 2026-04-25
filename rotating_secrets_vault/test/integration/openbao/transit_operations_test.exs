defmodule RotatingSecretsVault.Integration.TransitOperationsTest do
  @moduledoc false
  use ExUnit.Case, async: false
  @moduletag :openbao

  alias RotatingSecrets.Source.Vault.HTTP
  alias RotatingSecrets.Source.Vault.Transit.Operations

  setup_all do
    OpenBaoHelper.setup_transit_engine!()
    on_exit(fn -> OpenBaoHelper.teardown_transit_engine!() end)
    :ok
  end

  setup do
    key_name = "ops-test-key-#{:erlang.unique_integer([:positive])}"
    {:ok, key_name: key_name}
  end

  defp base_req do
    HTTP.base_request(
      address: OpenBaoHelper.base_url(),
      token: OpenBaoHelper.root_token()
    )
  end

  test "create_key/3 is idempotent", %{key_name: key_name} do
    assert :ok = Operations.create_key(base_req(), "transit", key_name)
    assert :ok = Operations.create_key(base_req(), "transit", key_name)
  end

  test "encrypt/4 and decrypt/4 roundtrip", %{key_name: key_name} do
    :ok = Operations.create_key(base_req(), "transit", key_name)
    plaintext = "super secret data"
    assert {:ok, ciphertext} = Operations.encrypt(base_req(), "transit", key_name, plaintext)
    assert {:ok, ^plaintext} = Operations.decrypt(base_req(), "transit", key_name, ciphertext)
  end

  test "rotate_key/3 increments version", %{key_name: key_name} do
    :ok = Operations.create_key(base_req(), "transit", key_name)
    assert {:ok, v1} = Operations.rotate_key(base_req(), "transit", key_name)
    assert v1 >= 2
  end

  test "rewrap/4 produces new ciphertext after rotation", %{key_name: key_name} do
    :ok = Operations.create_key(base_req(), "transit", key_name)
    plaintext = "data to rewrap"
    {:ok, ct_v1} = Operations.encrypt(base_req(), "transit", key_name, plaintext)
    {:ok, _version} = Operations.rotate_key(base_req(), "transit", key_name)
    assert {:ok, ct_v2} = Operations.rewrap(base_req(), "transit", key_name, ct_v1)
    assert ct_v1 != ct_v2
    assert {:ok, ^plaintext} = Operations.decrypt(base_req(), "transit", key_name, ct_v2)
  end

  test "delete_key/3 removes the key", %{key_name: key_name} do
    :ok = Operations.create_key(base_req(), "transit", key_name)
    assert :ok = Operations.delete_key(base_req(), "transit", key_name)
    assert {:error, _} = Operations.encrypt(base_req(), "transit", key_name, "test")
  end
end
