defmodule RotatingSecretsVault.Integration.CrossLangTest do
  use ExUnit.Case, async: false

  @moduletag :cross_lang

  import ExUnit.Assertions
  alias RotatingSecrets.Secret

  setup do
    binary_path = System.get_env("RUST_CONSUMER_BIN") ||
                  raise "RUST_CONSUMER_BIN not set"

    {rust_port_handle, rust_port} = RustConsumerHelper.start_server!(binary_path)
    RustConsumerHelper.wait_for_ready!(rust_port)

    prefix = "test-#{:erlang.unique_integer([:positive])}"
    secret_name = :"cross_lang_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      RustConsumerHelper.stop_server!(rust_port_handle)
      RotatingSecrets.deregister(secret_name)
      OpenBaoHelper.delete_path!("secret", "#{prefix}/cross_lang")
    end)

    {:ok, prefix: prefix, rust_port: rust_port, secret_name: secret_name}
  end

  test "full rotation pipeline reaches Rust consumer", %{
    prefix: prefix,
    rust_port: rust_port,
    secret_name: secret_name
  } do
    # Step 1: Write initial secret to OpenBao
    OpenBaoHelper.write_secret!("secret", "#{prefix}/cross_lang", %{"value" => "v1-value"})

    # Step 2: Register in Elixir
    {:ok, _} = RotatingSecrets.register(secret_name,
      source: RotatingSecrets.Source.Vault.KvV2,
      source_opts: [
        address: OpenBaoHelper.base_url(),
        token: OpenBaoHelper.root_token(),
        path: "#{prefix}/cross_lang",
        mount: "secret"
      ],
      fallback_interval_ms: 300
    )

    # Step 3: Subscribe
    {:ok, sub_ref} = RotatingSecrets.subscribe(secret_name)

    # Step 4: Assert initial value
    {:ok, s1} = RotatingSecrets.current(secret_name)
    assert Secret.expose(s1) == "v1-value"

    # Step 5: Push to Rust
    RustConsumerHelper.push_secret!(rust_port, "v1-value", 1)

    # Step 6: Verify Rust has v1
    assert %{"value" => "v1-value", "version" => 1} = RustConsumerHelper.get_secret!(rust_port)

    # Step 7: Write rotated value to OpenBao
    OpenBaoHelper.write_secret!("secret", "#{prefix}/cross_lang", %{"value" => "v2-value"})

    # Step 8: Wait for Elixir to pick up rotation
    assert_receive {:rotating_secret_rotated, ^sub_ref, ^secret_name, _}, 3000

    # Step 9: Assert rotated value in Elixir
    {:ok, s2} = RotatingSecrets.current(secret_name)
    assert Secret.expose(s2) == "v2-value"

    # Step 10: Push to Rust
    RustConsumerHelper.push_secret!(rust_port, "v2-value", 2)

    # Step 11: Verify Rust has v2
    assert %{"value" => "v2-value", "version" => 2} = RustConsumerHelper.get_secret!(rust_port)
  end
end
