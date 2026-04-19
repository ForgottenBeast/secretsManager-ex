defmodule RotatingSecrets.RegistryResilienceTest do
  @moduledoc """
  Resilience tests: Registry recovers from transient errors via exponential backoff.
  """

  use ExUnit.Case, async: false

  @moduletag :resilience

  import Mox

  alias RotatingSecrets.{MockSource, Registry, Secret}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    :ok
  end

  @material "resilient-secret"
  @meta %{version: 1}

  test "Registry stays alive and serves last-known-good while refresh returns transient errors" do
    name = :"resilience_failsoft_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      case n do
        0 -> {:ok, @material, @meta, state}
        _ -> {:error, :timeout, state}
      end
    end)

    opts = [
      name: name,
      source: MockSource,
      source_opts: [],
      fallback_interval_ms: 60_000,
      min_backoff_ms: 50,
      max_backoff_ms: 200
    ]

    start_supervised!({Registry, opts})

    # Initially valid
    assert {:ok, secret} = GenServer.call(name, :current)
    assert Secret.expose(secret) == @material

    # Trigger a failing refresh
    send(name, :do_refresh)
    Process.sleep(30)

    # Registry still alive, still serving the good value
    assert Process.whereis(name) != nil
    assert {:ok, secret2} = GenServer.call(name, :current)
    assert Secret.expose(secret2) == @material
  end

  test "Registry eventually recovers and serves new value after transient errors clear" do
    name = :"resilience_recovery_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      case n do
        0 -> {:ok, "old-value", %{version: 1}, state}
        1 -> {:error, :timeout, state}
        _ -> {:ok, "new-value", %{version: 2}, state}
      end
    end)

    opts = [
      name: name,
      source: MockSource,
      source_opts: [],
      fallback_interval_ms: 60_000,
      min_backoff_ms: 30,
      max_backoff_ms: 100
    ]

    start_supervised!({Registry, opts})

    {:ok, secret} = GenServer.call(name, :current)
    assert Secret.expose(secret) == "old-value"

    # First refresh fails
    send(name, :do_refresh)
    Process.sleep(30)

    # Second refresh succeeds via backoff timer
    send(name, :do_refresh)
    Process.sleep(30)

    {:ok, secret2} = GenServer.call(name, :current)
    assert Secret.expose(secret2) == "new-value"
  end

  test "subscribers are re-notified after recovery" do
    name = :"resilience_sub_recovery_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      case n do
        0 -> {:ok, "v1", %{version: 1}, state}
        1 -> {:error, :timeout, state}
        _ -> {:ok, "v2", %{version: 2}, state}
      end
    end)

    opts = [
      name: name,
      source: MockSource,
      source_opts: [],
      fallback_interval_ms: 60_000,
      min_backoff_ms: 30,
      max_backoff_ms: 100
    ]

    start_supervised!({Registry, opts})
    {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})

    # Fail once, then succeed
    send(name, :do_refresh)
    Process.sleep(30)
    send(name, :do_refresh)
    Process.sleep(30)

    assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, 2}, 500
  end
end
