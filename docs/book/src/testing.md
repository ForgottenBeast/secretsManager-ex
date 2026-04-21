# Testing

This page describes how to write tests for application code that reads from RotatingSecrets. Three approaches cover different test granularities: Mox for unit tests, `Source.Memory` for integration tests, and `Source.Controllable` for full rotation-flow tests.

## Approach 1: MockSource with Mox

Use Mox to stub the `RotatingSecrets.Source` behaviour in unit tests. This approach starts a real Registry process but uses a controlled fake source, so there is no I/O and no timing uncertainty.

### Setup

In `test/test_helper.exs`:

```elixir
Mox.defmock(MyApp.MockSource, for: RotatingSecrets.Source)
ExUnit.start()
```

### Example test

```elixir
defmodule MyApp.SecretConsumerTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "reads the current secret value" do
    MyApp.MockSource
    |> expect(:init, fn _opts -> {:ok, %{}} end)
    |> expect(:load, fn state ->
      {:ok, "s3cr3t-value", %{version: 1}, state}
    end)

    start_supervised!(RotatingSecrets.Supervisor)

    {:ok, _} = RotatingSecrets.register(:test_secret,
      source: MyApp.MockSource,
      source_opts: []
    )

    {:ok, secret} = RotatingSecrets.current(:test_secret)
    assert RotatingSecrets.Secret.expose(secret) == "s3cr3t-value"
  end

  test "returns error when source fails permanently" do
    MyApp.MockSource
    |> expect(:init, fn _opts -> {:error, :not_found} end)

    start_supervised!(RotatingSecrets.Supervisor)

    assert {:error, :not_found} = RotatingSecrets.register(:missing_secret,
      source: MyApp.MockSource,
      source_opts: []
    )
  end
end
```

Each test that calls `start_supervised!(RotatingSecrets.Supervisor)` gets a fresh supervisor stopped automatically at the end of the test. Secrets registered in one test do not bleed into another.

To test retry behaviour, stub `load/1` to fail on the first call and succeed on the second:

```elixir
test "retries after transient failure" do
  attempt = :counters.new(1, [])

  MyApp.MockSource
  |> expect(:init, fn _opts -> {:ok, %{}} end)
  |> expect(:load, 2, fn state ->
    if :counters.get(attempt, 1) == 0 do
      :counters.add(attempt, 1, 1)
      {:error, :timeout, state}
    else
      {:ok, "value", %{version: 1}, state}
    end
  end)

  start_supervised!(RotatingSecrets.Supervisor)

  {:ok, _} = RotatingSecrets.register(:retry_secret,
    source: MyApp.MockSource,
    source_opts: [],
    min_backoff_ms: 10,
    max_backoff_ms: 50
  )

  # Wait for the retry to succeed
  :timer.sleep(100)

  {:ok, secret} = RotatingSecrets.current(:retry_secret)
  assert RotatingSecrets.Secret.expose(secret) == "value"
end
```

## Approach 2: Source.Memory for integration tests

`Source.Memory` holds a value in-process via an `Agent` and exposes `update/2` for programmatic rotation. It implements `subscribe_changes/1`, so rotation notifications are delivered synchronously without timing uncertainty.

### Example test

```elixir
defmodule MyApp.RotationHandlerTest do
  use ExUnit.Case, async: false   # Source.Memory uses named Agent

  setup do
    start_supervised!(RotatingSecrets.Supervisor)
    :ok
  end

  test "subscriber receives notification when value changes" do
    {:ok, _} = RotatingSecrets.register(:rotating_key,
      source: RotatingSecrets.Source.Memory,
      source_opts: [name: :rotating_key, initial_value: "initial"]
    )

    {:ok, sub_ref} = RotatingSecrets.subscribe(:rotating_key)

    RotatingSecrets.Source.Memory.update(:rotating_key, "rotated")

    assert_receive {:rotating_secret_rotated, ^sub_ref, :rotating_key, _version}, 1_000

    {:ok, secret} = RotatingSecrets.current(:rotating_key)
    assert RotatingSecrets.Secret.expose(secret) == "rotated"
  end

  test "handles multiple sequential rotations" do
    {:ok, _} = RotatingSecrets.register(:seq_key,
      source: RotatingSecrets.Source.Memory,
      source_opts: [name: :seq_key, initial_value: "v1"]
    )

    {:ok, sub_ref} = RotatingSecrets.subscribe(:seq_key)

    for value <- ["v2", "v3", "v4"] do
      RotatingSecrets.Source.Memory.update(:seq_key, value)
      assert_receive {:rotating_secret_rotated, ^sub_ref, :seq_key, _}, 1_000
      {:ok, secret} = RotatingSecrets.current(:seq_key)
      assert RotatingSecrets.Secret.expose(secret) == value
    end
  end
end
```

`Source.Memory` starts an Agent registered in `RotatingSecrets.ProcessRegistry`. Use `async: false` or distinct secret name atoms to avoid name collisions between tests.

## Approach 3: Source.Controllable (provisional)

`Source.Controllable` (from `rotating_secrets_testing`) gives fine-grained control over what `load/1` returns on each call, without running a real external process. It is useful for testing error handling, retry logic, and version ordering.

> `rotating_secrets_testing` and `Source.Controllable` are provisional. The API is stabilising. Check the package changelog before upgrading.

### Setup

Add to `mix.exs` under `only: [:test]`:

```elixir
{:rotating_secrets_testing, "~> 0.1", only: :test}
```

### Example test

```elixir
defmodule MyApp.RetryTest do
  use ExUnit.Case, async: false
  use RotatingSecrets.Testing   # imports test macros

  setup do
    start_supervised!(RotatingSecrets.Testing.Supervisor)
    :ok
  end

  test "retries on transient error and succeeds" do
    {:ok, ctrl} = RotatingSecrets.Source.Controllable.start(name: :ctrl_secret)

    # Queue two responses: first a transient error, then a valid value
    RotatingSecrets.Source.Controllable.enqueue(ctrl, {:error, :timeout})
    RotatingSecrets.Source.Controllable.enqueue(ctrl, {:ok, "final-value", %{version: 1}})

    {:ok, _} = RotatingSecrets.register(:ctrl_secret,
      source: RotatingSecrets.Source.Controllable,
      source_opts: [controller: ctrl],
      min_backoff_ms: 5,
      max_backoff_ms: 20
    )

    assert_secret_value(:ctrl_secret, "final-value", timeout: 200)
  end
end
```

## Property testing with Generators

The library ships `RotatingSecrets.Generators` in `test/support/generators.ex` with StreamData generators for common inputs. Add `stream_data` to your test dependencies to use them.

```elixir
defmodule MyApp.RegistryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import RotatingSecrets.Generators

  property "current/1 always returns the registered value" do
    check all(
            name <- secret_name(),
            value <- secret_value()
          ) do
      start_supervised!(RotatingSecrets.Supervisor)

      Mox.stub(MyApp.MockSource, :init, fn _ -> {:ok, %{}} end)
      Mox.stub(MyApp.MockSource, :load, fn state ->
        {:ok, value, %{version: 1}, state}
      end)

      {:ok, _} = RotatingSecrets.register(name,
        source: MyApp.MockSource,
        source_opts: []
      )

      {:ok, secret} = RotatingSecrets.current(name)
      assert RotatingSecrets.Secret.expose(secret) == value

      stop_supervised!(RotatingSecrets.Supervisor)
    end
  end
end
```

Available generators:

| Generator | Returns |
|---|---|
| `secret_name/0` | An atom like `:secret_Abc123` |
| `secret_value/0` | A non-empty printable binary, up to 128 bytes |
| `meta_map/0` | A map with optional `:version` and `:ttl_seconds` |
| `permanent_error/0` | One of `:enoent`, `:eacces`, `:not_found`, `:forbidden` |
| `transient_error/0` | One of `:timeout`, `:econnrefused`, `:nxdomain`, `:temporary_failure` |
| `subscriber_count/0` | An integer from 1 to 5 |

## Testing the Secret struct's leak prevention

Verify that your application code does not accidentally expose secrets through inspect, interpolation, or JSON:

```elixir
test "Secret.expose/1 is required to access the value" do
  start_supervised!(RotatingSecrets.Supervisor)

  Mox.stub(MyApp.MockSource, :init, fn _ -> {:ok, %{}} end)
  Mox.stub(MyApp.MockSource, :load, fn state ->
    {:ok, "s3cr3t", %{version: 1}, state}
  end)

  {:ok, _} = RotatingSecrets.register(:leak_test,
    source: MyApp.MockSource,
    source_opts: []
  )

  {:ok, secret} = RotatingSecrets.current(:leak_test)

  refute inspect(secret) =~ "s3cr3t"
  assert inspect(secret) =~ "redacted"

  assert_raise ArgumentError, fn -> "#{secret}" end

  if Code.ensure_loaded?(Jason) do
    assert_raise ArgumentError, fn -> Jason.encode!(secret) end
  end

  assert RotatingSecrets.Secret.expose(secret) == "s3cr3t"
end
```

## Telemetry in tests

To assert that telemetry events fire, attach a temporary handler that forwards events to the test process:

```elixir
setup do
  test_pid = self()
  ref = make_ref()
  handler_id = "test-rotation-#{inspect(ref)}"

  :telemetry.attach(
    handler_id,
    [:rotating_secrets, :rotation],
    fn _event, measurements, metadata, _ ->
      send(test_pid, {:rotation_event, measurements, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach(handler_id) end)
  :ok
end

test "rotation emits telemetry" do
  # ... register and trigger rotation ...
  assert_receive {:rotation_event, %{version: _}, %{name: :my_secret}}, 1_000
end
```

## Test environment config

Set `cluster_broadcast: false` in `config/test.exs` to avoid spurious pg group messages:

```elixir
config :rotating_secrets,
  cluster_broadcast: false
```

Pass short backoff values directly to `register/2` in tests that exercise the retry path:

```elixir
RotatingSecrets.register(:flaky,
  source: MyApp.MockSource,
  source_opts: [],
  min_backoff_ms: 5,
  max_backoff_ms: 25
)
```
