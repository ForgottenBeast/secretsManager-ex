defmodule RotatingSecrets.SupervisorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Mox

  alias RotatingSecrets.{MockSource, Supervisor}

  @material "super-secret"
  @meta %{version: 1}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    start_supervised!(Supervisor)
    :ok
  end

  describe "supervision tree" do
    test "ProcessRegistry is alive after start" do
      assert Process.whereis(RotatingSecrets.ProcessRegistry) != nil
    end

    test "DynamicSupervisor is alive after start" do
      assert Process.whereis(RotatingSecrets.DynamicSupervisor) != nil
    end
  end

  describe "register/2" do
    test "starts a secret process reachable via :current" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, @material, @meta, state} end)

      assert {:ok, pid} = Supervisor.register(:test_secret, source: MockSource)
      assert Process.alive?(pid)

      assert {:ok, secret} = GenServer.call({:via, Registry, {RotatingSecrets.ProcessRegistry, :test_secret}}, :current)
      assert RotatingSecrets.Secret.expose(secret) == @material
    end

    test "returns {:error, reason} when source.init fails" do
      MockSource
      |> stub(:init, fn _opts -> {:error, :bad_config} end)

      assert {:error, _} = Supervisor.register(:bad_secret, source: MockSource)
    end

    test "accepts :registry_via to override server_name" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, @material, @meta, state} end)

      custom_via = {:via, Registry, {RotatingSecrets.ProcessRegistry, :via_secret}}
      assert {:ok, pid} = Supervisor.register(:via_secret, source: MockSource, registry_via: custom_via)
      assert Process.alive?(pid)
    end
  end

  describe "deregister/1" do
    test "terminates the registered process" do
      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, @material, @meta, state} end)

      {:ok, pid} = Supervisor.register(:deregister_secret, source: MockSource)
      ref = Process.monitor(pid)

      assert :ok = Supervisor.deregister(:deregister_secret)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end

    test "returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = Supervisor.deregister(:no_such_secret)
    end
  end
end
