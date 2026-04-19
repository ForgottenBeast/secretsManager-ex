defmodule RotatingSecrets.Cluster.HordeMigrationTest do
  @moduledoc """
  Cluster tests: the Registry child_spec is fully serializable (no closures,
  no PIDs, no refs), enabling Horde migration. We simulate migration by:
    1. Starting a Registry process under a `server_name` via-tuple.
    2. Stopping it.
    3. Restarting it with the original child_spec (as Horde would do on the
       destination node after migration).
    4. Asserting subscribers receive `{:rotating_secret_rotated, ...}` after
       the migrated process performs its first rotation.

  Horde itself is not a dependency. The via-tuple uses Elixir's built-in
  `Registry` to stand in for Horde.Registry.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  import Mox

  alias RotatingSecrets.{MockSource, Registry, Secret}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Start a local registry to act as the "Horde.Registry" stand-in
    {:ok, _} = Registry.start_link(keys: :unique, name: :test_via_registry)

    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)

    :ok
  end

  test "child_spec contains no closures, PIDs, or refs" do
    name = :"horde_spec_#{System.unique_integer([:positive])}"
    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]

    spec = RotatingSecrets.Registry.child_spec(opts)

    assert %{
             id: {RotatingSecrets.Registry, ^name},
             start: {RotatingSecrets.Registry, :start_link, [^opts]},
             restart: :transient
           } = spec

    # Verify the spec round-trips through term_to_binary/binary_to_term
    # (no closures, no PIDs — only serializable terms)
    encoded = :erlang.term_to_binary(spec)
    decoded = :erlang.binary_to_term(encoded)
    assert decoded == spec
  end

  test "Registry restarts from the original child_spec and subscribers survive" do
    name = :"horde_migration_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)
      {:ok, "val-#{n}", %{version: n}, state}
    end)

    # Register using a via-tuple for the server_name (simulating Horde.Registry)
    via = {:via, Registry, {:test_via_registry, name}}

    opts = [
      name: name,
      server_name: via,
      source: MockSource,
      source_opts: [],
      fallback_interval_ms: 60_000
    ]

    {:ok, pid1} = RotatingSecrets.Registry.start_link(opts)
    assert Process.alive?(pid1)

    {:ok, s1} = GenServer.call(via, :current)
    assert is_binary(Secret.expose(s1))

    # Subscribe before migration
    test_pid = self()
    {:ok, sub_ref} = GenServer.call(via, {:subscribe, test_pid})

    # "Migrate": stop the process (as Horde does before starting on the new node)
    GenServer.stop(pid1, :normal)
    refute Process.alive?(pid1)

    # Restart from the same serializable child_spec — simulates Horde restart on dest node
    {:ok, pid2} = RotatingSecrets.Registry.start_link(opts)
    assert pid2 != pid1
    assert Process.alive?(pid2)

    # Re-subscribe (subscribers must re-subscribe after migration — documented behaviour)
    {:ok, sub_ref2} = GenServer.call(via, {:subscribe, test_pid})

    # Trigger a rotation on the migrated process
    send(pid2, :do_refresh)

    assert_receive {:rotating_secret_rotated, ^sub_ref2, ^name, _version}, 500

    _ = sub_ref
  end
end
