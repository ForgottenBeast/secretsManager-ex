defmodule RotatingSecrets.FileSourceIntegrationTest do
  @moduledoc """
  Integration tests: Source.File with real filesystem — atomic rename triggers
  reload in watch mode; concurrent reads during rotation see a valid value.
  """

  use ExUnit.Case, async: false

  alias RotatingSecrets.Secret
  alias RotatingSecrets.Source.File
  alias RotatingSecrets.Supervisor

  setup do
    start_supervised!(Supervisor)

    dir =
      Path.join(System.tmp_dir!(), "rs_int_#{System.unique_integer([:positive])}")

    Elixir.File.mkdir_p!(dir)
    path = Path.join(dir, "secret.txt")
    on_exit(fn -> Elixir.File.rm_rf!(dir) end)

    %{dir: dir, path: path}
  end

  test "atomic rename is picked up on next interval refresh", %{dir: dir, path: path} do
    Elixir.File.write!(path, "v1\n")

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"file_int_atomic_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: File,
        source_opts: [path: path, mode: {:interval, 60_000}]
      )

    {:ok, s1} = RotatingSecrets.current(name)
    assert Secret.expose(s1) == "v1"

    # Atomic rename: write to a temp file, then rename into place.
    # This is the canonical pattern used by Vault Agent, systemd-creds, etc.
    tmp = Path.join(dir, ".secret.tmp")
    Elixir.File.write!(tmp, "v2\n")
    Elixir.File.rename!(tmp, path)

    # Trigger the interval refresh manually
    registry_pid =
      GenServer.whereis({:via, Registry, {RotatingSecrets.ProcessRegistry, name}})

    send(registry_pid, :do_refresh)
    Process.sleep(50)

    {:ok, s2} = RotatingSecrets.current(name)
    assert Secret.expose(s2) == "v2"
  end

  test "concurrent reads during rotation always return a valid secret", %{path: path} do
    Elixir.File.write!(path, "concurrent-v1\n")

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"file_int_concurrent_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: File,
        source_opts: [path: path, mode: {:interval, 60_000}]
      )

    test_pid = self()

    # Spawn 30 concurrent readers
    for _ <- 1..30 do
      spawn(fn ->
        send(test_pid, {:read, RotatingSecrets.current(name)})
      end)
    end

    # Trigger a refresh concurrently with the readers
    registry_pid =
      GenServer.whereis({:via, Registry, {RotatingSecrets.ProcessRegistry, name}})

    send(registry_pid, :do_refresh)

    results =
      for _ <- 1..30 do
        receive do
          {:read, r} -> r
        after
          1_000 -> {:error, :timeout}
        end
      end

    # GenServer serialises reads and writes; every call must succeed
    for result <- results do
      assert {:ok, secret} = result
      assert is_binary(Secret.expose(secret))
    end
  end

  test "interval mode serves last-known-good when file is removed mid-rotation",
       %{path: path} do
    Elixir.File.write!(path, "good-value\n")

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"file_int_lgk_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

    {:ok, _pid} =
      RotatingSecrets.register(name,
        source: File,
        source_opts: [path: path, mode: {:interval, 60_000}]
      )

    {:ok, good} = RotatingSecrets.current(name)
    assert Secret.expose(good) == "good-value"

    # Remove file, then trigger refresh
    Elixir.File.rm!(path)
    registry_pid =
      GenServer.whereis({:via, Registry, {RotatingSecrets.ProcessRegistry, name}})

    send(registry_pid, :do_refresh)
    Process.sleep(50)

    # Registry must still serve the last-known-good value
    assert {:ok, stale} = RotatingSecrets.current(name)
    assert Secret.expose(stale) == "good-value"
  end
end
