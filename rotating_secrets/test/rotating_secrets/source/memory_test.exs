defmodule RotatingSecrets.Source.MemoryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Mox

  alias RotatingSecrets.MockSource
  # credo:disable-for-next-line Credo.Check.Readability.AliasAs
  alias RotatingSecrets.Source.Memory, as: MemorySource
  alias RotatingSecrets.Supervisor

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    start_supervised!(Supervisor)
    :ok
  end

  defp unique_name do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    :"memory_test_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled
  end

  describe "init/1" do
    test "starts an Agent and returns {:ok, state} with name and nil channel_ref" do
      name = unique_name()
      assert {:ok, state} = MemorySource.init(name: name, initial_value: "initial")
      assert state.name == name
      assert state.channel_ref == nil
    end

    test "re-initializes existing Agent on duplicate name" do
      name = unique_name()
      {:ok, _} = MemorySource.init(name: name, initial_value: "v1")
      {:ok, _} = MemorySource.init(name: name, initial_value: "v2")

      # Agent should be reset to v2
      {:ok, state} = MemorySource.init(name: name, initial_value: "v3")
      assert {:ok, "v3", %{}, _} = MemorySource.load(state)
    end
  end

  describe "load/1" do
    test "returns the initial value" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "initial-value")
      assert {:ok, "initial-value", %{}, _state} = MemorySource.load(state)
    end
  end

  describe "subscribe_changes/1" do
    test "returns {:ok, ref, new_state} with a non-nil channel_ref" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "val")
      assert {:ok, ref, new_state} = MemorySource.subscribe_changes(state)
      assert is_reference(ref)
      assert new_state.channel_ref == ref
    end
  end

  describe "handle_change_notification/2" do
    test "returns {:changed, state} when channel_ref matches" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "val")
      {:ok, ref, sub_state} = MemorySource.subscribe_changes(state)

      msg = {ref, :updated}
      assert {:changed, ^sub_state} = MemorySource.handle_change_notification(msg, sub_state)
    end

    test "returns :ignored for wrong ref" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "val")
      {:ok, _ref, sub_state} = MemorySource.subscribe_changes(state)

      msg = {make_ref(), :updated}
      assert :ignored = MemorySource.handle_change_notification(msg, sub_state)
    end

    test "returns :ignored for unrelated messages" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "val")
      assert :ignored = MemorySource.handle_change_notification(:random, state)
    end
  end

  describe "update/2" do
    test "returns {:error, :not_found} when Agent is not registered" do
      assert {:error, :not_found} = MemorySource.update(:nonexistent_secret_xyz, "val")
    end

    test "updates the Agent value; next load returns new value" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "original")

      :ok = MemorySource.update(name, "updated")
      assert {:ok, "updated", %{}, _} = MemorySource.load(state)
    end

    test "sends {channel_ref, :updated} to the Registry PID after subscribe_changes" do
      name = unique_name()
      {:ok, _state} = MemorySource.init(name: name, initial_value: "val")

      # Simulate the Registry calling subscribe_changes with self() as the registry PID.
      # Capture test_pid before the Agent.update closure — self() inside the closure
      # refers to the Agent process, not the test process.
      test_pid = self()
      ref = make_ref()
      agent_key = {MemorySource, name}
      [{agent_pid, _}] = Registry.lookup(RotatingSecrets.ProcessRegistry, agent_key)

      Agent.update(agent_pid, fn s ->
        %{s | channel_ref: ref, registry_pid: test_pid}
      end)

      :ok = MemorySource.update(name, "new-val")

      assert_receive {^ref, :updated}, 500
    end
  end

  describe "terminate/1" do
    test "stops the Agent without raising" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "val")
      assert :ok = MemorySource.terminate(state)
    end

    test "is idempotent — calling twice does not raise" do
      name = unique_name()
      {:ok, state} = MemorySource.init(name: name, initial_value: "val")
      assert :ok = MemorySource.terminate(state)
      assert :ok = MemorySource.terminate(state)
    end
  end
end
