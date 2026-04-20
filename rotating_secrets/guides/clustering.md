# Clustering

This guide describes the current single-node architecture, what multi-node support is planned to look like, and how to inspect secret state across a cluster today.

## Current Status

Clustering support is planned for Phase 10 of the library roadmap. The current release does not include distributed process coordination. Each node manages its own secret processes independently, loading directly from the source.

**What works today across multiple nodes:**

- Each node runs its own `RotatingSecrets.Supervisor` with independent secret processes.
- Secrets are loaded from the source on each node separately; there is no cross-node synchronisation of secret values.
- `RotatingSecrets.cluster_status/1` queries version and metadata from all connected nodes via `:rpc.multicall/5`.

**What requires Phase 10:**

- Horde-based distributed process registration (one secret process per cluster, not per node).
- Cross-node subscription fan-out beyond the current pg-based broadcast.
- Coordinated failover when the node hosting a secret process goes down.

## Single-Node Architecture

On each node, `RotatingSecrets.Supervisor` starts two children under a `:rest_for_one` strategy:

```
RotatingSecrets.Supervisor
  |-- Registry (RotatingSecrets.ProcessRegistry)   # local name lookup
  |-- DynamicSupervisor (RotatingSecrets.DynamicSupervisor)
        |-- Registry (name: :db_password)          # one per registered secret
        |-- Registry (name: :api_key)
        |-- ...
```

The `:rest_for_one` strategy ensures the `DynamicSupervisor` restarts if the `ProcessRegistry` crashes, because all registered process names would be lost.

Each `RotatingSecrets.Registry` GenServer:

- Calls `Process.flag(:sensitive, true)` to exclude itself from crash dumps.
- Calls `:net_kernel.monitor_nodes(true)` to receive `{:nodedown, node}` messages.
- Removes subscriptions for processes on nodes that disconnect.

## Inspecting Cluster State

`RotatingSecrets.cluster_status/1` queries every connected node and returns a map of node names to version/metadata results. Secret values are never included.

```elixir
RotatingSecrets.cluster_status(:db_password)
# => %{
#      :"app@node1" => {:ok, 42, %{ttl_seconds: 300}},
#      :"app@node2" => {:ok, 42, %{ttl_seconds: 300}},
#      :"app@node3" => {:error, :loading}
#    }
```

Use this to verify that all nodes have refreshed to the same version after a rotation event. Nodes that are unreachable or return an RPC error appear as `{:error, :noconnection}`.

The call uses a 5-second timeout per node via `:rpc.multicall/5`. Increase the timeout by calling `RotatingSecrets.Registry.version_and_meta/1` directly on specific nodes if needed.

## Preparing for Horde Integration

When Phase 10 is available, distributed registration will be enabled by passing `:registry_via` to `register/2`:

```elixir
# Future API — requires Phase 10
RotatingSecrets.register(:db_password,
  source: MyApp.Source.Vault,
  source_opts: [path: "secret/db_password"],
  registry_via: {:via, Horde.Registry, {MyApp.HordeRegistry, :db_password}}
)
```

The `RotatingSecrets.Registry` child spec is already designed to be Horde-compatible: it contains no closures, PIDs, or refs, so it can be migrated between nodes safely. After migration the secret value is re-loaded from the source on the new node; it is never carried in the child spec.

## pg-Based Broadcast (Optional)

The Registry includes an optional `pg`-based cluster broadcast. When enabled, every rotation emits a `{:rotating_secret_rotated_cluster, node, name, version}` message to all members of a pg group. This allows processes on remote nodes to react to rotations happening on a different node.

Enable it in your application config:

```elixir
config :rotating_secrets,
  cluster_broadcast: true,
  cluster_broadcast_group: :rotating_secrets_rotations
```

Processes that want to receive cluster rotation messages must join the pg group:

```elixir
:pg.join(:rotating_secrets_rotations, self())
```

Then handle the message:

```elixir
receive do
  {:rotating_secret_rotated_cluster, _node, :db_password, _version} ->
    {:ok, secret} = RotatingSecrets.current(:db_password)
    # use the new value
end
```

The broadcast is best-effort: nodes that are partitioned or temporarily disconnected will not receive the message, and the rotation notification is not retried. Design consumer logic to tolerate missed notifications by also handling TTL-driven refresh.

## Subscription Cleanup on Node Disconnect

The Registry calls `:net_kernel.monitor_nodes(true)` on startup. When a node disconnects, it receives `{:nodedown, node}` and removes all subscriptions for processes on that node. This prevents the subscription map from accumulating stale entries in long-running clusters.

Subscribers on the disconnecting node do not receive a notification for rotations that occurred while the node was partitioned. They will pick up the current value on reconnect via the TTL-driven refresh cycle.
