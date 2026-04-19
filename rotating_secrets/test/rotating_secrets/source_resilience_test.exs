defmodule RotatingSecrets.SourceResilienceTest do
  @moduledoc """
  Resilience tests: source.load/1 raises an unexpected exception;
  the Registry catches it, schedules backoff, and stays alive.
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

  test "Registry stays alive when source.load raises during refresh" do
    name = :"source_resilience_raise_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      case n do
        0 -> {:ok, "good-value", %{version: 1}, state}
        _ -> raise RuntimeError, "unexpected crash in source.load"
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

    {:ok, secret} = GenServer.call(name, :current)
    assert Secret.expose(secret) == "good-value"

    # Trigger a refresh that raises
    send(name, :do_refresh)
    Process.sleep(30)

    # Registry must still be alive
    assert Process.whereis(name) != nil

    # Must still serve last-known-good
    assert {:ok, secret2} = GenServer.call(name, :current)
    assert Secret.expose(secret2) == "good-value"
  end

  test "Registry stays alive when source.load throws" do
    name = :"source_resilience_throw_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      case n do
        0 -> {:ok, "good", %{}, state}
        _ -> throw(:deliberate_throw)
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

    send(name, :do_refresh)
    Process.sleep(30)

    assert Process.whereis(name) != nil
    assert {:ok, _} = GenServer.call(name, :current)
  end

  test "load exception emits [:rotating_secrets, :source, :load, :exception] telemetry" do
    name = :"source_resilience_telemetry_#{System.unique_integer([:positive])}"
    calls = :counters.new(1, [:atomics])
    test_pid = self()
    handler_id = "resilience-exception-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:rotating_secrets, :source, :load, :exception],
      fn _ev, _m, meta, _ -> send(test_pid, {:exception_event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state ->
      n = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      case n do
        0 -> {:ok, "good", %{}, state}
        _ -> raise "boom"
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

    send(name, :do_refresh)

    assert_receive {:exception_event, %{name: ^name, kind: :error}}, 500
  end
end
