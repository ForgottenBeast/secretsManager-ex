# Vault / OpenBao Source

`RotatingSecrets.Source.Vault.KvV2` reads secrets from the Vault or OpenBao KV secrets engine v2. It is shipped in the `rotating_secrets_vault` companion package.

## Prerequisites

- A running Vault or OpenBao instance with the KV v2 secrets engine mounted (for example, at path `secret`).
- A Vault token with `read` access to the target path.
- `rotating_secrets_vault` added to your dependencies.

Enable the KV v2 engine if it is not already active:

```bash
vault secrets enable -path=secret kv-v2
```

Write a test secret:

```bash
vault kv put secret/myapp/db password=s3cr3t
```

## Adding the dependency

```elixir
# mix.exs
def deps do
  [
    {:rotating_secrets, "~> 0.1"},
    {:rotating_secrets_vault, "~> 0.1"},
    {:req, "~> 0.5"}          # required by rotating_secrets_vault
  ]
end
```

## Registering a KV v2 secret

```elixir
RotatingSecrets.register(:db_password,
  source: RotatingSecrets.Source.Vault.KvV2,
  source_opts: [
    address: "http://127.0.0.1:8200",
    mount: "secret",
    path: "myapp/db",
    token: System.fetch_env!("VAULT_TOKEN"),
    key: "password"
  ]
)
```

At registration time the source calls `GET /v1/secret/data/myapp/db`, extracts the `password` field from the response, and caches it. The Registry is then responsible for all subsequent refreshes.

## `source_opts` reference

| Option | Required | Default | Description |
|---|---|---|---|
| `:address` | Yes | — | Vault server address, e.g. `"http://127.0.0.1:8200"` |
| `:mount` | Yes | — | KV v2 mount path, e.g. `"secret"` |
| `:path` | Yes | — | Secret path within the mount, e.g. `"myapp/db"` |
| `:token` | Yes | — | Vault token for authentication |
| `:key` | No | `"value"` | Field name to extract from the KV data map |
| `:namespace` | No | `nil` | Vault Enterprise namespace (non-empty binary) |
| `:req_options` | No | `[]` | Keyword list merged into `Req.new/1`; for test injection only |

## TTL from KV metadata

Vault KV v2 does not expose an expiry TTL for data secrets the way dynamic secrets do. `Source.Vault.KvV2` derives a TTL from the `custom_metadata` field of the secret. If you want explicit refresh scheduling, set `ttl_seconds` in the custom metadata:

```bash
vault kv metadata put \
  -custom-metadata ttl_seconds=300 \
  secret/myapp/db
```

The source reads `custom_metadata.ttl_seconds` and returns it in the meta map. The Registry then schedules a refresh at 200 seconds (2/3 of 300).

If no `ttl_seconds` is present in custom metadata, the Registry falls back to the `:fallback_interval_ms` option (default 60 000 ms).

## Version tracking

Vault KV v2 assigns an integer version number to every write. `Source.Vault.KvV2` reads this from `data.metadata.version` and returns it in the meta map. The Registry enforces version monotonicity: versions must never decrease across refreshes.

After a rotation, `RotatingSecrets.cluster_status/1` shows the current version on each node, allowing you to verify that all nodes have picked up the new value:

```elixir
RotatingSecrets.cluster_status(:db_password)
# => %{
#      :"app@node1" => {:ok, 7, %{ttl_seconds: 300}},
#      :"app@node2" => {:ok, 7, %{ttl_seconds: 300}}
#    }
```

## Token renewal

`Source.Vault.KvV2` does not renew the Vault token. Token renewal is the responsibility of a sidecar or agent running alongside your application. Two common patterns:

- **Vault Agent**: runs as a sidecar, handles auth renewal, and can also write secrets to files (use `Source.File` in that case).
- **Short-lived tokens with re-registration**: if your auth method supports frequent short-lived tokens, consider registering a new secret process with a fresh token when the old one is about to expire. This is advanced usage and adds operational complexity.

For most deployments, a long-lived (but revocable) service token or an AppRole with a token TTL of 24 hours is the simplest approach. Use Vault audit logs and `vault token renew` in a cron job or systemd timer to keep the token alive.

## Error handling

| Vault response | `load/1` return | Registry behaviour |
|---|---|---|
| HTTP 200 | `{:ok, value, meta, state}` | Caches value, schedules refresh |
| HTTP 403 Forbidden | `{:error, :forbidden, state}` | Permanent failure — process stops |
| HTTP 404 Not Found | `{:error, :not_found, state}` | Permanent failure — process stops |
| HTTP 429 Rate limited | `{:error, :vault_rate_limited, state}` | Transient — exponential backoff |
| Network error | `{:error, reason, state}` | Transient — exponential backoff |

Permanent failures stop the Registry process. The supervisor restarts it, which re-runs `init/1` and then `load/1` from scratch. If the root cause (wrong path, insufficient permissions) is not fixed, the process will enter a restart loop. Set an appropriate restart intensity in your application supervisor.

## API reference

See [`RotatingSecrets.Source.Vault.KvV2`](../../api/vault/RotatingSecrets.Source.Vault.KvV2.html) for the full option and callback documentation.
