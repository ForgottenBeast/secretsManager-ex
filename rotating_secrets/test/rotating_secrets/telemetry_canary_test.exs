defmodule RotatingSecrets.TelemetryCanaryTest do
  @moduledoc """
  Canary tests verifying that secret-bearing exception structs are sanitized
  before reaching telemetry events or log output (C1, C2, C3), plus a full
  lifecycle audit confirming no event exposes secret material (Test 8).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias RotatingSecrets.MockSource
  alias RotatingSecrets.Registry
  alias RotatingSecrets.Telemetry

  # A custom exception with a :token field that must never appear in telemetry
  defmodule CanaryException do
    defexception [:message, :token]
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    test_pid = self()
    handler_id = "canary-telemetry-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{test_pid: test_pid, handler_id: handler_id}
  end

  defp attach_listener(handler_id, event, test_pid) do
    :telemetry.attach(
      handler_id,
      event,
      fn _ev, _meas, metadata, _ -> send(test_pid, {:telemetry_event, metadata}) end,
      nil
    )
  end

  # ---------------------------------------------------------------------------
  # C1: emit_load_exception must not expose exception struct fields in :reason
  # ---------------------------------------------------------------------------

  describe "C1 — load_exception sanitization" do
    test "exception struct with :token field is sanitized; token absent from :reason",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :source, :load, :exception], pid)

      exception = %CanaryException{message: "load failed", token: "canary_c1_secret"}
      Telemetry.emit_load_exception(:test_secret, RotatingSecrets.Source.Env, :error, exception)

      assert_receive {:telemetry_event, metadata}
      refute inspect(metadata.reason) =~ "canary_c1_secret"
    end
  end

  # ---------------------------------------------------------------------------
  # C3: emit_load_stop error clause must not expose exception struct fields
  # ---------------------------------------------------------------------------

  describe "C3 — load_stop error sanitization" do
    test "exception struct with :token field is sanitized; token absent from :reason",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :source, :load, :stop], pid)

      exception = %CanaryException{message: "load error", token: "canary_c3_secret"}
      Telemetry.emit_load_stop(:test_secret, RotatingSecrets.Source.Env, {:error, exception})

      assert_receive {:telemetry_event, metadata}
      refute inspect(metadata.reason) =~ "canary_c3_secret"
    end
  end

  # ---------------------------------------------------------------------------
  # C2: handle_change_notification error is logged without leaking token
  # ---------------------------------------------------------------------------

  describe "C2 — registry notification error log sanitization" do
    setup do
      stub(MockSource, :terminate, fn _state -> :ok end)
      stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
      start_supervised!(RotatingSecrets.Supervisor)

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, "safe-value", %{version: 1}, state} end)

      :ok
    end

    test "handle_change_notification error reason with :token is not logged verbatim" do
      # unique test atom, not user-controlled
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"canary_c2_#{System.unique_integer([:positive])}"

      stub(MockSource, :handle_change_notification, fn _msg, _state ->
        {:error, %{token: "canary_c2_secret"}}
      end)

      opts = [
        name: name,
        source: MockSource,
        source_opts: [],
        fallback_interval_ms: 60_000
      ]

      start_supervised!({Registry, opts})

      log =
        capture_log(fn ->
          send(name, :some_change_notification)
          Process.sleep(30)
        end)

      refute log =~ "canary_c2_secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 8: Full lifecycle audit — no event exposes known secret values
  # ---------------------------------------------------------------------------

  describe "Test 8 — full lifecycle telemetry audit" do
    setup do
      stub(MockSource, :terminate, fn _state -> :ok end)
      stub(MockSource, :subscribe_changes, fn _state -> :not_supported end)
      start_supervised!(RotatingSecrets.Supervisor)

      :ok
    end

    test "no telemetry event metadata contains the secret material or sensitive opts" do
      # unique test atom, not user-controlled
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = :"audit_lifecycle_#{System.unique_integer([:positive])}"
      test_pid = self()

      handler_id = "audit-lifecycle-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach_many(
        handler_id,
        Telemetry.event_names(),
        fn _event, _meas, metadata, _ ->
          send(test_pid, {:audit_event, metadata})
        end,
        nil
      )

      MockSource
      |> stub(:init, fn _opts -> {:ok, %{}} end)
      |> stub(:load, fn state -> {:ok, "audit_material", %{version: 1}, state} end)

      opts = [
        name: name,
        source: MockSource,
        source_opts: [token: "audit_token"],
        fallback_interval_ms: 60_000
      ]

      start_supervised!({Registry, opts})
      Process.sleep(30)

      events = drain_audit_events([])

      for metadata <- events do
        serialized = inspect(metadata)

        refute serialized =~ "audit_material",
               "telemetry metadata exposed secret material: #{serialized}"

        refute serialized =~ "audit_token",
               "telemetry metadata exposed token: #{serialized}"
      end

      assert events != [], "expected at least one telemetry event during lifecycle"
    end
  end

  defp drain_audit_events(acc) do
    receive do
      {:audit_event, metadata} -> drain_audit_events([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
