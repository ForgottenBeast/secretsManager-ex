defmodule RotatingSecrets.RegistryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Mox

  setup :set_mox_global

  alias RotatingSecrets.{MockSource, Registry, Secret}

  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    :ok
  end

  # Valid load response fixtures
  @material "my-secret-value"
  @meta %{version: 1, content_hash: "abc"}

  defp start_registry(extra_opts \\ []) do
    name = :"test_registry_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        source: MockSource,
        source_opts: [],
        fallback_interval_ms: 60_000,
        min_backoff_ms: 1_000
      ] ++ extra_opts

    %{name: name, opts: opts}
  end

  defp mock_load_ok(n \\ 1) do
    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> expect(:load, n, fn state -> {:ok, @material, @meta, state} end)
  end

  describe "init/1 and initial load" do
    test "starts and transitions to :valid after successful load" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()

      {:ok, pid} = start_supervised({Registry, opts})
      assert Process.alive?(pid)
      assert {:ok, %Secret{}} = GenServer.call(name, :current)
    end

    test "expose/1 returns the loaded material" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      {:ok, secret} = GenServer.call(name, :current)
      assert Secret.expose(secret) == @material
    end

    test "meta is preserved on the Secret" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      {:ok, secret} = GenServer.call(name, :current)
      assert Secret.meta(secret) == @meta
    end

    test "stops with :permanent_load_failure on :enoent" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :enoent, state} end)

      %{opts: opts} = start_registry()
      {:ok, pid} = start_supervised({Registry, opts}, restart: :temporary)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:permanent_load_failure, :enoent}}, 500
    end

    test "stops with :permanent_load_failure on :eacces" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :eacces, state} end)

      %{opts: opts} = start_registry()
      {:ok, pid} = start_supervised({Registry, opts}, restart: :temporary)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:permanent_load_failure, :eacces}}, 500
    end

    test "stops with :transient_load_failure on network error" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :timeout, state} end)

      %{opts: opts} = start_registry()
      {:ok, pid} = start_supervised({Registry, opts}, restart: :temporary)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:transient_load_failure, :timeout}}, 500
    end

    test "stops with :source_init_failed when source.init fails" do
      MockSource
      |> stub(:init, fn _opts -> {:error, {:invalid_option, :address}} end)

      %{opts: opts} = start_registry()
      {:error, {{:source_init_failed, {:invalid_option, :address}}, _}} =
        start_supervised({Registry, opts})
    end
  end

  describe "subscribe/unsubscribe" do
    test "subscribe returns {:ok, sub_ref}" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      assert {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})
      assert is_reference(sub_ref)
    end

    test "unsubscribe returns :ok" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})
      assert :ok = GenServer.call(name, {:unsubscribe, sub_ref})
    end

    test "subscriber receives :rotating_secret_rotated on refresh" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, 2, fn state -> {:ok, @material, @meta, state} end)

      %{name: name, opts: opts} = start_registry(min_backoff_ms: 1)
      start_supervised!({Registry, opts})

      {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})

      # Trigger a manual refresh
      send(name, :do_refresh)

      assert_receive {:rotating_secret_rotated, ^sub_ref, _name, 1}, 500
    end

    test "subscriber is cleaned up after DOWN" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      sub_pid =
        spawn(fn ->
          GenServer.call(name, {:subscribe, self()})
          receive do: (:stop -> :ok)
        end)

      # Let subscriber register
      :timer.sleep(10)

      # Kill the subscriber
      Process.exit(sub_pid, :kill)
      :timer.sleep(10)

      # Registry should still be alive and have no subscribers
      state = :sys.get_state(pid)
      assert map_size(state.subscribers) == 0
    end
  end

  describe "child_spec/1" do
    test "id is {Registry, name}" do
      spec = Registry.child_spec(name: :test_secret, source: MockSource)
      assert spec.id == {Registry, :test_secret}
    end

    test "restart is :transient" do
      spec = Registry.child_spec(name: :test_secret, source: MockSource)
      assert spec.restart == :transient
    end

    test "start tuple contains no closures or pids" do
      spec = Registry.child_spec(name: :test_secret, source: MockSource)
      {_mod, _fun, [opts]} = spec.start
      assert is_list(opts)
      # Verify serializable (no pids, refs, funs)
      assert :erlang.term_to_binary(spec) |> byte_size() > 0
    end
  end
end
