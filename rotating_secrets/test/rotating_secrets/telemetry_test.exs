defmodule RotatingSecrets.TelemetryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias RotatingSecrets.Telemetry

  setup do
    test_pid = self()
    handler_id = "test-telemetry-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{test_pid: test_pid, handler_id: handler_id}
  end

  defp attach_listener(handler_id, event, test_pid) do
    :telemetry.attach(
      handler_id,
      event,
      fn ev, measurements, metadata, _ ->
        send(test_pid, {:telemetry, ev, measurements, metadata})
      end,
      nil
    )
  end

  describe "attach_default_handlers/0" do
    test "attaches without raising and returns :ok" do
      assert :ok = Telemetry.attach_default_handlers()
      :telemetry.detach("rotating_secrets-default-logger")
    end

    test "is idempotent — calling twice does not raise" do
      assert :ok = Telemetry.attach_default_handlers()
      assert :ok = Telemetry.attach_default_handlers()
      :telemetry.detach("rotating_secrets-default-logger")
    end
  end

  describe "event_names/0" do
    test "returns all 9 event name lists" do
      names = Telemetry.event_names()
      assert length(names) == 9
      assert [:rotating_secrets, :source, :load, :start] in names
      assert [:rotating_secrets, :source, :load, :stop] in names
      assert [:rotating_secrets, :source, :load, :exception] in names
      assert [:rotating_secrets, :rotation] in names
      assert [:rotating_secrets, :state_change] in names
      assert [:rotating_secrets, :subscriber_added] in names
      assert [:rotating_secrets, :subscriber_removed] in names
      assert [:rotating_secrets, :degraded] in names
      assert [:rotating_secrets, :dev_source_in_use] in names
    end
  end

  describe "emit_load_start/2" do
    test "fires [:rotating_secrets, :source, :load, :start] with name and source",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :source, :load, :start], pid)
      Telemetry.emit_load_start(:my_secret, MyApp.Source)

      assert_receive {:telemetry, [:rotating_secrets, :source, :load, :start], %{},
                      %{name: :my_secret, source: MyApp.Source}}
    end
  end

  describe "emit_load_stop/3" do
    test "fires with result :ok", %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :source, :load, :stop], pid)
      Telemetry.emit_load_stop(:my_secret, MyApp.Source, :ok)

      assert_receive {:telemetry, [:rotating_secrets, :source, :load, :stop], %{},
                      %{name: :my_secret, source: MyApp.Source, result: :ok}}
    end

    test "fires with result :error and reason", %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :source, :load, :stop], pid)
      Telemetry.emit_load_stop(:my_secret, MyApp.Source, {:error, :timeout})

      assert_receive {:telemetry, [:rotating_secrets, :source, :load, :stop], %{},
                      %{name: :my_secret, source: MyApp.Source, result: :error, reason: :timeout}}
    end
  end

  describe "emit_rotation/2" do
    test "fires [:rotating_secrets, :rotation] with version measurement",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :rotation], pid)
      Telemetry.emit_rotation(:my_secret, 42)

      assert_receive {:telemetry, [:rotating_secrets, :rotation], %{version: 42},
                      %{name: :my_secret}}
    end

    test "version can be nil", %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :rotation], pid)
      Telemetry.emit_rotation(:my_secret, nil)

      assert_receive {:telemetry, [:rotating_secrets, :rotation], %{version: nil},
                      %{name: :my_secret}}
    end
  end

  describe "emit_state_change/3" do
    test "fires [:rotating_secrets, :state_change] with from/to metadata",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :state_change], pid)
      Telemetry.emit_state_change(:my_secret, :loading, :valid)

      assert_receive {:telemetry, [:rotating_secrets, :state_change], %{},
                      %{name: :my_secret, from: :loading, to: :valid}}
    end
  end

  describe "emit_subscriber_added/1" do
    test "fires [:rotating_secrets, :subscriber_added]", %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :subscriber_added], pid)
      Telemetry.emit_subscriber_added(:my_secret)

      assert_receive {:telemetry, [:rotating_secrets, :subscriber_added], %{},
                      %{name: :my_secret}}
    end
  end

  describe "emit_subscriber_removed/2" do
    test "fires [:rotating_secrets, :subscriber_removed] with reason",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :subscriber_removed], pid)
      Telemetry.emit_subscriber_removed(:my_secret, :killed)

      assert_receive {:telemetry, [:rotating_secrets, :subscriber_removed], %{},
                      %{name: :my_secret, reason: :killed}}
    end
  end

  describe "emit_degraded/2" do
    test "fires [:rotating_secrets, :degraded] with reason", %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :degraded], pid)
      Telemetry.emit_degraded(:my_secret, :enoent)

      assert_receive {:telemetry, [:rotating_secrets, :degraded], %{},
                      %{name: :my_secret, reason: :enoent}}
    end
  end

  describe "emit_dev_source_in_use/2" do
    test "fires [:rotating_secrets, :dev_source_in_use] with source",
         %{handler_id: id, test_pid: pid} do
      attach_listener(id, [:rotating_secrets, :dev_source_in_use], pid)
      Telemetry.emit_dev_source_in_use(:my_secret, RotatingSecrets.Source.Env)

      assert_receive {:telemetry, [:rotating_secrets, :dev_source_in_use], %{},
                      %{name: :my_secret, source: RotatingSecrets.Source.Env}}
    end
  end
end
