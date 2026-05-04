defmodule RotatingSecrets.Cluster.IndependentRegistryTest do
  @moduledoc """
  Cluster tests: each node runs an independent Registry for the same named secret;
  after a refresh on each node, both converge on the same value from a shared
  file source.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  setup_all do
    {:ok, cluster} =
      LocalCluster.start_link(2, applications: [])

    nodes = LocalCluster.nodes(cluster)

    # Start the RotatingSecrets.Supervisor on each node
    for node <- nodes do
      :ok = :rpc.call(node, Application, :ensure_all_started, [:telemetry])
      {:ok, _} = :rpc.call(node, RotatingSecrets.Supervisor, :start_link, [[]])
    end

    on_exit(fn -> LocalCluster.stop(cluster) end)

    %{nodes: nodes}
  end

  test "both nodes independently serve the same value from a shared file source",
       %{nodes: [node_a, node_b]} do
    dir =
      Path.join(System.tmp_dir!(), "rs_cluster_ind_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "shared.txt")
    File.write!(path, "shared-v1\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    # unique test atom, not user-controlled
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"cluster_independent_#{System.unique_integer([:positive])}"

    # Register the same secret on each node independently
    {:ok, _} =
      :rpc.call(node_a, RotatingSecrets, :register, [
        name,
        [
          source: RotatingSecrets.Source.File,
          source_opts: [path: path, mode: {:interval, 60_000}]
        ]
      ])

    {:ok, _} =
      :rpc.call(node_b, RotatingSecrets, :register, [
        name,
        [
          source: RotatingSecrets.Source.File,
          source_opts: [path: path, mode: {:interval, 60_000}]
        ]
      ])

    {:ok, s_a} = :rpc.call(node_a, RotatingSecrets, :current, [name])
    {:ok, s_b} = :rpc.call(node_b, RotatingSecrets, :current, [name])

    assert :rpc.call(node_a, RotatingSecrets.Secret, :expose, [s_a]) == "shared-v1"
    assert :rpc.call(node_b, RotatingSecrets.Secret, :expose, [s_b]) == "shared-v1"

    # Update the shared source
    File.write!(path, "shared-v2\n")

    # Trigger refresh on both nodes via the registry pid
    pid_a =
      :rpc.call(node_a, GenServer, :whereis, [
        {:via, Registry, {RotatingSecrets.ProcessRegistry, name}}
      ])

    pid_b =
      :rpc.call(node_b, GenServer, :whereis, [
        {:via, Registry, {RotatingSecrets.ProcessRegistry, name}}
      ])

    send(pid_a, :do_refresh)
    send(pid_b, :do_refresh)
    Process.sleep(100)

    {:ok, s_a2} = :rpc.call(node_a, RotatingSecrets, :current, [name])
    {:ok, s_b2} = :rpc.call(node_b, RotatingSecrets, :current, [name])

    assert :rpc.call(node_a, RotatingSecrets.Secret, :expose, [s_a2]) == "shared-v2"
    assert :rpc.call(node_b, RotatingSecrets.Secret, :expose, [s_b2]) == "shared-v2"
  end
end
