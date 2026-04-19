defmodule RotatingSecrets.Cluster.NodedownTest do
  @moduledoc """
  Cluster tests: when a node hosting a subscriber goes down, the Registry
  removes the subscription and emits [:rotating_secrets, :subscriber_removed]
  telemetry. Re-connecting nodes must re-subscribe explicitly.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  import Mox

  setup_all do
    {:ok, cluster} = LocalCluster.start_link(1, applications: [])
    [remote_node] = LocalCluster.nodes(cluster)

    :ok = :rpc.call(remote_node, Application, :ensure_all_started, [:telemetry])

    on_exit(fn -> LocalCluster.stop(cluster) end)

    %{remote_node: remote_node}
  end

  setup do
    Mox.set_mox_global()

    stub(RotatingSecrets.MockSource, :terminate, fn _state -> :ok end)
    stub(RotatingSecrets.MockSource, :subscribe_changes, fn _state -> :not_supported end)
    stub(RotatingSecrets.MockSource, :init, fn _opts -> {:ok, %{}} end)

    stub(RotatingSecrets.MockSource, :load, fn state ->
      {:ok, "nodedown-test-value", %{version: 1}, state}
    end)

    start_supervised!(RotatingSecrets.Supervisor)

    :ok
  end

  test "subscriber on remote node removed when node disconnects", %{remote_node: remote_node} do
    name = :"nodedown_sub_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.MockSource,
        source_opts: [],
        fallback_interval_ms: 60_000
      )

    # Spawn a subscriber process on the remote node
    remote_pid =
      :rpc.call(remote_node, :erlang, :spawn, [
        fn ->
          receive do
            :stop -> :ok
          end
        end
      ])

    # Subscribe the remote pid from the local registry
    {:ok, _sub_ref} =
      GenServer.call(
        {:via, Registry, {RotatingSecrets.ProcessRegistry, name}},
        {:subscribe, remote_pid}
      )

    # Capture subscriber_removed telemetry
    test_pid = self()
    handler_id = "nodedown-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:rotating_secrets, :subscriber_removed],
      fn _event, _measurements, meta, _ ->
        send(test_pid, {:subscriber_removed, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    registry_pid =
      Process.whereis({:via, Registry, {RotatingSecrets.ProcessRegistry, name}})

    state_before = :sys.get_state(registry_pid)
    assert map_size(state_before.subscribers) == 1

    # Disconnect the remote node (simulates nodedown)
    Node.disconnect(remote_node)
    Process.sleep(100)

    # Subscriber should be cleaned up
    state_after = :sys.get_state(registry_pid)
    assert map_size(state_after.subscribers) == 0

    # Telemetry must have fired
    assert_receive {:subscriber_removed, %{name: ^name}}, 500
  end

  test "local registry is unaffected by nodedown for local-only subscribers" do
    name = :"nodedown_local_#{System.unique_integer([:positive])}"

    {:ok, _} =
      RotatingSecrets.register(name,
        source: RotatingSecrets.MockSource,
        source_opts: [],
        fallback_interval_ms: 60_000
      )

    {:ok, sub_ref} = RotatingSecrets.subscribe(name)

    registry_pid =
      Process.whereis({:via, Registry, {RotatingSecrets.ProcessRegistry, name}})

    state = :sys.get_state(registry_pid)
    assert map_size(state.subscribers) == 1

    # Simulate nodedown for an unrelated node — local subscriber must be kept
    send(registry_pid, {:nodedown, :"unrelated@nowhere"})
    Process.sleep(30)

    state_after = :sys.get_state(registry_pid)
    assert map_size(state_after.subscribers) == 1

    RotatingSecrets.unsubscribe(name, sub_ref)
  end
end
