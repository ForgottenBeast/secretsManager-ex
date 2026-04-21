# Writing a Custom Source

A custom source lets you load secrets from any backend — an HTTP endpoint, a database, AWS Secrets Manager, or a proprietary secrets store — while the Registry handles caching, TTL scheduling, retries, and rotation notifications.

## The Source behaviour

Declare your module as a source:

```elixir
@behaviour RotatingSecrets.Source
```

You must implement `init/1` and `load/1`. The optional callbacks `subscribe_changes/1`, `handle_change_notification/2`, and `terminate/1` enable push-driven refresh.

See [Sources](../concepts/sources.md) for the full callback signatures and error classification rules.

## Example: HTTP endpoint source

This source polls a JSON API that returns a secret value and a TTL:

```elixir
defmodule MyApp.Source.HttpEndpoint do
  @behaviour RotatingSecrets.Source

  @impl true
  def init(opts) do
    with {:ok, url} <- fetch_required_string(opts, :url),
         {:ok, token} <- fetch_required_string(opts, :api_token) do
      {:ok, %{url: url, token: token}}
    end
  end

  @impl true
  def load(state) do
    headers = [{"Authorization", "Bearer #{state.token}"}]

    case :httpc.request(:get, {String.to_charlist(state.url), headers}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        %{"secret" => value, "ttl_seconds" => ttl, "version" => version} =
          Jason.decode!(body)

        meta = %{ttl_seconds: ttl, version: version}
        {:ok, value, meta, state}

      {:ok, {{_, 403, _}, _, _}} ->
        {:error, :forbidden, state}

      {:ok, {{_, 404, _}, _, _}} ->
        {:error, :not_found, state}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      {:ok, _} -> {:error, {:invalid_option, {key, :not_binary}}}
      :error -> {:error, {:invalid_option, {key, :missing}}}
    end
  end
end
```

Register it:

```elixir
RotatingSecrets.register(:api_credential,
  source: MyApp.Source.HttpEndpoint,
  source_opts: [
    url: "https://secrets.internal/v1/api_credential",
    api_token: System.fetch_env!("SECRETS_SERVICE_TOKEN")
  ]
)
```

## Adding push-driven refresh

If the external system supports a push channel — a PubSub topic, a WebSocket, a long-poll endpoint — implement `subscribe_changes/1` and `handle_change_notification/2` to trigger immediate reloads:

```elixir
defmodule MyApp.Source.PubSubEndpoint do
  @behaviour RotatingSecrets.Source

  @impl true
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    {:ok, %{topic: topic, sub_ref: nil}}
  end

  @impl true
  def load(state) do
    case MyApp.SecretBackend.fetch(state.topic) do
      {:ok, value, version} ->
        {:ok, value, %{version: version}, state}
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def subscribe_changes(state) do
    ref = MyApp.PubSub.subscribe(state.topic)
    {:ok, ref, %{state | sub_ref: ref}}
  end

  @impl true
  def handle_change_notification({:secret_changed, ref}, state)
      when ref == state.sub_ref do
    {:changed, state}
  end

  def handle_change_notification(_msg, _state), do: :ignored

  @impl true
  def terminate(state) do
    if state.sub_ref do
      MyApp.PubSub.unsubscribe(state.topic, state.sub_ref)
    end
    :ok
  end
end
```

When `handle_change_notification/2` returns `{:changed, state}`, the Registry immediately calls `load/1`. The push channel and TTL timer coexist: whichever fires first triggers a reload.

## Error classification

Return the correct error atom to control how the Registry responds to failures:

| Error atom | Registry response |
|---|---|
| `:forbidden`, `:not_found`, `:enoent`, `:eacces` | Permanent — process stops immediately |
| `{:invalid_option, _}` | Permanent — process stops immediately |
| Anything else | Transient — exponential backoff retry |

Only return permanent error atoms when the configuration is wrong in a way that cannot resolve itself (wrong path, insufficient permissions). For network timeouts or transient backend errors, return any other term so the Registry retries.

## Testing your source

### Unit test: call callbacks directly

You do not need a running Registry to test `init/1` and `load/1`:

```elixir
defmodule MyApp.Source.HttpEndpointTest do
  use ExUnit.Case, async: true

  alias MyApp.Source.HttpEndpoint

  test "init rejects missing url" do
    assert {:error, {:invalid_option, {:url, :missing}}} =
      HttpEndpoint.init(api_token: "tok")
  end

  test "init rejects non-binary url" do
    assert {:error, {:invalid_option, {:url, :not_binary}}} =
      HttpEndpoint.init(url: 42, api_token: "tok")
  end
end
```

### Integration test: use Source.Memory as a stand-in

For tests that exercise the Registry round-trip without making real HTTP calls, use `Source.Memory`:

```elixir
defmodule MyApp.RotationTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(RotatingSecrets.Supervisor)
    :ok
  end

  test "subscriber receives notification" do
    {:ok, _} = RotatingSecrets.register(:test_secret,
      source: RotatingSecrets.Source.Memory,
      source_opts: [name: :test_secret, initial_value: "initial"]
    )

    {:ok, sub_ref} = RotatingSecrets.subscribe(:test_secret)
    RotatingSecrets.Source.Memory.update(:test_secret, "rotated")

    assert_receive {:rotating_secret_rotated, ^sub_ref, :test_secret, _version}, 1_000
    {:ok, secret} = RotatingSecrets.current(:test_secret)
    assert RotatingSecrets.Secret.expose(secret) == "rotated"
  end
end
```

### Using Source.Controllable (provisional)

`Source.Controllable` (from `rotating_secrets_testing`) gives direct control over what `load/1` returns. This is useful for testing retry behaviour and error handling without relying on real network calls or file system state. See [Testing](../testing.md) for setup details.

## API reference

See [`RotatingSecrets.Source`](../../api/rotating_secrets/RotatingSecrets.Source.html) for the complete callback specifications and meta map documentation.
