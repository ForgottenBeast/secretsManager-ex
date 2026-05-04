defmodule RotatingSecrets.Source.SopsTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  import ExUnit.CaptureLog

  alias RotatingSecrets.Source.Sops

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ok_cmd(output), do: fn _bin, _args, _opts -> {output, 0} end
  defp error_cmd(code, output \\ "error"), do: fn _bin, _args, _opts -> {output, code} end

  defp valid_opts(overrides) do
    Keyword.merge(
      [
        path: "/tmp/secret.enc",
        mode: {:interval, 1000},
        cmd_fn: ok_cmd("decrypted")
      ],
      overrides
    )
  end

  defp init!(overrides \\ []) do
    overrides |> valid_opts() |> Sops.init() |> elem(1)
  end

  # ---------------------------------------------------------------------------
  # init/1 — option validation
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "accepts valid opts with defaults" do
      assert {:ok, state} = Sops.init(path: "/tmp/secret.enc", mode: {:interval, 1000})
      assert state.path == "/tmp/secret.enc"
      assert state.sops_binary == "sops"
      assert state.format == :raw
      assert state.mode == {:interval, 1000}
      assert state.sops_args == []
      assert state.timeout == 30_000
      assert is_function(state.cmd_fn, 3)
    end

    test "accepts :file_watch mode" do
      assert {:ok, state} = Sops.init(path: "/tmp/s.enc", mode: :file_watch)
      assert state.mode == :file_watch
    end

    test "accepts :json format" do
      assert {:ok, _} = Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, format: :json)
    end

    test "accepts custom sops_binary and sops_args" do
      assert {:ok, state} =
               Sops.init(
                 path: "/tmp/s.enc",
                 mode: {:interval, 500},
                 sops_binary: "/usr/local/bin/sops",
                 sops_args: ["--config", "/etc/sops.yaml"]
               )

      assert state.sops_binary == "/usr/local/bin/sops"
      assert state.sops_args == ["--config", "/etc/sops.yaml"]
    end

    test "returns error when :path is missing" do
      assert {:error, {:missing_option, :path}} = Sops.init(mode: {:interval, 500})
    end

    test "returns error when :path is empty string" do
      assert {:error, {:invalid_option, {:path, ""}}} =
               Sops.init(path: "", mode: {:interval, 500})
    end

    test "returns error when :path contains null byte" do
      assert {:error, {:invalid_option, {:path, _}}} =
               Sops.init(path: "/tmp/s\0ec", mode: {:interval, 500})
    end

    test "returns error when :path is not a binary" do
      assert {:error, {:invalid_option, {:path, 123}}} =
               Sops.init(path: 123, mode: {:interval, 500})
    end

    test "returns error when :sops_binary is empty" do
      assert {:error, {:invalid_option, {:sops_binary, ""}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, sops_binary: "")
    end

    test "returns error when :sops_binary contains null byte" do
      assert {:error, {:invalid_option, {:sops_binary, _}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, sops_binary: "sops\0")
    end

    test "returns error for invalid :format" do
      assert {:error, {:invalid_option, {:format, :yaml}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, format: :yaml)
    end

    test "returns error for invalid :mode atom" do
      assert {:error, {:invalid_option, {:mode, :poll}}} =
               Sops.init(path: "/tmp/s.enc", mode: :poll)
    end

    test "returns error for interval with non-positive ms" do
      assert {:error, {:invalid_option, {:mode, {:interval, 0}}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 0})
    end

    test "returns error when :sops_args is not a list" do
      assert {:error, {:invalid_option, {:sops_args, "--verbose"}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, sops_args: "--verbose")
    end

    test "returns error when :sops_args contains non-binary" do
      assert {:error, {:invalid_option, {:sops_args, _}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, sops_args: [:verbose])
    end

    test "returns error for invalid :timeout" do
      assert {:error, {:invalid_option, {:timeout, 0}}} =
               Sops.init(path: "/tmp/s.enc", mode: {:interval, 500}, timeout: 0)
    end
  end

  # ---------------------------------------------------------------------------
  # init/1 — permission warning
  # ---------------------------------------------------------------------------

  describe "init/1 permission warning" do
    test "emits warning when file has group-readable bits" do
      path = Path.join(System.tmp_dir!(), "sops_perm_test_#{System.unique_integer()}.enc")
      File.write!(path, "dummy")
      File.chmod!(path, 0o640)

      assert capture_log(fn ->
               {:ok, _} = Sops.init(path: path, mode: {:interval, 500})
             end) =~ "group- or world-readable"

      File.rm!(path)
    end

    test "no warning when file has strict permissions" do
      path = Path.join(System.tmp_dir!(), "sops_perm_strict_#{System.unique_integer()}.enc")
      File.write!(path, "dummy")
      File.chmod!(path, 0o600)

      log =
        capture_log(fn ->
          {:ok, _} = Sops.init(path: path, mode: {:interval, 500})
        end)

      refute log =~ "group- or world-readable"
      File.rm!(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load/1
  # ---------------------------------------------------------------------------

  describe "load/1" do
    test "success: returns material and content hash for :raw format" do
      state = init!(cmd_fn: ok_cmd("mysecret"))
      assert {:ok, "mysecret", meta, _state} = Sops.load(state)
      assert meta.version == nil
      assert meta.ttl_seconds == nil
      assert is_binary(meta.content_hash)
      assert String.length(meta.content_hash) == 64
    end

    test "success: :json format returns raw JSON binary (caller decodes)" do
      json = ~s({"password":"abc"})
      state = init!(format: :json, cmd_fn: ok_cmd(json))
      assert {:ok, ^json, _meta, _state} = Sops.load(state)
    end

    test "content hash is SHA-256 hex of raw output" do
      output = "secret_value"
      state = init!(cmd_fn: ok_cmd(output))
      {:ok, _material, meta, _state} = Sops.load(state)
      raw = :crypto.hash(:sha256, output)
      expected = Base.encode16(raw, case: :lower)
      assert meta.content_hash == expected
    end

    test "exit 100 returns :not_found" do
      state = init!(cmd_fn: error_cmd(100))
      assert {:error, :not_found, _state} = Sops.load(state)
    end

    test "non-zero exit returns {:sops_error, code, output}" do
      state = init!(cmd_fn: error_cmd(1, "decryption failed"))
      assert {:error, {:sops_error, 1, "decryption failed"}, _state} = Sops.load(state)
    end

    test "timeout returns :sops_timeout" do
      slow_cmd = fn _bin, _args, _opts ->
        Process.sleep(200)
        {"output", 0}
      end

      state = init!(cmd_fn: slow_cmd, timeout: 50)
      assert {:error, :sops_timeout, _state} = Sops.load(state)
    end

    test "passes sops_args before --decrypt flag" do
      test_pid = self()

      capture_cmd = fn bin, args, _opts ->
        send(test_pid, {:cmd_called, bin, args})
        {"output", 0}
      end

      state = init!(sops_args: ["--config", "/etc/sops.yaml"], cmd_fn: capture_cmd)
      Sops.load(state)

      assert_received {:cmd_called, "sops",
                       [
                         "--config",
                         "/etc/sops.yaml",
                         "--decrypt",
                         "--output-type",
                         "binary",
                         "/tmp/secret.enc"
                       ]}
    end

    test "uses --output-type json for :json format" do
      test_pid = self()

      capture_cmd = fn _bin, args, _opts ->
        send(test_pid, {:args, args})
        {"[]", 0}
      end

      state = init!(format: :json, cmd_fn: capture_cmd)
      Sops.load(state)

      assert_received {:args, args}
      assert "--output-type" in args
      json_idx = Enum.find_index(args, &(&1 == "--output-type"))
      assert Enum.at(args, json_idx + 1) == "json"
    end

    test "uses --output-type binary for :raw format" do
      test_pid = self()

      capture_cmd = fn _bin, args, _opts ->
        send(test_pid, {:args, args})
        {"raw", 0}
      end

      state = init!(cmd_fn: capture_cmd)
      Sops.load(state)

      assert_received {:args, args}
      bin_idx = Enum.find_index(args, &(&1 == "--output-type"))
      assert Enum.at(args, bin_idx + 1) == "binary"
    end
  end

  # ---------------------------------------------------------------------------
  # subscribe_changes/1 and handle_change_notification/2 — interval mode
  # ---------------------------------------------------------------------------

  describe "subscribe_changes/1 + handle_change_notification/2 (interval)" do
    test "subscribe_changes returns a ref and schedules timer" do
      state = init!()
      assert {:ok, ref, new_state} = Sops.subscribe_changes(state)
      assert is_reference(ref)
      assert new_state.timer_ref == ref
    end

    test "handle_change_notification returns {:changed, _} on tick with matching ref" do
      state = init!()
      {:ok, ref, subscribed_state} = Sops.subscribe_changes(state)

      assert {:changed, _new_state} =
               Sops.handle_change_notification({:sops_interval_tick, ref}, subscribed_state)
    end

    test "handle_change_notification returns :ignored on stale ref" do
      state = init!()
      {:ok, _ref, subscribed_state} = Sops.subscribe_changes(state)
      stale_ref = make_ref()

      assert :ignored =
               Sops.handle_change_notification({:sops_interval_tick, stale_ref}, subscribed_state)
    end

    test "handle_change_notification re-arms timer on tick" do
      state = init!()
      {:ok, ref, subscribed_state} = Sops.subscribe_changes(state)

      {:changed, new_state} =
        Sops.handle_change_notification({:sops_interval_tick, ref}, subscribed_state)

      assert is_reference(new_state.timer_ref)
      refute new_state.timer_ref == ref
    end

    test "handle_change_notification ignores unrelated messages" do
      state = init!()
      assert :ignored = Sops.handle_change_notification(:something_else, state)
    end
  end

  # ---------------------------------------------------------------------------
  # terminate/1
  # ---------------------------------------------------------------------------

  describe "terminate/1" do
    test "stops watcher_pid when present" do
      {:ok, agent} = Agent.start_link(fn -> :ok end)
      state = %{watcher_pid: agent, timer_ref: nil}
      assert :ok = Sops.terminate(state)
      refute Process.alive?(agent)
    end

    test "cancels timer_ref when present" do
      ref = make_ref()
      state = %{watcher_pid: nil, timer_ref: ref}
      assert :ok = Sops.terminate(state)
    end

    test "returns :ok with nil state" do
      assert :ok = Sops.terminate(%{watcher_pid: nil, timer_ref: nil})
    end
  end

  # ---------------------------------------------------------------------------
  # Property-based tests
  # ---------------------------------------------------------------------------

  describe "init/1 property: invalid mode always returns error" do
    property "arbitrary non-mode atoms fail" do
      check all(mode <- atom(:alphanumeric), mode not in [:file_watch]) do
        assert {:error, {:invalid_option, {:mode, ^mode}}} =
                 Sops.init(path: "/tmp/s.enc", mode: mode)
      end
    end

    property "interval with non-positive ms fails" do
      check all(ms <- integer(), ms <= 0) do
        assert {:error, {:invalid_option, {:mode, {:interval, ^ms}}}} =
                 Sops.init(path: "/tmp/s.enc", mode: {:interval, ms})
      end
    end
  end

  describe "load/1 property: non-zero exit always returns error tuple" do
    property "any non-zero, non-100 exit code returns {:sops_error, code, _}" do
      check all(
              code <- integer(1..255),
              code != 100,
              output <- binary()
            ) do
        state = init!(cmd_fn: error_cmd(code, output))
        assert {:error, {:sops_error, ^code, ^output}, _} = Sops.load(state)
      end
    end
  end
end
