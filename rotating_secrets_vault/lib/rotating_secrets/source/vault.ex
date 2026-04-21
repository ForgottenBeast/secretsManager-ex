defmodule RotatingSecrets.Source.Vault do
  @moduledoc """
  Vault integration for RotatingSecrets.

  Use one of the four source modules directly:

    - `RotatingSecrets.Source.Vault.KvV2` — KV secrets engine v2 (versioned)
    - `RotatingSecrets.Source.Vault.KvV1` — KV secrets engine v1 (unversioned)
    - `RotatingSecrets.Source.Vault.Dynamic` — Dynamic secrets (database, AWS, etc.)
    - `RotatingSecrets.Source.Vault.PKI` — PKI certificates (X.509, TTL-driven refresh)

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
  """
end
