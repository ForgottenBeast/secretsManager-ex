defmodule RotatingSecrets.Cluster.NetsplitTest do
  @moduledoc """
  Cluster tests: during a network partition both sides continue to serve
  last-known-good values; after healing, no errors occur and both sides
  still hold valid secrets.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  setup_all do
    {:ok, cluster} = LocalCluster.start_link(2, applications: [])
    [node_a, node_b] = LocalCluster.nodes(cluster)

    for node <- [node_a, node_b] do
      :ok = :rpc.call(node, Application, :ensure_all_started, [:telemetry])
      {:ok, _} = :rpc.call(node, RotatingSecrets.Supervisor, :start_link, [[]])
    end

    on_exit(fn -> LocalCluster.stop(cluster) end)

    %{node_a: node_a, node_b: node_b}
  end

  test "both sides serve last-known-good during partition and recover after healing",
       %{node_a: node_a, node_b: node_b} do
    dir =
      Path.join(System.tmp_dir!(), "rs_netsplit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "secret.txt")
    File.write!(path, "pre-split-value\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    # unique test atom, not user-controlled
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"netsplit_#{System.unique_integer([:positive])}"

    for node <- [node_a, node_b] do
      {:ok, _} =
        :rpc.call(node, RotatingSecrets, :register, [
          name,
          [
            source: RotatingSecrets.Source.File,
            source_opts: [path: path, mode: {:interval, 60_000}]
          ]
        ])
    end

    # Both nodes should serve the initial value
    {:ok, s_a} = :rpc.call(node_a, RotatingSecrets, :current, [name])
    {:ok, s_b} = :rpc.call(node_b, RotatingSecrets, :current, [name])

    assert :rpc.call(node_a, RotatingSecrets.Secret, :expose, [s_a]) == "pre-split-value"
    assert :rpc.call(node_b, RotatingSecrets.Secret, :expose, [s_b]) == "pre-split-value"

    # --- PARTITION ---
    # Disconnect node_b from the current node and node_a (simulate netsplit)
    :rpc.call(node_a, Node, :disconnect, [node_b])
    Process.sleep(100)

    # During partition: each side must still serve last-known-good
    {:ok, split_a} = :rpc.call(node_a, RotatingSecrets, :current, [name])
    {:ok, split_b} = :rpc.call(node_b, RotatingSecrets, :current, [name])

    assert is_binary(:rpc.call(node_a, RotatingSecrets.Secret, :expose, [split_a]))
    assert is_binary(:rpc.call(node_b, RotatingSecrets.Secret, :expose, [split_b]))

    # --- HEAL ---
    :rpc.call(node_a, Node, :connect, [node_b])
    Process.sleep(100)

    # After healing: both sides still alive and serving valid values
    assert :rpc.call(
             node_a,
             Process,
             :alive?,
             [:rpc.call(node_a, RotatingSecrets.Supervisor, :whereis_child, [name])]
           ) != :badrpc

    {:ok, healed_a} = :rpc.call(node_a, RotatingSecrets, :current, [name])
    {:ok, healed_b} = :rpc.call(node_b, RotatingSecrets, :current, [name])

    assert is_binary(:rpc.call(node_a, RotatingSecrets.Secret, :expose, [healed_a]))
    assert is_binary(:rpc.call(node_b, RotatingSecrets.Secret, :expose, [healed_b]))
  end

  test "nodedown subscriber cleanup fires during partition", %{node_a: node_a, node_b: node_b} do
    # unique test atom, not user-controlled
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"netsplit_sub_#{System.unique_integer([:positive])}"

    # Register only on node_a
    dummy_path = Path.join(System.tmp_dir!(), "netsplit_dummy.txt")

    {:ok, _} =
      :rpc.call(node_a, RotatingSecrets, :register, [
        name,
        [
          source: RotatingSecrets.Source.File,
          source_opts: [
            path: dummy_path,
            mode: {:interval, 60_000}
          ]
        ]
      ])

    # Write the file so load succeeds
    File.write!(dummy_path, "dummy\n")

    # Subscribe a process running on node_b
    remote_pid =
      :rpc.call(node_b, :erlang, :spawn, [fn -> receive do: (:stop -> :ok) end])

    registry_via = {:via, Registry, {RotatingSecrets.ProcessRegistry, name}}

    # Wait a moment for the registry to load
    Process.sleep(50)

    {:ok, _sub_ref} =
      :rpc.call(node_a, GenServer, :call, [registry_via, {:subscribe, remote_pid}])

    # Verify subscriber was added
    registry_pid = :rpc.call(node_a, GenServer, :whereis, [registry_via])
    state_before = :rpc.call(node_a, :sys, :get_state, [registry_pid])
    assert map_size(state_before.subscribers) == 1

    # Partition: disconnect node_b from node_a
    :rpc.call(node_a, Node, :disconnect, [node_b])
    Process.sleep(200)

    # Subscriber from node_b should be removed from node_a's registry
    state_after = :rpc.call(node_a, :sys, :get_state, [registry_pid])
    assert map_size(state_after.subscribers) == 0

    # Heal
    :rpc.call(node_a, Node, :connect, [node_b])
    Process.sleep(50)
  end
end
