defmodule RotatingSecrets.Source.Sops.TransitTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  import ExUnit.CaptureLog

  alias RotatingSecrets.Source.Sops.Transit

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ok_cmd(output), do: fn _bin, _args, _opts -> {output, 0} end
  defp error_cmd(code, out \\ "error"), do: fn _bin, _args, _opts -> {out, code} end

  defp valid_key, do: :crypto.strong_rand_bytes(32)

  defp valid_opts(overrides) do
    Keyword.merge(
      [path: "/tmp/key.enc", mode: {:interval, 1000}, cmd_fn: ok_cmd(valid_key())],
      overrides
    )
  end

  defp init!(overrides \\ []) do
    overrides |> valid_opts() |> Transit.init() |> elem(1)
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "accepts valid opts" do
      assert {:ok, state} = Transit.init(path: "/tmp/key.enc", mode: {:interval, 500})
      assert state.path == "/tmp/key.enc"
      assert state.sops_binary == "sops"
      refute Map.has_key?(state, :format)
    end

    test "no :format option in state" do
      {:ok, state} = Transit.init(path: "/tmp/key.enc", mode: {:interval, 500})
      refute Map.has_key?(state, :format)
    end

    test "returns error for missing :path" do
      assert {:error, {:missing_option, :path}} = Transit.init(mode: {:interval, 500})
    end

    test "returns error for null byte in :path" do
      assert {:error, {:invalid_option, {:path, _}}} =
               Transit.init(path: "/tmp/k\0ey.enc", mode: {:interval, 500})
    end

    test "returns error for invalid :mode" do
      assert {:error, {:invalid_option, {:mode, :bad}}} =
               Transit.init(path: "/tmp/key.enc", mode: :bad)
    end

    test "returns error for non-list :sops_args" do
      assert {:error, {:invalid_option, {:sops_args, "--v"}}} =
               Transit.init(path: "/tmp/key.enc", mode: {:interval, 500}, sops_args: "--v")
    end
  end

  # ---------------------------------------------------------------------------
  # init/1 — permission warning
  # ---------------------------------------------------------------------------

  describe "init/1 permission warning" do
    test "warns on group-readable key file" do
      path = Path.join(System.tmp_dir!(), "transit_key_perm_#{System.unique_integer()}.enc")
      File.write!(path, "x")
      File.chmod!(path, 0o640)

      assert capture_log(fn ->
               {:ok, _} = Transit.init(path: path, mode: {:interval, 500})
             end) =~ "group- or world-readable"

      File.rm!(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load/1 — key validation
  # ---------------------------------------------------------------------------

  describe "load/1" do
    test "success with 32-byte key material" do
      key = valid_key()
      state = init!(cmd_fn: ok_cmd(key))
      assert {:ok, ^key, meta, _state} = Transit.load(state)
      assert meta.key_length == 32
      assert meta.version == nil
      assert meta.ttl_seconds == nil
      assert is_binary(meta.content_hash)
    end

    test "returns :invalid_key_length for 31-byte output" do
      state = init!(cmd_fn: ok_cmd(:crypto.strong_rand_bytes(31)))
      assert {:error, :invalid_key_length, _state} = Transit.load(state)
    end

    test "returns :invalid_key_length for 33-byte output" do
      state = init!(cmd_fn: ok_cmd(:crypto.strong_rand_bytes(33)))
      assert {:error, :invalid_key_length, _state} = Transit.load(state)
    end

    test "returns :invalid_key_length for empty output" do
      state = init!(cmd_fn: ok_cmd(""))
      assert {:error, :invalid_key_length, _state} = Transit.load(state)
    end

    test "exit 100 returns :not_found" do
      state = init!(cmd_fn: error_cmd(100))
      assert {:error, :not_found, _state} = Transit.load(state)
    end

    test "non-zero exit returns {:sops_error, code, output}" do
      state = init!(cmd_fn: error_cmd(2, "key access denied"))
      assert {:error, {:sops_error, 2, "key access denied"}, _state} = Transit.load(state)
    end

    test "timeout returns :sops_timeout" do
      slow = fn _b, _a, _o ->
        Process.sleep(200)
        {"x", 0}
      end

      state = init!(cmd_fn: slow, timeout: 50)
      assert {:error, :sops_timeout, _state} = Transit.load(state)
    end

    test "always uses --output-type binary" do
      test_pid = self()
      key = valid_key()

      capture_cmd = fn _bin, args, _opts ->
        send(test_pid, {:args, args})
        {key, 0}
      end

      state = init!(cmd_fn: capture_cmd)
      Transit.load(state)

      assert_received {:args, args}
      bin_idx = Enum.find_index(args, &(&1 == "--output-type"))
      assert Enum.at(args, bin_idx + 1) == "binary"
    end
  end

  # ---------------------------------------------------------------------------
  # subscribe_changes / handle_change_notification / terminate
  # ---------------------------------------------------------------------------

  describe "subscribe_changes + handle_change_notification (interval)" do
    test "subscribe_changes returns ref" do
      state = init!()
      assert {:ok, ref, new_state} = Transit.subscribe_changes(state)
      assert is_reference(ref)
      assert new_state.timer_ref == ref
    end

    test "tick with matching ref returns {:changed, _}" do
      state = init!()
      {:ok, ref, subscribed} = Transit.subscribe_changes(state)

      assert {:changed, _} =
               Transit.handle_change_notification({:sops_interval_tick, ref}, subscribed)
    end

    test "stale ref returns :ignored" do
      state = init!()
      {:ok, _ref, subscribed} = Transit.subscribe_changes(state)

      assert :ignored =
               Transit.handle_change_notification({:sops_interval_tick, make_ref()}, subscribed)
    end
  end

  describe "terminate/1" do
    test "returns :ok" do
      state = init!()
      assert :ok = Transit.terminate(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Property-based
  # ---------------------------------------------------------------------------

  describe "load/1 property: wrong key lengths always fail" do
    property "any size != 32 fails" do
      check all(
              size <- integer(0..64),
              size != 32
            ) do
        key = :crypto.strong_rand_bytes(size)
        state = init!(cmd_fn: ok_cmd(key))
        assert {:error, :invalid_key_length, _} = Transit.load(state)
      end
    end
  end
end
