defmodule RotatingSecretsVault.Integration.FailSoftTest do
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

  test "serves last-known-good when source becomes unreachable", %{prefix: prefix} do
    path = "#{prefix}/api_key"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "initial-value"})

    fault_name = :"fault_#{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      RotatingSecrets.register(:fault_secret,
        source: SourceFault,
        source_opts: [
          source: RotatingSecrets.Source.Vault.KvV2,
          source_opts: [
            address: OpenBaoHelper.base_url(),
            token: OpenBaoHelper.root_token(),
            path: path,
            mount: "secret"
          ],
          fault_name: fault_name,
          fallback_interval_ms: 300
        ]
      )

    on_exit(fn -> RotatingSecrets.deregister(:fault_secret) end)

    # Initial load succeeds
    {:ok, s1} = RotatingSecrets.current(:fault_secret)
    assert Secret.expose(s1) == "initial-value"

    # Attach handler before arming to avoid race between arm! and first failed load event
    attach_telemetry_handler(:source_load_stop_test, [:rotating_secrets, :source, :load, :stop])

    # Arm the fault — subsequent loads return {:error, {:connection_error, :econnrefused}, state}
    SourceFault.arm!(fault_name)
    assert_receive {:telemetry_event, [:rotating_secrets, :source, :load, :stop], _, _}, 2000

    # Registry still serves last-known-good
    {:ok, s2} = RotatingSecrets.current(:fault_secret)
    assert Secret.expose(s2) == "initial-value"

    # Registry PID is still alive
    assert Process.alive?(GenServer.whereis(:fault_secret))
  end

  test "Registry stays alive and serves stale when KV path deleted", %{prefix: prefix} do
    path = "#{prefix}/key"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "loaded-value"})

    {:ok, _} =
      RotatingSecrets.register(:stale_secret,
        source: RotatingSecrets.Source.Vault.KvV2,
        source_opts: [
          address: OpenBaoHelper.base_url(),
          token: OpenBaoHelper.root_token(),
          path: path,
          mount: "secret"
        ],
        fallback_interval_ms: 300
      )

    on_exit(fn -> RotatingSecrets.deregister(:stale_secret) end)

    {:ok, s} = RotatingSecrets.current(:stale_secret)
    assert Secret.expose(s) == "loaded-value"

    # Delete the secret from OpenBao (simulates path removal mid-operation)
    OpenBaoHelper.delete_path!("secret", path)

    # Wait for a refresh attempt; :not_found is classified permanent in classify_error
    # but handle_info ignores the class and calls schedule_backoff — Registry stays alive
    attach_telemetry_handler(:load_stop, [:rotating_secrets, :source, :load, :stop])
    assert_receive {:telemetry_event, [:rotating_secrets, :source, :load, :stop], _, _}, 2000

    # Stale value still served
    {:ok, s2} = RotatingSecrets.current(:stale_secret)
    assert Secret.expose(s2) == "loaded-value"
    assert Process.alive?(GenServer.whereis(:stale_secret))
  end

  test "exponential backoff increases interval between load attempts", %{prefix: prefix} do
    path = "#{prefix}/k"
    OpenBaoHelper.write_secret!("secret", path, %{"value" => "v"})

    fault_name = :"backoff_fault_#{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      RotatingSecrets.register(:backoff_secret,
        source: SourceFault,
        source_opts: [
          source: RotatingSecrets.Source.Vault.KvV2,
          source_opts: [
            address: OpenBaoHelper.base_url(),
            token: OpenBaoHelper.root_token(),
            path: path,
            mount: "secret"
          ],
          fault_name: fault_name,
          fallback_interval_ms: 300
        ],
        min_backoff_ms: 50
      )

    on_exit(fn -> RotatingSecrets.deregister(:backoff_secret) end)

    {:ok, _} = RotatingSecrets.current(:backoff_secret)
    SourceFault.arm!(fault_name)

    # Collect timestamps of load stop events (3 events)
    attach_telemetry_handler(:backoff_events, [:rotating_secrets, :source, :load, :stop])
    t0 = System.monotonic_time(:millisecond)
    assert_receive {:telemetry_event, _, _, _}, 500
    t1 = System.monotonic_time(:millisecond)
    assert_receive {:telemetry_event, _, _, _}, 1000
    t2 = System.monotonic_time(:millisecond)
    assert_receive {:telemetry_event, _, _, _}, 2000
    t3 = System.monotonic_time(:millisecond)

    # Intervals should grow: (t2-t1) > (t1-t0) and (t3-t2) > (t2-t1)
    assert t2 - t1 > t1 - t0
    assert t3 - t2 > t2 - t1
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
