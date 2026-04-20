# Writing a Source

A source encapsulates how a secret is loaded from an external system: a file, an environment variable, HashiCorp Vault, AWS Secrets Manager, a database, or anything else. The `RotatingSecrets.Registry` owns the lifecycle; the source handles only the I/O.

## The Source Behaviour

Declare your module as a source with:

```elixir
@behaviour RotatingSecrets.Source
```

### Required callbacks

#### `init/1`

```elixir
@callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
```

Called once when the secret process starts. Validate options and build the initial state. **No blocking I/O** — `init/1` runs inside the GenServer `init/1` callback and must return quickly.

Return `{:ok, state}` on success. Return `{:error, reason}` to abort startup. The reason must not contain raw secret values or full option keyword lists.

Permanent errors (`:enoent`, `:eacces`, `:not_found`, `:forbidden`, `{:invalid_option, _}`) cause the Registry to stop with a permanent failure. All other errors are treated as transient.

#### `load/1`

```elixir
@callback load(state()) ::
  {:ok, material(), meta(), state()} | {:error, term(), state()}
```

Called on initial load and on each scheduled refresh. Fetch the current secret material from the external system.

- `material` — a binary (the raw secret value).
- `meta` — a map with optional keys `:version`, `:ttl_seconds`, `:issued_at`, `:content_hash`, and any source-specific keys. See `RotatingSecrets.Source` for the full meta specification.
- Return the updated `state` in both success and error tuples.

The Registry serves the last-known-good value during transient failures and schedules an exponential-backoff retry.

### Optional callbacks

#### `subscribe_changes/1`

```elixir
@callback subscribe_changes(state()) ::
  {:ok, ref :: term(), state()} | :not_supported
```

Register for push notifications from the external system. Return `{:ok, ref, new_state}` where `ref` identifies messages the source will send to the Registry PID. Return `:not_supported` to fall back to TTL/interval polling.

#### `handle_change_notification/2`

```elixir
@callback handle_change_notification(msg :: term(), state()) ::
  {:changed, state()} | :ignored | {:error, term()}
```

Called when the Registry receives a `handle_info` message. Return `{:changed, new_state}` to trigger an immediate `load/1`. Return `:ignored` for messages that do not indicate a change. Return `{:error, reason}` to log a warning and continue.

#### `terminate/1`

```elixir
@callback terminate(state()) :: :ok
```

Called when the Registry GenServer is terminating. Close file handles, cancel subscriptions, or stop watcher processes.

## Minimal Example: Static Source

A source that always returns the same value. Useful for tests and illustrating the required interface:

```elixir
defmodule MyApp.Source.Static do
  @behaviour RotatingSecrets.Source

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :value) do
      {:ok, v} when is_binary(v) -> {:ok, %{value: v}}
      {:ok, _} -> {:error, {:invalid_option, {:value, :not_binary}}}
      :error -> {:error, {:invalid_option, {:value, :missing}}}
    end
  end

  @impl true
  def load(state) do
    {:ok, state.value, %{version: 1}, state}
  end
end
```

Register it:

```elixir
RotatingSecrets.register(:my_secret,
  source: MyApp.Source.Static,
  source_opts: [value: "s3cr3t"]
)
```

## Example: HTTP Source with TTL

A source that fetches a secret from an HTTP endpoint and uses the server-supplied TTL:

```elixir
defmodule MyApp.Source.HttpVault do
  @behaviour RotatingSecrets.Source

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    token = Keyword.fetch!(opts, :token)
    {:ok, %{url: url, token: token}}
  end

  @impl true
  def load(state) do
    headers = [{"X-Vault-Token", state.token}]

    case :httpc.request(:get, {String.to_charlist(state.url), headers}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        %{"data" => %{"value" => value}, "lease_duration" => ttl} = Jason.decode!(body)
        meta = %{ttl_seconds: ttl, version: nil}
        {:ok, value, meta, state}

      {:ok, {{_, 403, _}, _, _}} ->
        {:error, :forbidden, state}

      {:ok, {{_, 404, _}, _, _}} ->
        {:error, :not_found, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
```

## Example: Push-Driven Source

A source that subscribes to a channel and triggers a reload on receipt of a message:

```elixir
defmodule MyApp.Source.Channel do
  @behaviour RotatingSecrets.Source

  @impl true
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    {:ok, %{topic: topic, ref: nil}}
  end

  @impl true
  def load(state) do
    case MyApp.SecretStore.fetch(state.topic) do
      {:ok, value, version} ->
        {:ok, value, %{version: version}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def subscribe_changes(state) do
    ref = MyApp.PubSub.subscribe(state.topic)
    {:ok, ref, %{state | ref: ref}}
  end

  @impl true
  def handle_change_notification({:secret_updated, ref}, state)
      when ref == state.ref do
    {:changed, state}
  end

  def handle_change_notification(_msg, _state), do: :ignored

  @impl true
  def terminate(state) do
    if state.ref, do: MyApp.PubSub.unsubscribe(state.topic, state.ref)
    :ok
  end
end
```

## The Meta Map

The `meta` map returned by `load/1` drives scheduling and version tracking:

| Key | Type | Effect |
|---|---|---|
| `:version` | `term() \| nil` | Version counter; must be monotonically non-decreasing. Use `nil` if the source has no ordering concept. |
| `:ttl_seconds` | `pos_integer() \| nil` | If set, the Registry refreshes at 2/3 of this value. If `nil`, falls back to `:fallback_interval_ms`. |
| `:issued_at` | `DateTime.t()` | When the material was issued; informational. |
| `:content_hash` | `binary()` | Hex SHA-256 of the material; useful for change detection when `:version` is `nil`. |

Any additional keys are passed through to the `Secret.meta/1` map unchanged.

## Error Classification

The Registry classifies load errors as permanent or transient:

| Reason | Class |
|---|---|
| `:enoent` | Permanent — process stops |
| `:eacces` | Permanent — process stops |
| `:not_found` | Permanent — process stops |
| `:forbidden` | Permanent — process stops |
| `{:invalid_option, _}` | Permanent — process stops |
| Anything else | Transient — exponential backoff retry |

Return permanent error atoms only when the configuration is irrecoverably wrong. Return transient errors for network failures, timeouts, and temporary unavailability.

## Testing Your Source

Use `Mox` to stub the source in unit tests, or implement a real source with `RotatingSecrets.Source.Memory` for integration tests. See the [Testing guide](testing.md) for details.

To test the `init/1` and `load/1` callbacks directly without a running Registry:

```elixir
test "load returns the expected value" do
  {:ok, state} = MyApp.Source.Static.init(value: "s3cr3t")
  assert {:ok, "s3cr3t", %{version: 1}, ^state} = MyApp.Source.Static.load(state)
end

test "init rejects non-binary value" do
  assert {:error, {:invalid_option, {:value, :not_binary}}} =
    MyApp.Source.Static.init(value: 12345)
end
```
