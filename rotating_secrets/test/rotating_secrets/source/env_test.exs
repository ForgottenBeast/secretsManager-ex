defmodule RotatingSecrets.Source.EnvTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # credo:disable-for-next-line Credo.Check.Readability.AliasAs
  alias RotatingSecrets.Source.Env, as: EnvSource

  @var_name "RS_TEST_SECRET_#{System.unique_integer([:positive])}"

  setup do
    on_exit(fn -> System.delete_env(@var_name) end)
    :ok
  end

  describe "init/1" do
    test "succeeds with a valid var_name string" do
      assert {:ok, state} = EnvSource.init(var_name: @var_name, name: :test_env_secret)
      assert state.var_name == @var_name
    end

    test "returns {:error, {:invalid_option, {:var_name, _}}} when var_name is not a string" do
      assert {:error, {:invalid_option, {:var_name, 42}}} =
               EnvSource.init(var_name: 42)
    end

    test "emits [:rotating_secrets, :dev_source_in_use] telemetry" do
      test_pid = self()
      handler_id = "env-test-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:rotating_secrets, :dev_source_in_use],
        fn _ev, _m, meta, _ -> send(test_pid, {:telemetry, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      EnvSource.init(var_name: @var_name, name: :env_telemetry_test)

      assert_receive {:telemetry, %{name: :env_telemetry_test, source: EnvSource}}
    end

    test "logs a warning about production usage" do
      log =
        capture_log(fn ->
          EnvSource.init(var_name: @var_name, name: :env_log_test)
        end)

      assert log =~ "not recommended for production"
    end
  end

  describe "load/1" do
    test "returns {:ok, value, %{}, state} when env var is set" do
      System.put_env(@var_name, "test-secret-value")
      {:ok, state} = EnvSource.init(var_name: @var_name, name: :load_test)

      assert {:ok, "test-secret-value", %{}, ^state} = EnvSource.load(state)
    end

    test "returns {:error, :enoent, state} when env var is not set" do
      {:ok, state} = EnvSource.init(var_name: @var_name, name: :load_missing_test)

      assert {:error, :enoent, ^state} = EnvSource.load(state)
    end
  end

  describe "subscribe_changes/1" do
    test "is not exported by Source.Env" do
      refute function_exported?(EnvSource, :subscribe_changes, 1)
    end
  end
end
