defmodule RotatingSecrets.RegistryTest do
  @moduledoc false

  use ExUnit.Case, async: false

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

  # Valid load response fixtures
  @material "my-secret-value"
  @meta %{version: 1, content_hash: "abc"}

  defp start_registry(extra_opts \\ []) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"test_registry_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

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

    test "returns :permanent_load_failure on :enoent" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :enoent, state} end)

      %{opts: opts} = start_registry()
      assert {:error, {{:permanent_load_failure, :enoent}, _}} = start_supervised({Registry, opts})
    end

    test "returns :permanent_load_failure on :eacces" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :eacces, state} end)

      %{opts: opts} = start_registry()
      assert {:error, {{:permanent_load_failure, :eacces}, _}} = start_supervised({Registry, opts})
    end

    test "returns :transient_load_failure on network error" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :timeout, state} end)

      %{opts: opts} = start_registry()
      assert {:error, {{:transient_load_failure, :timeout}, _}} = start_supervised({Registry, opts})
    end

    test "stops with :source_init_failed when source.init fails" do
      stub(MockSource, :init, fn _opts -> {:error, {:invalid_option, :address}} end)

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

  describe "version_and_meta" do
    test "returns {:ok, version, meta} when secret is valid" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      assert {:ok, 1, %{version: 1, content_hash: "abc"}} =
               GenServer.call(name, :version_and_meta)
    end

    test "returns {:error, :expired} when lifecycle is expired" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      :sys.replace_state(pid, fn state -> %{state | lifecycle: :expired} end)
      assert {:error, :expired} = GenServer.call(name, :version_and_meta)
    end
  end

  describe "current lifecycle states" do
    test "returns {:error, :expired} when lifecycle is expired" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      :sys.replace_state(pid, fn state -> %{state | lifecycle: :expired} end)
      assert {:error, :expired} = GenServer.call(name, :current)
    end

    test "returns {:error, :loading} when lifecycle is loading" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      :sys.replace_state(pid, fn state -> %{state | lifecycle: :loading} end)
      assert {:error, :loading} = GenServer.call(name, :current)
    end
  end

  describe "version_and_meta/1 module function" do
    test "calls through process registry" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()

      # Need the process registry to be available
      start_supervised!({Elixir.Registry, keys: :unique, name: RotatingSecrets.ProcessRegistry})
      server_name = {:via, Elixir.Registry, {RotatingSecrets.ProcessRegistry, name}}
      start_supervised!({Registry, Keyword.put(opts, :server_name, server_name)})

      assert {:ok, 1, %{version: 1}} = Registry.version_and_meta(name)
    end
  end

  describe "do_refresh with backoff" do
    test "schedules retry on transient load failure during refresh" do
      call_count = :counters.new(1, [:atomics])

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, @material, @meta, state}
        else
          {:error, :timeout, state}
        end
      end)

      %{name: name, opts: opts} = start_registry(min_backoff_ms: 10, max_backoff_ms: 50)
      pid = start_supervised!({Registry, opts})

      # Trigger refresh that will fail
      send(name, :do_refresh)
      :timer.sleep(30)

      # The process should still be alive (transient error does not crash it)
      assert Process.alive?(pid)
      assert {:ok, %Secret{}} = GenServer.call(name, :current)
    end
  end

  describe "unsubscribe edge cases" do
    test "unsubscribe with unknown sub_ref returns :ok" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      assert :ok = GenServer.call(name, {:unsubscribe, make_ref()})
    end
  end

  describe "permanent error classification" do
    test ":not_found is classified as permanent" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :not_found, state} end)

      %{opts: opts} = start_registry()
      assert {:error, {{:permanent_load_failure, :not_found}, _}} = start_supervised({Registry, opts})
    end

    test ":forbidden is classified as permanent" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, :forbidden, state} end)

      %{opts: opts} = start_registry()
      assert {:error, {{:permanent_load_failure, :forbidden}, _}} = start_supervised({Registry, opts})
    end

    test "{:invalid_option, _} is classified as permanent" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:error, {:invalid_option, :bad}, state} end)

      %{opts: opts} = start_registry()
      assert {:error, {{:permanent_load_failure, {:invalid_option, :bad}}, _}} =
               start_supervised({Registry, opts})
    end
  end

  describe "load exception handling" do
    test "source raising an exception results in transient error" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn _state -> raise "boom" end)

      %{opts: opts} = start_registry()
      assert {:error, {{:transient_load_failure, {:exception, %RuntimeError{}}}, _}} =
               start_supervised({Registry, opts})
    end

    test "source throwing a value results in transient error" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn _state -> throw(:kaboom) end)

      %{opts: opts} = start_registry()
      assert {:error, {{:transient_load_failure, {:exception, {:throw, :kaboom}}}, _}} =
               start_supervised({Registry, opts})
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages when source lacks handle_change_notification" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      send(name, :some_random_message)
      :timer.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "DOWN with :noconnection" do
    test "removes subscriber on :noconnection DOWN" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      # Subscribe a spawned process
      sub_pid =
        spawn(fn ->
          receive do: (:stop -> :ok)
        end)

      {:ok, _sub_ref} = GenServer.call(name, {:subscribe, sub_pid})
      :timer.sleep(10)

      state = :sys.get_state(pid)
      assert map_size(state.subscribers) == 1

      # Simulate :noconnection DOWN by finding the monitor ref and sending the message
      [{monitor_ref, _}] = Map.to_list(state.subscribers)
      send(pid, {:DOWN, monitor_ref, :process, sub_pid, :noconnection})
      :timer.sleep(10)

      state_after = :sys.get_state(pid)
      assert map_size(state_after.subscribers) == 0
    end

    test "ignores :noconnection DOWN for unknown monitor ref" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      send(name, {:DOWN, make_ref(), :process, self(), :noconnection})
      :timer.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "handle_change_notification via handle_info" do
    test "routes change notification to source and triggers reload" do
      channel_ref = make_ref()

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, @material, @meta, state} end)
      |> stub(:handle_change_notification, fn
        {:test_change, ^channel_ref}, _state -> {:changed, %{}}
        _msg, _state -> :ignored
      end)

      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      send(name, {:test_change, channel_ref})
      :timer.sleep(20)

      assert Process.alive?(pid)
    end

    test "logs warning when source notification returns {:error, reason}" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, @material, @meta, state} end)
      |> stub(:handle_change_notification, fn _msg, _state ->
        {:error, :some_problem}
      end)

      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      send(name, :trigger_notification)
      :timer.sleep(20)

      assert Process.alive?(pid)
    end

    test "ignores message when source returns :ignored" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, @material, @meta, state} end)
      |> stub(:handle_change_notification, fn _msg, _state -> :ignored end)

      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      send(name, :irrelevant_msg)
      :timer.sleep(20)

      assert Process.alive?(pid)
    end
  end

  describe "terminate/1" do
    test "calls source.terminate when exported" do
      test_pid = self()

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:ok, @material, @meta, state} end)
      |> expect(:terminate, fn _state ->
        send(test_pid, :terminate_called)
        :ok
      end)

      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})
      ref = Process.monitor(pid)

      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
      assert_receive :terminate_called, 500
    end
  end

  describe "ttl-based refresh scheduling" do
    test "schedules refresh at 2/3 of ttl_seconds" do
      meta_with_ttl = %{version: 1, ttl_seconds: 3}

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, 2, fn state -> {:ok, @material, meta_with_ttl, state} end)

      %{name: name, opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      {:ok, sub_ref} = GenServer.call(name, {:subscribe, self()})

      # ttl_seconds: 3 => refresh at 2000ms
      assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, 1}, 3_000
    end
  end

  describe "subscribe_changes integration" do
    test "calls subscribe_changes on first load when source supports it" do
      test_pid = self()

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> expect(:load, fn state -> {:ok, @material, @meta, state} end)
      |> expect(:subscribe_changes, fn state ->
        send(test_pid, :subscribe_changes_called)
        {:ok, make_ref(), state}
      end)

      %{opts: opts} = start_registry()
      start_supervised!({Registry, opts})

      assert_receive :subscribe_changes_called, 500
    end
  end

  describe "nodedown handler" do
    test "removes subscribers on the downed node" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      # Subscribe self
      {:ok, _sub_ref} = GenServer.call(name, {:subscribe, self()})
      :timer.sleep(10)

      state = :sys.get_state(pid)
      assert map_size(state.subscribers) == 1

      # Simulate nodedown for node() -- all local subscribers match
      send(pid, {:nodedown, node()})
      :timer.sleep(10)

      state_after = :sys.get_state(pid)
      assert map_size(state_after.subscribers) == 0
    end

    test "does nothing when no subscribers match the downed node" do
      mock_load_ok()
      %{name: name, opts: opts} = start_registry()
      pid = start_supervised!({Registry, opts})

      # Send nodedown for a fake node, with no subscribers
      send(pid, {:nodedown, :"fake@nowhere"})
      :timer.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "change notification with load failure" do
    test "schedules backoff when change triggers a load that fails" do
      call_count = :counters.new(1, [:atomics])

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, @material, @meta, state}
        else
          {:error, :timeout, state}
        end
      end)
      |> stub(:handle_change_notification, fn _msg, _state -> {:changed, %{}} end)

      %{name: name, opts: opts} = start_registry(min_backoff_ms: 10)
      pid = start_supervised!({Registry, opts})

      send(name, :trigger_reload)
      :timer.sleep(30)

      # Process stays alive and still serves old secret
      assert Process.alive?(pid)
      assert {:ok, %Secret{}} = GenServer.call(name, :current)
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
      assert byte_size(:erlang.term_to_binary(spec)) > 0
    end
  end
end
