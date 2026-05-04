defmodule RotatingSecretsVault.Integration.CrossLangDynamicTest do
  use ExUnit.Case, async: false

  @moduletag :cross_lang_db

  alias RotatingSecrets.Secret

  setup_all do
    OpenBaoHelper.setup_database_engine!(OpenBaoHelper.pg_connection_url())
    on_exit(fn -> OpenBaoHelper.teardown_database_engine!() end)
    :ok
  end

  setup do
    binary_path = System.get_env("RUST_CONSUMER_BIN") || raise "RUST_CONSUMER_BIN not set"
    {rust_port_handle, rust_port} = RustConsumerHelper.start_server!(binary_path)
    RustConsumerHelper.wait_for_ready!(rust_port)

    name = :"cross_lang_dyn_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      RustConsumerHelper.stop_server!(rust_port_handle)
      RotatingSecrets.deregister(name)
    end)

    {:ok, rust_port: rust_port, name: name}
  end

  test "Dynamic credential pipeline reaches Rust consumer", %{rust_port: rust_port, name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.Dynamic,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          mount: "database",
          path: "test-role"
        ]
      )

    {:ok, sub_ref} = RotatingSecrets.subscribe(name)

    {:ok, s1} = RotatingSecrets.current(name)
    material_v1 = Secret.expose(s1)

    # Verify valid JSON with database credentials
    creds = Jason.decode!(material_v1)
    assert Map.has_key?(creds, "username")
    assert Map.has_key?(creds, "password")

    # Push to Rust consumer
    RustConsumerHelper.push_secret!(rust_port, material_v1, 1)
    assert %{"value" => ^material_v1, "version" => 1} = RustConsumerHelper.get_secret!(rust_port)

    # Wait for rotation event (lease renewal at ~20s, fired as rotation event by Registry).
    # NOTE: Dynamic lease renewal returns the SAME credentials — this is expected behavior.
    # The Registry fires a rotation event regardless, which is what we test here.
    assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, _}, 90_000

    {:ok, s2} = RotatingSecrets.current(name)
    material_v2 = Secret.expose(s2)

    # Push (potentially same) material with version 2
    RustConsumerHelper.push_secret!(rust_port, material_v2, 2)
    assert %{"value" => ^material_v2, "version" => 2} = RustConsumerHelper.get_secret!(rust_port)
  end
end
