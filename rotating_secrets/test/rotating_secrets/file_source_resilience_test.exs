defmodule RotatingSecrets.FileSourceResilienceTest do
  @moduledoc """
  Resilience tests: Source.File in interval mode handles missing files on
  refresh without crashing, and retries on the next tick.
  """

  use ExUnit.Case, async: false

  @moduletag :resilience

  import Mox

  alias RotatingSecrets.{MockSource, Registry, Secret, Source.File, Supervisor}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(MockSource, :terminate, fn _state -> :ok end)
    stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
    start_supervised!(Supervisor)

    dir = System.tmp_dir!() |> Path.join("rs_resilience_#{System.unique_integer([:positive])}")
    Elixir.File.mkdir_p!(dir)
    path = Path.join(dir, "secret.txt")
    on_exit(fn -> Elixir.File.rm_rf!(dir) end)

    %{dir: dir, path: path}
  end

  test "Source.File load/1 returns {:error, :enoent, state} when file is missing on refresh",
       %{path: path} do
    {:ok, state} = File.init(path: path, mode: {:interval, 60_000})

    # File does not exist — load should return :enoent without raising
    assert {:error, :enoent, ^state} = File.load(state)
  end

  test "interval-mode registry stays alive after missing-file refresh", %{path: path} do
    Elixir.File.write!(path, "initial-secret\n")

    name = :"file_resilience_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: File,
        source_opts: [path: path, mode: {:interval, 60_000}]
      )

    {:ok, secret} = RotatingSecrets.current(name)
    assert Secret.expose(secret) == "initial-secret"

    # Delete the file to simulate missing file on refresh
    Elixir.File.rm!(path)

    state = :sys.get_state({:via, Elixir.Registry, {RotatingSecrets.ProcessRegistry, name}})
    registry_pid = GenServer.whereis({:via, Elixir.Registry, {RotatingSecrets.ProcessRegistry, name}})

    send(registry_pid, :do_refresh)
    Process.sleep(30)

    # Registry must still be alive
    assert Process.alive?(registry_pid)

    # Must still serve last-known-good
    assert {:ok, secret2} = RotatingSecrets.current(name)
    assert Secret.expose(secret2) == "initial-secret"
    _ = state
  end

  test "interval-mode registry recovers after file is restored", %{path: path} do
    Elixir.File.write!(path, "v1\n")

    name = :"file_recovery_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: File,
        source_opts: [path: path, mode: {:interval, 60_000}]
      )

    {:ok, s1} = RotatingSecrets.current(name)
    assert Secret.expose(s1) == "v1"

    # Remove file, trigger refresh
    Elixir.File.rm!(path)
    registry_pid = GenServer.whereis({:via, Elixir.Registry, {RotatingSecrets.ProcessRegistry, name}})
    send(registry_pid, :do_refresh)
    Process.sleep(30)

    # Restore file with new value
    Elixir.File.write!(path, "v2\n")
    send(registry_pid, :do_refresh)
    Process.sleep(30)

    {:ok, s2} = RotatingSecrets.current(name)
    assert Secret.expose(s2) == "v2"
  end
end
