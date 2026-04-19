defmodule RotatingSecretsVault.Integration.SubscriberTest do
  use ExUnit.Case, async: false

  @moduletag :openbao

  alias RotatingSecrets.Source.Vault.KvV2

  setup do
    prefix = "test-#{:erlang.unique_integer([:positive])}"
    name = :"sub_test_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      RotatingSecrets.deregister(name)
      OpenBaoHelper.delete_path!("secret", prefix)
    end)

    {:ok, prefix: prefix, name: name}
  end

  defp source_opts(prefix, path_suffix) do
    [
      address: OpenBaoHelper.base_url(),
      token: OpenBaoHelper.root_token(),
      path: "#{prefix}/#{path_suffix}",
      mount: "secret"
    ]
  end

  defp register!(name, prefix, path_suffix) do
    OpenBaoHelper.write_secret!("secret", "#{prefix}/#{path_suffix}", %{"value" => "initial"})

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: KvV2,
        source_opts: source_opts(prefix, path_suffix) ++ [fallback_interval_ms: 300]
      )
  end

  test "subscriber receives notification after KV rotation", %{prefix: prefix, name: name} do
    register!(name, prefix, "sub_key")

    {:ok, ref} = RotatingSecrets.subscribe(name)

    OpenBaoHelper.write_secret!("secret", "#{prefix}/sub_key", %{"value" => "new-val"})

    assert_receive {:rotating_secret_rotated, ^ref, ^name, _version}, 2000
  end

  test "notification message contains no secret value", %{prefix: prefix, name: name} do
    secret_value = "super-secret-#{:erlang.unique_integer([:positive])}"
    OpenBaoHelper.write_secret!("secret", "#{prefix}/no_leak_key", %{"value" => secret_value})

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: KvV2,
        source_opts: source_opts(prefix, "no_leak_key") ++ [fallback_interval_ms: 300]
      )

    {:ok, ref} = RotatingSecrets.subscribe(name)

    OpenBaoHelper.write_secret!("secret", "#{prefix}/no_leak_key", %{"value" => "rotated-val"})

    assert_receive msg = {:rotating_secret_rotated, ^ref, ^name, version}, 2000

    # Confirm it is a 4-tuple
    assert tuple_size(msg) == 4

    # version must be an integer (KV v2 metadata version)
    assert is_integer(version)

    # The notification must not carry the secret value
    refute inspect({:rotating_secret_rotated, ref, name, version}) =~ secret_value
    refute inspect({:rotating_secret_rotated, ref, name, version}) =~ "rotated-val"
  end

  test "subscriber auto-removed on process exit", %{prefix: prefix, name: name} do
    register!(name, prefix, "auto_remove_key")

    test_pid = self()

    :telemetry.attach(
      "sub-removed-#{inspect(test_pid)}",
      [:rotating_secrets, :subscriber_removed],
      fn _event, _measurements, _meta, _config ->
        send(test_pid, {:telemetry_event, :subscriber_removed})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("sub-removed-#{inspect(test_pid)}")
    end)

    # Subscribe from a task that immediately exits
    {:ok, task} =
      Task.start(fn ->
        RotatingSecrets.subscribe(name)
        # exit immediately — process death should auto-remove the subscriber
      end)

    # Wait for the task to exit
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 1000

    # Wait for the :subscriber_removed telemetry event
    assert_receive {:telemetry_event, :subscriber_removed}, 2000

    # Trigger a rotation and assert no :noproc errors crash the Registry
    OpenBaoHelper.write_secret!("secret", "#{prefix}/auto_remove_key", %{"value" => "rotated"})

    # Registry PID must still be alive
    assert Process.alive?(GenServer.whereis({:via, Registry, {RotatingSecrets.ProcessRegistry, name}}))
  end

  test "unsubscribe stops notifications", %{prefix: prefix, name: name} do
    register!(name, prefix, "unsub_key")

    {:ok, ref} = RotatingSecrets.subscribe(name)

    :ok = RotatingSecrets.unsubscribe(name, ref)

    OpenBaoHelper.write_secret!("secret", "#{prefix}/unsub_key", %{"value" => "after-unsub"})

    refute_receive {:rotating_secret_rotated, ^ref, _, _}, 2000
  end
end
