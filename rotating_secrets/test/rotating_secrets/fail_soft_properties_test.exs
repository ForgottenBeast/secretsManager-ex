defmodule RotatingSecrets.FailSoftPropertiesTest do
  @moduledoc """
  Property: when refresh fails, the Registry serves the last-known-good value
  without crashing and without returning nil.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias RotatingSecrets.{Generators, MockSource, Registry, Secret}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    :ok
  end

  property "last-known-good is served after a transient refresh failure" do
    check all(
            value <- Generators.secret_value(),
            error <- Generators.transient_error(),
            max_runs: 20
          ) do
      name = :"prop_fail_soft_#{System.unique_integer([:positive])}"
      calls = :counters.new(1, [:atomics])

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state ->
        n = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)

        if n == 0 do
          {:ok, value, %{version: 1}, state}
        else
          {:error, error, state}
        end
      end)

      opts = [
        name: name,
        source: MockSource,
        source_opts: [],
        fallback_interval_ms: 60_000,
        min_backoff_ms: 100
      ]

      start_supervised!({Registry, opts}, id: name)

      # Trigger a failing refresh
      send(name, :do_refresh)
      Process.sleep(30)

      # Registry must still be alive
      assert Process.whereis(name) != nil

      # Must still serve the last-known-good
      assert {:ok, secret} = GenServer.call(name, :current)
      assert Secret.expose(secret) == value
      refute Secret.expose(secret) == nil

      stop_supervised!(name)
    end
  end
end
