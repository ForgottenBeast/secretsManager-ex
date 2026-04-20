defmodule RotatingSecrets.LogCaptureTest do
  @moduledoc """
  Confirms that no code path in RotatingSecrets logs the raw secret value.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias RotatingSecrets.MockSource
  alias RotatingSecrets.Registry
  alias RotatingSecrets.Supervisor

  require Logger

  setup :set_mox_global
  setup :verify_on_exit!

  @secret_material "SUPER_SECRET_CANARY_VALUE_DO_NOT_LOG"
  @meta %{version: 1}

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    start_supervised!(Supervisor)
    :ok
  end

  defp start_registry_with_secret do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"log_test_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

    MockSource
    |> stub(:init, fn _opts -> {:ok, %{}} end)
    |> stub(:load, fn state -> {:ok, @secret_material, @meta, state} end)

    opts = [name: name, source: MockSource, source_opts: [], fallback_interval_ms: 60_000]
    start_supervised!({Registry, opts})
    name
  end

  describe "secret value does not appear in logs" do
    test "during initial load" do
      log =
        capture_log(fn ->
          start_registry_with_secret()
          Process.sleep(20)
        end)

      refute log =~ @secret_material
    end

    test "during rotation refresh" do
      name = start_registry_with_secret()

      log =
        capture_log(fn ->
          send(name, :do_refresh)
          Process.sleep(20)
        end)

      refute log =~ @secret_material
    end

    test "during subscriber notification" do
      name = start_registry_with_secret()
      {:ok, _sub_ref} = GenServer.call(name, {:subscribe, self()})

      log =
        capture_log(fn ->
          send(name, :do_refresh)
          Process.sleep(20)
        end)

      refute log =~ @secret_material
    end

    test "Secret.inspect does not include the value" do
      {:ok, secret} = GenServer.call(start_registry_with_secret(), :current)
      log = capture_log(fn -> secret |> inspect() |> Logger.debug() end)
      refute log =~ @secret_material
    end
  end
end
