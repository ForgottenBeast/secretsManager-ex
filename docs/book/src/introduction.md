# Introduction

RotatingSecrets is an Elixir library for managing secret values whose contents change over time. It loads secrets from pluggable sources, caches them in memory, refreshes them automatically when their TTL approaches, and delivers rotation notifications to subscriber processes — all without touching I/O on the hot path.

## The problem it solves

Production secrets — database passwords, API keys, TLS certificates — rotate. An operator or external agent writes a new value to Vault, a file, or another store. Processes running at that moment still hold the old value. The naive fix is a restart, but restarts cause downtime and break long-running connections.

RotatingSecrets solves three problems simultaneously:

1. **Secrets change.** Your process automatically gets the latest value without a restart, because every read goes through an in-memory cache that the library refreshes on your behalf.
2. **Reads must be fast.** All `current/1` calls are served from an ETS-backed in-process cache. No network call, no disk read, no lock contention on the hot path.
3. **Exposure must be controlled.** The `RotatingSecrets.Secret` type is deliberately opaque. It cannot be logged, serialised, or interpolated into a string by accident. You must call `Secret.expose/1` explicitly, and only at the point of use.

## When to use RotatingSecrets

Use RotatingSecrets when:

- You have secrets that change at runtime and your processes must pick up new values without restarting.
- You want a single consistent pattern for reading secrets across file, environment, Vault, or custom sources.
- You need subscription-based notifications so connection pools or similar resources can react immediately when a password rotates.
- You want telemetry and observability baked in without wiring it yourself.

Do not use RotatingSecrets when:

- Your secrets never change and you only need to read them once at startup. A plain `Application.fetch_env!/2` or a config file is simpler.
- You are in a context where adding a supervision tree is not possible (e.g., a pure function library). RotatingSecrets requires a running `RotatingSecrets.Supervisor`.

## Package overview

| Package | Purpose |
|---|---|
| `rotating_secrets` | Core library: supervisor, registry, secret type, built-in file/env/memory sources, telemetry |
| `rotating_secrets_vault` | Vault and OpenBao companion: `Source.Vault.KvV2` for KV secrets engine v2 |
| `rotating_secrets_testing` | Test helpers: `Source.Controllable`, `Testing.Supervisor`, ExUnit macros for rotation assertions |

The `rotating_secrets_testing` package is provisional; its API is stabilising. See the [Testing](testing.md) chapter for current guidance.

## Next step

Start with the [Quickstart](quickstart.md) to add RotatingSecrets to your application in five minutes.
