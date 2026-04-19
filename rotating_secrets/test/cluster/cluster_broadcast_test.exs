defmodule RotatingSecrets.Cluster.ClusterBroadcastTest do
  @moduledoc """
  Cluster tests: with :cluster_broadcast enabled, a rotation emits
  {:rotating_secret_rotated_cluster, node(), name, version} to all :pg group
  members on every connected node.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  import Mox

  alias RotatingSecrets.{MockSource, Registry}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    :ok
  end

  test "rotation broadcasts {:rotating_secret_rotated_cluster, node, name, version} via :pg" do
    name = :"broadcast_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])
    test_pid = self()

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)
      {:ok, "broadcast-val-#{n}", %{version: n}, state}
    end)

    # Enable cluster broadcast and join the :pg group as a "remote node" listener
    group = :rotating_secrets_rotations
    :ok = Application.put_env(:rotating_secrets, :cluster_broadcast, true)
    :ok = Application.put_env(:rotating_secrets, :cluster_broadcast_group, group)

    on_exit(fn ->
      Application.delete_env(:rotating_secrets, :cluster_broadcast)
      Application.delete_env(:rotating_secrets, :cluster_broadcast_group)
    end)

    # Join the pg group to receive broadcast messages
    :ok = :pg.join(group, test_pid)
    on_exit(fn -> :pg.leave(group, test_pid) end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    start_supervised!({Registry, opts})

    # Trigger a rotation
    send(name, :do_refresh)

    assert_receive {:rotating_secret_rotated_cluster, _node, ^name, _version}, 500
  end

  test "broadcast failure is silenced and does not affect local rotation" do
    name = :"broadcast_safe_#{System.unique_integer([:positive])}"

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      {:ok, "safe-val", %{version: 1}, state}
    end)

    # Enable broadcast with an invalid (nonexistent) :pg group to trigger an error path
    :ok = Application.put_env(:rotating_secrets, :cluster_broadcast, true)
    :ok = Application.put_env(:rotating_secrets, :cluster_broadcast_group, :nonexistent_pg_group)

    on_exit(fn ->
      Application.delete_env(:rotating_secrets, :cluster_broadcast)
      Application.delete_env(:rotating_secrets, :cluster_broadcast_group)
    end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    start_supervised!({Registry, opts})

    # Rotation must succeed locally even if :pg.get_members raises
    {:ok, secret} = GenServer.call(name, :current)
    assert RotatingSecrets.Secret.expose(secret) == "safe-val"

    # Registry must stay alive after a refresh with a bad pg group
    send(name, :do_refresh)
    Process.sleep(50)
    assert Process.whereis(name) != nil
  end

  test "broadcast message never carries the secret value" do
    name = :"broadcast_no_leak_#{System.unique_integer([:positive])}"
    test_pid = self()

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      {:ok, "super-secret-value", %{version: 42}, state}
    end)

    group = :rotating_secrets_rotations_no_leak
    :ok = Application.put_env(:rotating_secrets, :cluster_broadcast, true)
    :ok = Application.put_env(:rotating_secrets, :cluster_broadcast_group, group)

    on_exit(fn ->
      Application.delete_env(:rotating_secrets, :cluster_broadcast)
      Application.delete_env(:rotating_secrets, :cluster_broadcast_group)
    end)

    :ok = :pg.join(group, test_pid)
    on_exit(fn -> :pg.leave(group, test_pid) end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    start_supervised!({Registry, opts})

    send(name, :do_refresh)

    assert_receive {:rotating_secret_rotated_cluster, _node, ^name, version}, 500
    # Message carries version (an integer), not the secret string
    refute is_binary(version) and String.contains?(version, "secret")
  end
end
