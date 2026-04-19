defmodule RotatingSecrets.Source.FileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RotatingSecrets.Source.File, as: FileSource

  setup do
    dir = System.tmp_dir!() |> Path.join("rs_file_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "secret.txt")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: path}
  end

  describe "init/1" do
    test "succeeds with :file_watch mode (default)", %{path: path} do
      File.write!(path, "value")
      assert {:ok, state} = FileSource.init(path: path)
      assert state.path == path
      assert state.mode == :file_watch
      assert state.format == :raw
    end

    test "succeeds with {:interval, ms} mode", %{path: path} do
      File.write!(path, "value")
      assert {:ok, state} = FileSource.init(path: path, mode: {:interval, 1_000})
      assert state.mode == {:interval, 1_000}
    end

    test "succeeds with :json format", %{path: path} do
      File.write!(path, ~s({"key":"val"}))
      assert {:ok, state} = FileSource.init(path: path, format: :json)
      assert state.format == :json
    end

    test "returns {:error, {:invalid_option, {:mode, bad}}} for unknown mode", %{path: path} do
      assert {:error, {:invalid_option, {:mode, :bad}}} =
               FileSource.init(path: path, mode: :bad)
    end

    test "returns {:error, {:invalid_option, {:format, bad}}} for unknown format", %{path: path} do
      assert {:error, {:invalid_option, {:format, :bad}}} =
               FileSource.init(path: path, format: :bad)
    end

    test "logs warning when file is group-readable", %{path: path} do
      File.write!(path, "secret")
      File.chmod!(path, 0o640)

      log =
        capture_log(fn ->
          {:ok, _state} = FileSource.init(path: path)
        end)

      assert log =~ "group- or world-readable"
    end

    test "no warning when file is owner-only", %{path: path} do
      File.write!(path, "secret")
      File.chmod!(path, 0o600)

      log =
        capture_log(fn ->
          {:ok, _state} = FileSource.init(path: path)
        end)

      refute log =~ "group- or world-readable"
    end

    test "does not crash when file does not exist yet", %{path: path} do
      # init should succeed even if file is missing (load will return :enoent)
      assert {:ok, _state} = FileSource.init(path: path)
    end
  end

  describe "load/1" do
    test "reads file content and trims trailing whitespace", %{path: path} do
      File.write!(path, "my-secret\n")
      {:ok, state} = FileSource.init(path: path)
      assert {:ok, "my-secret", %{}, ^state} = FileSource.load(state)
    end

    test "trims trailing spaces and newlines", %{path: path} do
      File.write!(path, "value  \n  ")
      {:ok, state} = FileSource.init(path: path)
      assert {:ok, "value", %{}, ^state} = FileSource.load(state)
    end

    test "returns {:error, :enoent, state} when file is missing", %{path: path} do
      {:ok, state} = FileSource.init(path: path)
      assert {:error, :enoent, ^state} = FileSource.load(state)
    end

    test "decodes JSON when format is :json", %{path: path} do
      File.write!(path, ~s({"token":"abc123"}))
      {:ok, state} = FileSource.init(path: path, format: :json)
      assert {:ok, %{"token" => "abc123"}, %{}, ^state} = FileSource.load(state)
    end
  end

  describe "handle_change_notification/2 — :file_watch mode" do
    test "returns {:changed, state} for :modified on matching basename", %{path: path} do
      {:ok, state} = FileSource.init(path: path)

      msg = {:file_event, self(), {path, [:modified]}}
      assert {:changed, ^state} = FileSource.handle_change_notification(msg, state)
    end

    test "returns {:changed, state} for :moved_to on matching basename", %{path: path} do
      {:ok, state} = FileSource.init(path: path)

      msg = {:file_event, self(), {path, [:moved_to]}}
      assert {:changed, ^state} = FileSource.handle_change_notification(msg, state)
    end

    test "returns {:changed, state} for :created on matching basename", %{path: path} do
      {:ok, state} = FileSource.init(path: path)

      msg = {:file_event, self(), {path, [:created]}}
      assert {:changed, ^state} = FileSource.handle_change_notification(msg, state)
    end

    test "returns :ignored for different filename in same directory", %{dir: dir, path: path} do
      {:ok, state} = FileSource.init(path: path)

      other_path = Path.join(dir, "other.txt")
      msg = {:file_event, self(), {other_path, [:modified]}}
      assert :ignored = FileSource.handle_change_notification(msg, state)
    end

    test "returns :ignored for unrelated events", %{path: path} do
      {:ok, state} = FileSource.init(path: path)

      msg = {:file_event, self(), {path, [:deleted]}}
      assert :ignored = FileSource.handle_change_notification(msg, state)
    end

    test "returns :ignored for unrelated messages", %{path: path} do
      {:ok, state} = FileSource.init(path: path)
      assert :ignored = FileSource.handle_change_notification(:some_other_msg, state)
    end
  end

  describe "handle_change_notification/2 — {:interval, ms} mode" do
    test "returns {:changed, new_state} with new timer_ref and reschedules", %{path: path} do
      {:ok, state} = FileSource.init(path: path, mode: {:interval, 60_000})
      ref = make_ref()
      state_with_ref = %{state | timer_ref: ref}

      msg = {:file_interval_tick, ref}
      assert {:changed, new_state} = FileSource.handle_change_notification(msg, state_with_ref)
      assert new_state.timer_ref != ref
    end

    test "returns :ignored for wrong ref", %{path: path} do
      {:ok, state} = FileSource.init(path: path, mode: {:interval, 60_000})
      state_with_ref = %{state | timer_ref: make_ref()}
      msg = {:file_interval_tick, make_ref()}
      assert :ignored = FileSource.handle_change_notification(msg, state_with_ref)
    end
  end
end
