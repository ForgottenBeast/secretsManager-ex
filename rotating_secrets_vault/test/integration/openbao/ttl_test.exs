defmodule RotatingSecretsVault.Integration.TtlTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :openbao

  alias RotatingSecrets.Secret

  # ---------------------------------------------------------------------------
  # Test 1: custom_metadata.ttl_seconds drives 2/3-lifetime scheduling
  # ---------------------------------------------------------------------------

  test "respects ttl_seconds from KV v2 custom_metadata" do
    path = "test-ttl-meta-#{System.unique_integer([:positive])}"
    name = :"vault_ttl_meta_#{System.unique_integer([:positive])}"

    OpenBaoHelper.write_secret!("secret", path, %{"value" => "initial-value"}, %{
      "ttl_seconds" => "1"
    })

    on_exit(fn ->
      RotatingSecrets.deregister(name)
      OpenBaoHelper.delete_path!("secret", path)
    end)

    handler_id = attach_telemetry_handler([:rotating_secrets, :rotation])

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ]
      )

    # Update KV value at ~500ms — before the 666ms TTL-driven refresh fires
    Process.sleep(500)
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "updated-value"})

    # Wait for rotation event (TTL-driven refresh at 666ms; give 2000ms budget)
    assert_receive {:telemetry, [:rotating_secrets, :rotation], _measurements, %{name: ^name}},
                   2000

    {:ok, secret} = RotatingSecrets.current(name)
    assert Secret.expose(secret) == "updated-value"

    :telemetry.detach(handler_id)
  end

  # ---------------------------------------------------------------------------
  # Test 2: fallback_interval_ms drives polling when no custom_metadata TTL
  # ---------------------------------------------------------------------------

  test "falls back to fallback_interval_ms when no custom_metadata TTL" do
    path = "test-ttl-fallback-#{System.unique_integer([:positive])}"
    name = :"vault_ttl_fallback_#{System.unique_integer([:positive])}"

    OpenBaoHelper.write_secret!("secret", path, %{"value" => "first-value"})

    on_exit(fn ->
      RotatingSecrets.deregister(name)
      OpenBaoHelper.delete_path!("secret", path)
    end)

    handler_id = attach_telemetry_handler([:rotating_secrets, :rotation])

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ],
        fallback_interval_ms: 300
      )

    OpenBaoHelper.write_secret!("secret", path, %{"value" => "second-value"})

    assert_receive {:telemetry, [:rotating_secrets, :rotation], _measurements, %{name: ^name}},
                   2000

    {:ok, secret} = RotatingSecrets.current(name)
    assert Secret.expose(secret) == "second-value"

    :telemetry.detach(handler_id)
  end

  # ---------------------------------------------------------------------------
  # Test 3: KV v2 version field drives monotone versioning
  # ---------------------------------------------------------------------------

  test "version from KV v2 metadata drives monotone versioning" do
    path = "test-ttl-version-#{System.unique_integer([:positive])}"
    name = :"vault_ttl_version_#{System.unique_integer([:positive])}"

    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v1-value"})

    on_exit(fn ->
      RotatingSecrets.deregister(name)
      OpenBaoHelper.delete_path!("secret", path)
    end)

    handler_id = attach_telemetry_handler([:rotating_secrets, :rotation])

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ],
        fallback_interval_ms: 300
      )

    # Write v2 and wait for rotation
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v2-value"})

    assert_receive {:telemetry, [:rotating_secrets, :rotation], %{version: v2}, %{name: ^name}},
                   2000

    # Write v3 and wait for rotation
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v3-value"})

    assert_receive {:telemetry, [:rotating_secrets, :rotation], %{version: v3}, %{name: ^name}},
                   2000

    # Versions must be strictly increasing
    assert is_integer(v2)
    assert is_integer(v3)
    assert v3 > v2

    :telemetry.detach(handler_id)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp attach_telemetry_handler(event) do
    test_pid = self()
    handler_id = "ttl-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ev, measurements, metadata, _ ->
        send(test_pid, {:telemetry, ev, measurements, metadata})
      end,
      nil
    )

    handler_id
  end
end
