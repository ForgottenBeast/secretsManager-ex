defmodule RotatingSecrets.MonotoneVersionsPropertiesTest do
  @moduledoc """
  Property: the version in :rotating_secret_rotated notifications equals
  the :version field in the meta returned by load/1.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

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

  property "notification version matches the version in meta from load/1" do
    check all(
            version <- integer(1..9999),
            max_runs: 25
          ) do
      # unique test atom, not user-controlled
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"prop_versions_#{System.unique_integer([:positive])}"
      meta = %{version: version}

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, "secret", meta, state} end)

      opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
      start_supervised!({Registry, opts}, id: name)

      {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})

      # Trigger rotation
      send(name, :do_refresh)

      assert_receive {:rotating_secret_rotated, ^sub_ref, _name, ^version}, 500

      # Also verify via current/1 that meta matches
      {:ok, secret} = GenServer.call(name, :current)
      assert Secret.meta(secret)[:version] == version

      stop_supervised!(name)
    end
  end

  test "version is nil when meta has no :version key" do
    # unique test atom, not user-controlled
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"prop_nil_ver_#{System.unique_integer([:positive])}"

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state -> {:ok, "secret", %{}, state} end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    start_supervised!({Registry, opts}, id: name)

    {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})
    send(name, :do_refresh)

    assert_receive {:rotating_secret_rotated, ^sub_ref, _name, nil}, 500

    stop_supervised!(name)
  end
end
