defmodule RotatingSecrets.Testing do
  @moduledoc """
  ExUnit assertion helpers for `rotating_secrets`.

  Import this module in your test file to get `assert_rotated/2`,
  `refute_rotated/2`, and `assert_telemetry_event/2`:

      defmodule MyApp.SecretTest do
        use ExUnit.Case
        import RotatingSecrets.Testing

        setup do
          start_supervised!(RotatingSecrets.Supervisor)
          start_supervised!(RotatingSecrets.Testing.Supervisor)
          :ok
        end

        test "rotation is delivered" do
          RotatingSecrets.register(:pw,
            source: RotatingSecrets.Source.Controllable,
            source_opts: [name: :pw, initial_value: "v1"]
          )
          {:ok, sub_ref} = RotatingSecrets.subscribe(:pw)

          RotatingSecrets.Source.Controllable.rotate(:pw, "v2")

          assert_rotated(:pw, sub_ref)
        end
      end

  ## Full PRD required before implementation

  This module is a **planning stub**.  The signatures and semantics below are
  provisional; a dedicated PRD for `rotating_secrets_testing` must be written
  and approved before the full implementation is authored.  The current bodies
  provide the minimal surface needed to validate integration patterns.
  """

  @default_timeout_ms 500
  @default_refute_timeout_ms 100

  @doc """
  Asserts that a `{:rotating_secret_rotated, sub_ref, name, _version}` message
  is received within `timeout` milliseconds.

  `sub_ref` is the reference returned by `RotatingSecrets.subscribe/1`.

  ## Examples

      {:ok, sub_ref} = RotatingSecrets.subscribe(:api_key)
      RotatingSecrets.Source.Controllable.rotate(:api_key, "new-value")
      assert_rotated(:api_key, sub_ref)

      # With a custom timeout (milliseconds):
      assert_rotated(:api_key, sub_ref, 1_000)
  """
  defmacro assert_rotated(name, sub_ref, timeout \\ @default_timeout_ms) do
    quote do
      ExUnit.Assertions.assert_receive(
        {:rotating_secret_rotated, ^unquote(sub_ref), ^unquote(name), _version},
        unquote(timeout),
        "expected a rotation notification for #{inspect(unquote(name))} but none arrived within #{unquote(timeout)}ms"
      )
    end
  end

  @doc """
  Asserts that no `{:rotating_secret_rotated, sub_ref, name, _version}` message
  is received within `timeout` milliseconds.

  ## Examples

      {:ok, sub_ref} = RotatingSecrets.subscribe(:api_key)
      # Expect no rotation to arrive:
      refute_rotated(:api_key, sub_ref)

      # With a custom timeout (milliseconds):
      refute_rotated(:api_key, sub_ref, 200)
  """
  defmacro refute_rotated(name, sub_ref, timeout \\ @default_refute_timeout_ms) do
    quote do
      ExUnit.Assertions.refute_receive(
        {:rotating_secret_rotated, ^unquote(sub_ref), ^unquote(name), _version},
        unquote(timeout),
        "expected no rotation notification for #{inspect(unquote(name))} but one arrived within #{unquote(timeout)}ms"
      )
    end
  end

  @doc """
  Asserts that a telemetry event matching `event_name` is emitted within
  `timeout` milliseconds.

  Attaches a temporary handler for the duration of the assertion.  The handler
  is detached after the assertion regardless of outcome.

  `event_name` is a list of atoms, e.g. `[:rotating_secrets, :rotation]`.

  This function is provisional; the full API will be defined in the rotating_secrets_testing PRD.

  ## Examples

      assert_telemetry_event([:rotating_secrets, :rotation])

      # With a custom timeout (milliseconds):
      assert_telemetry_event([:rotating_secrets, :rotation], 1_000)
  """
  @spec assert_telemetry_event(
          event_name :: [atom()],
          timeout :: non_neg_integer()
        ) :: term()
  def assert_telemetry_event(event_name, timeout \\ @default_timeout_ms)
      when is_list(event_name) do
    test_pid = self()
    handler_id = {__MODULE__, event_name, make_ref()}

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    try do
      receive do
        {:telemetry_event, ^event_name, _measurements, _metadata} -> :ok
      after
        timeout ->
          ExUnit.Assertions.flunk(
            "expected telemetry event #{inspect(event_name)} but it was not emitted within #{timeout}ms"
          )
      end
    after
      :telemetry.detach(handler_id)
    end
  end
end
