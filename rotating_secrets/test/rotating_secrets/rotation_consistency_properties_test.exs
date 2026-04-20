defmodule RotatingSecrets.RotationConsistencyPropertiesTest do
  @moduledoc """
  Property: after a successful load, current/1 returns the material that was loaded.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias RotatingSecrets.Generators
  alias RotatingSecrets.MockSource
  alias RotatingSecrets.Registry
  alias RotatingSecrets.Secret

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    :ok
  end

  property "current/1 always returns the material provided by load/1" do
    check all(
            value <- Generators.secret_value(),
            meta <- Generators.meta_map(),
            max_runs: 25
          ) do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"prop_consistency_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, value, meta, state} end)

      opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
      pid = start_supervised!({Registry, opts}, id: name)

      {:ok, secret} = GenServer.call(name, :current)

      assert Secret.expose(secret) == value
      assert Secret.meta(secret) == meta

      stop_supervised!(name)
      _ = pid
    end
  end

  property "current/1 reflects the most recent successful load after refresh" do
    check all(
            v1 <- Generators.secret_value(),
            v2 <- Generators.secret_value(),
            max_runs: 20
          ) do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"prop_refresh_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled
      # :counters are shared across processes — safe for GenServer load callbacks
      calls = :counters.new(1, [:atomics])

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state ->
        n = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)
        val = if n == 0, do: v1, else: v2
        {:ok, val, %{version: n}, state}
      end)

      opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
      start_supervised!({Registry, opts}, id: name)

      {:ok, secret1} = GenServer.call(name, :current)
      assert Secret.expose(secret1) == v1

      send(name, :do_refresh)
      # GenServer serialises messages: :current call is queued after :do_refresh
      {:ok, secret2} = GenServer.call(name, :current)
      assert Secret.expose(secret2) == v2

      stop_supervised!(name)
    end
  end
end
