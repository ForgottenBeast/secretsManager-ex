defmodule RotatingSecrets.SubscriberResilienceTest do
  @moduledoc """
  Resilience tests: subscriber crashes do not affect remaining subscribers.
  """

  use ExUnit.Case, async: false

  import Mox

  alias RotatingSecrets.MockSource
  alias RotatingSecrets.Registry

  @moduletag :resilience

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    :ok
  end

  test "remaining subscribers receive notification after one subscriber crashes" do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"sub_resilience_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      :counters.add(calls, 1, 1)
      {:ok, "val-#{:counters.get(calls, 1)}", %{version: :counters.get(calls, 1)}, state}
    end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    start_supervised!({Registry, opts})

    # Subscribe two processes: one that will crash, one that should survive
    test_pid = self()

    crasher =
      spawn(fn ->
        {:ok, _ref} = GenServer.call(name, {:subscribe, self()})
        send(test_pid, :crasher_subscribed)

        receive do
          :crash_now -> exit(:crash)
        end
      end)

    assert_receive :crasher_subscribed, 500

    {:ok, survivor_ref} = GenServer.call(name, {:subscribe, self()})

    # Kill the crasher (Registry should detect via DOWN)
    Process.exit(crasher, :kill)
    Process.sleep(20)

    # Trigger rotation — only survivor should get the notification
    send(name, :do_refresh)

    assert_receive {:rotating_secret_rotated, ^survivor_ref, _name, _ver}, 500
    # Registry itself must still be alive
    assert Process.whereis(name) != nil
  end

  test "dead subscriber is removed from state before next rotation" do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"sub_cleanup_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state -> {:ok, "v", %{}, state} end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    pid = start_supervised!({Registry, opts})

    dead_sub =
      spawn(fn ->
        GenServer.call(name, {:subscribe, self()})

        receive do
          :stop -> :ok
        end
      end)

    :timer.sleep(10)
    state_before = :sys.get_state(pid)
    assert map_size(state_before.subscribers) == 1

    Process.exit(dead_sub, :kill)
    :timer.sleep(30)

    state_after = :sys.get_state(pid)
    assert map_size(state_after.subscribers) == 0
  end
end
