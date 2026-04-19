defmodule RotatingSecretsVault.Integration.RotationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :openbao

  alias RotatingSecrets.Secret

  setup do
    prefix = "test-rotation-#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      OpenBaoHelper.delete_path!("secret", "#{prefix}/val")
    end)

    {:ok, prefix: prefix}
  end

  test "picks up new value after interval refresh", %{prefix: prefix} do
    path = "#{prefix}/val"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v1"})

    {:ok, _pid} =
      RotatingSecrets.register(:"rotation_basic_#{prefix}",
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          mount: "secret",
          path: path
        ],
        fallback_interval_ms: 300
      )

    name = :"rotation_basic_#{prefix}"

    on_exit(fn -> RotatingSecrets.deregister(name) end)

    {:ok, s1} = RotatingSecrets.current(name)
    assert Secret.expose(s1) == "v1"

    attach_telemetry_handler("rotation-basic-#{prefix}", [:rotating_secrets, :rotation])

    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v2"})

    assert_receive {:telemetry_event, [:rotating_secrets, :rotation], _, _}, 2000

    {:ok, s2} = RotatingSecrets.current(name)
    assert Secret.expose(s2) == "v2"
  end

  test "KV version increments in meta after rotation", %{prefix: prefix} do
    path = "#{prefix}/val"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v1"})

    name = :"rotation_version_#{prefix}"

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          mount: "secret",
          path: path
        ],
        fallback_interval_ms: 300
      )

    on_exit(fn -> RotatingSecrets.deregister(name) end)

    {:ok, s1} = RotatingSecrets.current(name)
    assert Secret.expose(s1) == "v1"
    {:ok, _ver1, meta1} = RotatingSecrets.Registry.version_and_meta(name)
    assert meta1.version == 1

    attach_telemetry_handler("rotation-version-#{prefix}", [:rotating_secrets, :rotation])

    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v2"})

    assert_receive {:telemetry_event, [:rotating_secrets, :rotation], _, _}, 2000

    {:ok, _ver2, meta2} = RotatingSecrets.Registry.version_and_meta(name)
    assert meta2.version == 2
  end

  test "telemetry :rotation event fires with correct metadata, no secret value", %{prefix: prefix} do
    path = "#{prefix}/val"
    secret_val = "super-secret-#{:erlang.unique_integer([:positive])}"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => secret_val})

    name = :"rotation_telemetry_#{prefix}"

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          mount: "secret",
          path: path
        ],
        fallback_interval_ms: 300
      )

    on_exit(fn -> RotatingSecrets.deregister(name) end)

    attach_telemetry_handler("rotation-telemetry-#{prefix}", [:rotating_secrets, :rotation])

    new_val = "new-secret-#{:erlang.unique_integer([:positive])}"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => new_val})

    assert_receive {:telemetry_event, [:rotating_secrets, :rotation], measurements, metadata}, 2000

    assert is_atom(metadata[:name])
    assert is_integer(measurements[:version])

    event_map = Map.merge(measurements, metadata)
    event_str = inspect(event_map)
    refute event_str =~ new_val
    refute event_str =~ secret_val

    refute Enum.any?(Map.values(event_map), fn v -> v == new_val end)
    refute Enum.any?(Map.values(event_map), fn v -> v == secret_val end)
  end

  test "telemetry :source_load_stop fires on each refresh", %{prefix: prefix} do
    path = "#{prefix}/val"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v1"})

    name = :"rotation_load_stop_#{prefix}"

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          mount: "secret",
          path: path
        ],
        fallback_interval_ms: 300
      )

    on_exit(fn -> RotatingSecrets.deregister(name) end)

    attach_telemetry_handler(
      "rotation-load-stop-#{prefix}",
      [:rotating_secrets, :source, :load, :stop]
    )

    assert_receive {:telemetry_event, [:rotating_secrets, :source, :load, :stop], _measurements,
                    metadata},
                   2000

    assert Map.has_key?(metadata, :name)
  end

  defp attach_telemetry_handler(id, event) do
    test_pid = self()

    :telemetry.attach(
      "#{id}-#{inspect(test_pid)}",
      event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{id}-#{inspect(test_pid)}") end)
  end
end
