defmodule RotatingSecrets.Source.Vault do
  @moduledoc """
  Vault integration for RotatingSecrets.

  Use one of the five source modules directly:

    - `RotatingSecrets.Source.Vault.KvV2` — KV secrets engine v2 (versioned)
    - `RotatingSecrets.Source.Vault.KvV1` — KV secrets engine v1 (unversioned)
    - `RotatingSecrets.Source.Vault.Dynamic` — Dynamic secrets (database, AWS, etc.)
    - `RotatingSecrets.Source.Vault.PKI` — PKI certificates (X.509, TTL-driven refresh)
    - `RotatingSecrets.Source.Vault.Transit` — Transit engine key metadata (encryption key versions)

  ## Example

      RotatingSecrets.register(:api_key,
        source: {RotatingSecrets.Source.Vault.KvV2,
                 address: "http://127.0.0.1:8200",
                 mount: "secret",
                 path: "myapp/api_key",
                 token: System.fetch_env!("VAULT_TOKEN")})

      RotatingSecrets.register(:tls_cert,
        source: {RotatingSecrets.Source.Vault.PKI,
                 address: "http://127.0.0.1:8200",
                 mount: "pki",
                 role: "web-server",
                 common_name: "example.com",
                 token: System.fetch_env!("VAULT_TOKEN")})

      # Transit key metadata: tracks current key version and type.
      # No TTL is returned by the Transit engine; set a short
      # fallback_interval_ms to poll for key rotations promptly.
      RotatingSecrets.register(:encrypt_key,
        source: {RotatingSecrets.Source.Vault.Transit,
                 address: "http://127.0.0.1:8200",
                 mount: "transit",
                 name: "my-key",
                 token: System.fetch_env!("VAULT_TOKEN")},
        fallback_interval_ms: 60_000)
  """
end
