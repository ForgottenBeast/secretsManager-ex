# Testing

This guide covers how to test application code that reads from RotatingSecrets, how to use `MockSource` and `Source.Memory` for unit and integration tests, and how to use the included StreamData generators for property tests.

## Test Setup

Add the following to `test/test_helper.exs`:

```elixir
# Start the Mox mock registry
Mox.defmock(RotatingSecrets.MockSource, for: RotatingSecrets.Source)
ExUnit.start()
```

The library ships `test/support/mocks.ex` which defines `RotatingSecrets.MockSource` automatically when `mix test` is run. No extra setup is needed if you are testing within the library itself.

For applications that depend on RotatingSecrets, define the mock in your own test helper:

```elixir
Mox.defmock(MyApp.MockSource, for: RotatingSecrets.Source)
```

## Unit Testing with MockSource (Mox)

Use `RotatingSecrets.MockSource` to stub the source behaviour in unit tests. This avoids starting a real Registry process.

```elixir
defmodule MyApp.SecretConsumerTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "reads the secret value from the registry" do
    RotatingSecrets.MockSource
    |> expect(:init, fn _opts -> {:ok, %{}} end)
    |> expect(:load, fn state ->
      {:ok, "s3cr3t-value", %{version: 1}, state}
    end)

    start_supervised!(RotatingSecrets.Supervisor)

    {:ok, _} = RotatingSecrets.register(:test_secret,
      source: RotatingSecrets.MockSource,
      source_opts: []
    )

    {:ok, secret} = RotatingSecrets.current(:test_secret)
    assert RotatingSecrets.Secret.expose(secret) == "s3cr3t-value"
  end
end
```

Each test that starts `RotatingSecrets.Supervisor` under `start_supervised!/1` gets a fresh supervisor that is stopped automatically at the end of the test. Secrets registered in one test do not bleed into another.

## Integration Testing with Source.Memory

`RotatingSecrets.Source.Memory` holds a value in-process and exposes `update/2` to rotate it programmatically. Use it for integration tests that exercise the full rotation notification path.

```elixir
defmodule MyApp.RotationHandlerTest do
  use ExUnit.Case, async: false  # Source.Memory uses a named Agent

  setup do
    start_supervised!(RotatingSecrets.Supervisor)
    :ok
  end

  test "subscriber receives notification on rotation" do
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
end
```

`Source.Memory` starts an `Agent` registered in `RotatingSecrets.ProcessRegistry`. Because the Agent is named, tests using `Source.Memory` should set `async: false` or use distinct secret name atoms to avoid collisions.

### Triggering multiple rotations

```elixir
test "consumer handles sequential rotations" do
  {:ok, _} = RotatingSecrets.register(:seq_key,
    source: RotatingSecrets.Source.Memory,
    source_opts: [name: :seq_key, initial_value: "v1"]
  )

  {:ok, sub_ref} = RotatingSecrets.subscribe(:seq_key)

  for new_value <- ["v2", "v3", "v4"] do
    RotatingSecrets.Source.Memory.update(:seq_key, new_value)
    assert_receive {:rotating_secret_rotated, ^sub_ref, :seq_key, _}, 1_000
    {:ok, secret} = RotatingSecrets.current(:seq_key)
    assert RotatingSecrets.Secret.expose(secret) == new_value
  end
end
```

## Testing Source Callbacks Directly

You do not need a running Registry to unit test a source module. Call `init/1` and `load/1` directly:

```elixir
defmodule MyApp.Source.StaticTest do
  use ExUnit.Case, async: true

  alias MyApp.Source.Static

  test "init validates the value option" do
    assert {:ok, %{value: "abc"}} = Static.init(value: "abc")
    assert {:error, {:invalid_option, {:value, :not_binary}}} = Static.init(value: 123)
    assert {:error, {:invalid_option, {:value, :missing}}} = Static.init([])
  end

  test "load returns the value and version 1" do
    {:ok, state} = Static.init(value: "secret")
    assert {:ok, "secret", %{version: 1}, ^state} = Static.load(state)
  end
end
```

## Property Testing with Generators

The library ships `RotatingSecrets.Generators` in `test/support/generators.ex`, with StreamData generators for common inputs:

```elixir
defmodule MyApp.RegistryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import RotatingSecrets.Generators

  property "current/1 always returns the registered value" do
    check all(
            name <- secret_name(),
            value <- secret_value(),
            _meta <- meta_map()
          ) do
      start_supervised!(RotatingSecrets.Supervisor)

      Mox.stub(RotatingSecrets.MockSource, :init, fn _ -> {:ok, %{}} end)
      Mox.stub(RotatingSecrets.MockSource, :load, fn state ->
        {:ok, value, %{}, state}
      end)

      {:ok, _} = RotatingSecrets.register(name,
        source: RotatingSecrets.MockSource,
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

## Testing the Secret Struct's Leak Prevention

Verify that the `Secret` struct does not leak values through inspect, interpolation, or JSON:

```elixir
test "Secret.expose/1 is required to access the value" do
  {:ok, secret} = RotatingSecrets.current(:my_secret)

  # inspect is redacted
  refute inspect(secret) =~ "s3cr3t"
  assert inspect(secret) =~ "redacted"

  # string interpolation raises
  assert_raise ArgumentError, fn -> "#{secret}" end

  # JSON encoding raises (if Jason is available)
  if Code.ensure_loaded?(Jason) do
    assert_raise ArgumentError, fn -> Jason.encode!(secret) end
  end

  # expose/1 returns the raw value
  assert RotatingSecrets.Secret.expose(secret) == "s3cr3t"
end
```

## Attaching Telemetry in Tests

To capture telemetry events in tests, use `:telemetry.attach/4` with `on_exit` cleanup:

```elixir
setup do
  test_pid = self()
  ref = make_ref()

  :telemetry.attach(
    "test-handler-#{inspect(ref)}",
    [:rotating_secrets, :rotation],
    fn _event, measurements, metadata, _ ->
      send(test_pid, {:rotation_event, measurements, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach("test-handler-#{inspect(ref)}") end)
  :ok
end

test "rotation emits telemetry" do
  # ... register and rotate ...
  assert_receive {:rotation_event, %{version: _}, %{name: :my_secret}}, 1_000
end
```

## Configuration for Test Environment

Set short backoff intervals in `config/test.exs` so retry tests do not slow down the suite:

```elixir
# config/test.exs
config :rotating_secrets,
  cluster_broadcast: false
```

Pass short backoff values directly to `register/2` in tests that exercise the retry path:

```elixir
RotatingSecrets.register(:flaky_secret,
  source: RotatingSecrets.MockSource,
  source_opts: [],
  min_backoff_ms: 10,
  max_backoff_ms: 50
)
```
