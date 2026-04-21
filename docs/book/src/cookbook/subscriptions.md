# Reacting to Rotations

RotatingSecrets notifies subscriber processes when a secret's value changes. Use subscriptions to react immediately — for example, to reconnect a database connection pool with a new password rather than waiting for the next connection attempt.

## Rotation notification format

When a secret rotates, each subscriber receives a message:

```elixir
{:rotating_secret_rotated, sub_ref, name, version}
```

- `sub_ref` — the reference returned by `subscribe/1`. Use it to match messages from this specific subscription.
- `name` — the atom name of the secret that rotated.
- `version` — the version from the source metadata. May be `nil` if the source does not track versions.

The message carries the version but **never the secret value**. Call `current/1` explicitly to obtain the new value.

## `subscribe/1` and `unsubscribe/2`

Subscribe any process (the calling process by default) to rotation notifications:

```elixir
{:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)
```

To cancel:

```elixir
:ok = RotatingSecrets.unsubscribe(:db_password, sub_ref)
```

`unsubscribe/2` always returns `:ok`, including when the subscription has already been cleaned up or the process has exited.

## Subscribe before reading

Subscribe before reading the current value to avoid a race condition where the secret rotates between your `current/1` call and your `subscribe/1` call:

```elixir
# Correct order: subscribe first, then read
{:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)
{:ok, secret} = RotatingSecrets.current(:db_password)
initial_password = RotatingSecrets.Secret.expose(secret)
```

If you subscribe after reading, there is a window where the secret may have already rotated and you are holding a stale value without knowing it.

## Skipping redundant reconnects with version

When a subscriber receives a notification, compare the incoming version against the version of the value it is currently using. If the versions match, the subscriber already has the current value and no reconnect is needed:

```elixir
# Track the version in your process state
def handle_info({:rotating_secret_rotated, ^sub_ref, :db_password, incoming_version}, state) do
  if incoming_version == state.current_version do
    {:noreply, state}
  else
    {:ok, secret} = RotatingSecrets.current(:db_password)
    new_password = RotatingSecrets.Secret.expose(secret)
    {:ok, new_conn} = MyApp.DB.reconnect(state.conn, new_password)
    {:noreply, %{state | conn: new_conn, current_version: incoming_version}}
  end
end
```

## GenServer pattern

The most common pattern is a GenServer that holds a connection or client, subscribes on `init`, and reconnects in `handle_info`:

```elixir
defmodule MyApp.DBPool do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Subscribe before reading to avoid the race window
    {:ok, sub_ref} = RotatingSecrets.subscribe(:db_password)
    {:ok, secret} = RotatingSecrets.current(:db_password)
    {:ok, conn} = MyApp.DB.connect(RotatingSecrets.Secret.expose(secret))
    version = secret |> RotatingSecrets.Secret.meta() |> Map.get(:version)
    {:ok, %{conn: conn, sub_ref: sub_ref, version: version}}
  end

  def handle_info({:rotating_secret_rotated, sub_ref, :db_password, new_version}, state)
      when sub_ref == state.sub_ref do
    if new_version == state.version do
      {:noreply, state}
    else
      {:ok, secret} = RotatingSecrets.current(:db_password)
      {:ok, new_conn} = MyApp.DB.reconnect(state.conn, RotatingSecrets.Secret.expose(secret))
      {:noreply, %{state | conn: new_conn, version: new_version}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  def terminate(_reason, state) do
    RotatingSecrets.unsubscribe(:db_password, state.sub_ref)
    :ok
  end
end
```

## Automatic cleanup on process exit

The Registry monitors each subscriber using `Process.monitor`. When a subscriber process exits or crashes, the Registry removes the subscription automatically. No manual cleanup is needed for the crash case — only for intentional deregistration via `unsubscribe/2`.

## Automatic cleanup on node disconnect

The Registry calls `:net_kernel.monitor_nodes(true)` on startup. When a node disconnects, all subscriptions for processes on that node are removed. Subscribers on the disconnecting node do not receive notifications for rotations that occurred during the partition; they pick up the current value on reconnect via the TTL-driven refresh cycle.

## Cluster-wide rotation broadcast (optional)

When `cluster_broadcast: true` is set in application config, the Registry also emits a `pg`-based broadcast message to a cluster-wide group:

```elixir
config :rotating_secrets,
  cluster_broadcast: true,
  cluster_broadcast_group: :rotating_secrets_rotations
```

Processes on any node that want to receive these cluster-wide notifications must join the pg group:

```elixir
:pg.join(:rotating_secrets_rotations, self())
```

They will then receive:

```elixir
{:rotating_secret_rotated_cluster, node, name, version}
```

This broadcast is best-effort. Nodes that are partitioned at rotation time will not receive the message. Design consumer logic to tolerate missed notifications by also relying on the TTL-driven refresh cycle.
