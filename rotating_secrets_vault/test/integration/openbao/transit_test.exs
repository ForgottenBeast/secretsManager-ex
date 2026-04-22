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
    on_exit(fn -> RotatingSecrets.deregister(name) end)
    {:ok, name: name}
  end

  test "load/1 returns version 1 as initial material", %{name: name} do
    {:ok, _} = register(name)
    {:ok, secret} = RotatingSecrets.current(name)
    material = Jason.decode!(Secret.expose(secret))
    assert material["latest_version"] == 1
  end

  test "load/1 returns incremented version after key rotation", %{name: name} do
    {:ok, _} = register(name)
    OpenBaoHelper.rotate_transit_key!("transit", "test-key")
    name2 = :"transit_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name2) end)
    {:ok, _} = register(name2)
    {:ok, secret2} = RotatingSecrets.current(name2)
    material2 = Jason.decode!(Secret.expose(secret2))
    assert material2["latest_version"] == 2
  end

  test "two registrations on same key return same version", %{name: name1} do
    name2 = :"transit_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RotatingSecrets.deregister(name2) end)
    {:ok, _} = register(name1)
    {:ok, _} = register(name2)
    {:ok, s1} = RotatingSecrets.current(name1)
    {:ok, s2} = RotatingSecrets.current(name2)
    v1 = Jason.decode!(Secret.expose(s1))["latest_version"]
    v2 = Jason.decode!(Secret.expose(s2))["latest_version"]
    assert v1 == v2
  end

  defp register(name) do
    RotatingSecrets.register(name,
      source: RotatingSecrets.Source.Vault.Transit,
      source_opts: [
        address: OpenBaoHelper.base_url(),
        token: OpenBaoHelper.root_token(),
        mount: "transit",
        name: "test-key"
      ]
    )
  end
end
