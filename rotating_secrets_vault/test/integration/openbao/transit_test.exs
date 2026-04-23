defmodule RotatingSecretsVault.Integration.TransitTest do
  @moduledoc false
  use ExUnit.Case, async: false
  @moduletag :openbao

  alias RotatingSecrets.Secret

  setup_all do
    OpenBaoHelper.setup_transit_engine!()
    on_exit(fn -> OpenBaoHelper.teardown_transit_engine!() end)
    :ok
  end

  setup do
    name = :"transit_#{:erlang.unique_integer([:positive])}"
    key_name = "test-key-#{:erlang.unique_integer([:positive])}"
    OpenBaoHelper.create_transit_key!(key_name)
    on_exit(fn -> RotatingSecrets.deregister(name) end)
    {:ok, name: name, key_name: key_name}
  end

  test "load/1 returns version 1 as initial material", %{name: name, key_name: key_name} do
    {:ok, _} = register(name, key_name)
    {:ok, secret} = RotatingSecrets.current(name)
    material = Jason.decode!(Secret.expose(secret))
    assert material["latest_version"] == 1
  end

  test "load/1 returns incremented version after key rotation", %{name: name, key_name: key_name} do
    {:ok, _} = register(name, key_name)
    OpenBaoHelper.rotate_transit_key!("transit", key_name)
    name2 = :"transit_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name2) end)
    {:ok, _} = register(name2, key_name)
    {:ok, secret2} = RotatingSecrets.current(name2)
    material2 = Jason.decode!(Secret.expose(secret2))
    assert material2["latest_version"] == 2
  end

  test "two registrations on same key return same version", %{name: name1, key_name: key_name} do
    name2 = :"transit_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name2) end)
    {:ok, _} = register(name1, key_name)
    {:ok, _} = register(name2, key_name)
    {:ok, s1} = RotatingSecrets.current(name1)
    {:ok, s2} = RotatingSecrets.current(name2)
    v1 = Jason.decode!(Secret.expose(s1))["latest_version"]
    v2 = Jason.decode!(Secret.expose(s2))["latest_version"]
    assert v1 == v2
  end

  defp register(name, key_name) do
    RotatingSecrets.register(name,
      source: RotatingSecrets.Source.Vault.Transit,
      source_opts: [
        address: OpenBaoHelper.base_url(),
        token: OpenBaoHelper.root_token(),
        mount: "transit",
        name: key_name
      ]
    )
  end
end
