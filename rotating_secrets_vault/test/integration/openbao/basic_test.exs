defmodule RotatingSecretsVault.Integration.BasicTest do
  use ExUnit.Case, async: false

  @moduletag :openbao

  alias RotatingSecrets.Secret

  setup do
    prefix = "test-#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      OpenBaoHelper.delete_path!("secret", prefix)
    end)

    {:ok, prefix: prefix}
  end

  test "reads secret value from OpenBao KV v2", %{prefix: prefix} do
    path = "#{prefix}/api_key"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "my-secret-abc"})

    {:ok, _pid} =
      RotatingSecrets.register(:api_key,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ]
      )

    on_exit(fn -> RotatingSecrets.deregister(:api_key) end)

    {:ok, secret} = RotatingSecrets.current(:api_key)
    assert Secret.expose(secret) == "my-secret-abc"
  end

  test "initial load failure stops the Registry — path does not exist", %{prefix: prefix} do
    result =
      RotatingSecrets.register(:nonexistent_key,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: "#{prefix}/nonexistent",
          mount: "secret"
        ]
      )

    assert {:error, _} = result
  end

  test "returns KV v2 version in meta", %{prefix: prefix} do
    path = "#{prefix}/versioned"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "versioned-value"})

    {:ok, _pid} =
      RotatingSecrets.register(:versioned_key,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ]
      )

    on_exit(fn -> RotatingSecrets.deregister(:versioned_key) end)

    {:ok, s} = RotatingSecrets.current(:versioned_key)
    assert Secret.meta(s).version == 1
  end

  test "with_secret/2 executes with correct value", %{prefix: prefix} do
    path = "#{prefix}/with_secret"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "expected-value"})

    {:ok, _pid} =
      RotatingSecrets.register(:with_secret_key,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ]
      )

    on_exit(fn -> RotatingSecrets.deregister(:with_secret_key) end)

    result = RotatingSecrets.with_secret(:with_secret_key, fn s -> Secret.expose(s) end)
    assert result == {:ok, "expected-value"}
  end

  test "secret value not logged during load", %{prefix: prefix} do
    import ExUnit.CaptureLog

    path = "#{prefix}/no_log"
    secret_value = "super-secret-no-log-#{:erlang.unique_integer([:positive])}"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => secret_value})

    log =
      capture_log(fn ->
        {:ok, _pid} =
          RotatingSecrets.register(:no_log_key,
            source: RotatingSecrets.Source.Vault.KvV2,
            source_opts: [
              address: OpenBaoHelper.base_url(),
              token: OpenBaoHelper.root_token(),
              path: path,
              mount: "secret"
            ]
          )

        {:ok, _secret} = RotatingSecrets.current(:no_log_key)
      end)

    on_exit(fn -> RotatingSecrets.deregister(:no_log_key) end)

    refute log =~ secret_value
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
