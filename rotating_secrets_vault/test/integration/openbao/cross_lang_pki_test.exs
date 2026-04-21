defmodule RotatingSecretsVault.Integration.CrossLangPKITest do
  use ExUnit.Case, async: false

  @moduletag :cross_lang

  alias RotatingSecrets.Secret

  setup_all do
    OpenBaoHelper.setup_pki_engine!()
    on_exit(fn -> OpenBaoHelper.teardown_pki_engine!() end)
    :ok
  end

  setup do
    binary_path =
      System.get_env("RUST_CONSUMER_BIN") ||
        raise "RUST_CONSUMER_BIN not set"

    {rust_port_handle, rust_port} = RustConsumerHelper.start_server!(binary_path)
    RustConsumerHelper.wait_for_ready!(rust_port)

    name = :"cross_lang_pki_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      RustConsumerHelper.stop_server!(rust_port_handle)
      RotatingSecrets.deregister(name)
    end)

    {:ok, rust_port: rust_port, name: name}
  end

  test "PKI cert issuance pipeline reaches Rust consumer", %{rust_port: rust_port, name: name} do
    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.PKI,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          mount: "pki",
          role: "test-role",
          common_name: "test.example.com",
          ttl: "10s"
        ]
      )

    {:ok, sub_ref} = RotatingSecrets.subscribe(name)

    {:ok, s1} = RotatingSecrets.current(name)
    material_v1 = Secret.expose(s1)

    # Verify it is a valid JSON cert bundle
    assert Map.has_key?(Jason.decode!(material_v1), "certificate")

    # Push to Rust consumer
    RustConsumerHelper.push_secret!(rust_port, material_v1, 1)
    assert %{"value" => ^material_v1, "version" => 1} = RustConsumerHelper.get_secret!(rust_port)

    # Wait for re-issuance (new cert after 10s TTL)
    assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, _}, 30_000

    {:ok, s2} = RotatingSecrets.current(name)
    material_v2 = Secret.expose(s2)

    # New cert must be different from initial
    assert material_v2 != material_v1

    # Push new cert to Rust
    RustConsumerHelper.push_secret!(rust_port, material_v2, 2)
    assert %{"value" => ^material_v2, "version" => 2} = RustConsumerHelper.get_secret!(rust_port)
  end
end
