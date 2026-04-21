# Clustering

RotatingSecrets is designed to run on multi-node BEAM clusters. Each node manages its own secret processes independently. Distributed process coordination (Horde-based, one process per cluster) is planned for a future release.

## Current architecture

On each node, `RotatingSecrets.Supervisor` starts two children under a `:rest_for_one` strategy:

```
RotatingSecrets.Supervisor
  |-- ProcessRegistry (RotatingSecrets.ProcessRegistry)
  |-- DynamicSupervisor (RotatingSecrets.DynamicSupervisor)
        |-- Registry (name: :db_password)
        |-- Registry (name: :api_key)
        |-- ...
```

The `:rest_for_one` strategy ensures the `DynamicSupervisor` restarts if `ProcessRegistry` crashes, since all registered process names would be lost.

Each node loads secrets independently from the source. There is no cross-node synchronisation of secret values. This means:

- Each node makes its own calls to Vault, the filesystem, or any other backend.
- A rotation applied to the source propagates to all nodes independently as each node's TTL refresh fires.
- Secret values are never transmitted over the BEAM distribution channel.

## Inspecting cluster state

`RotatingSecrets.cluster_status/1` queries every connected node via `:rpc.multicall/5` and returns a map of node names to version/metadata results. Secret values are never included.

```elixir
RotatingSecrets.cluster_status(:db_password)
# => %{
#      :"app@node1" => {:ok, 42, %{ttl_seconds: 300}},
#      :"app@node2" => {:ok, 42, %{ttl_seconds: 300}},
#      :"app@node3" => {:error, :loading}
#    }
```

Use this to verify that all nodes have refreshed to the same version after a rotation event. Unreachable nodes or RPC errors appear as `{:error, :noconnection}`.

The call uses a 5-second timeout per node. If you need a longer timeout for a specific node, call `RotatingSecrets.Registry.version_and_meta/1` directly on that node via `:rpc.call/4`.

## Subscription cleanup on node disconnect

Each Registry GenServer calls `:net_kernel.monitor_nodes(true)` on startup. When a node disconnects, the Registry receives `{:nodedown, node}` and removes all subscriptions for processes on that node. This prevents the subscription map from accumulating stale entries in long-running clusters.

Subscribers on the disconnecting node do not receive notifications for rotations that occurred during the partition. They pick up the current value on reconnect via the TTL-driven refresh cycle.

## Optional: pg-based cluster broadcast

Enable a cluster-wide rotation broadcast by setting:

```elixir
config :rotating_secrets,
  cluster_broadcast: true,
  cluster_broadcast_group: :rotating_secrets_rotations
```

Processes that want cluster rotation messages must join the pg group:

```elixir
:pg.join(:rotating_secrets_rotations, self())
```

They then receive:

```elixir
{:rotating_secret_rotated_cluster, node, name, version}
```

This broadcast is best-effort. Nodes that are partitioned or temporarily disconnected will not receive the message and will not receive a replay. Design consumer logic to tolerate missed notifications by also relying on the TTL-driven refresh cycle.

## What NOT to do

- **Do not use `pg2` for the Registry itself.** `pg2` is deprecated in OTP 24 and removed in OTP 26. The pg-based cluster broadcast described above uses the current `:pg` module, not `pg2`.
- **Do not rely on cluster broadcast as the only delivery mechanism for rotation reactions.** It is best-effort. Pair it with TTL polling or local subscriptions.
- **Do not store the raw Vault token or file contents in the child spec.** The `Registry` child spec contains no closures, PIDs, or secret values by design. If you customise the child spec, preserve this property.

## Preparing for Horde integration

Distributed process coordination (one secret process per cluster, not per node) is planned. When it is available, you will enable it by passing `:registry_via` to `register/2`:

```elixir
# Future API — not yet available
RotatingSecrets.register(:db_password,
  source: MyApp.Source.Vault,
  source_opts: [path: "secret/db_password"],
  registry_via: {:via, Horde.Registry, {MyApp.HordeRegistry, :db_password}}
)
```

The `Registry` child spec is already Horde-compatible: it contains no closures, PIDs, or refs that would break cross-node migration. After migration, the secret value is re-loaded from the source on the receiving node.

## API reference

See [`RotatingSecrets.cluster_status/1`](../../api/rotating_secrets/RotatingSecrets.html#cluster_status/1) for full return value documentation.
