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

      # Connecting via a bao agent UNIX socket:
      # Set address: to "http://localhost" — the host is used only for the
      # HTTP Host header; all traffic routes through the socket.
      RotatingSecrets.register(:api_key,
        source: {RotatingSecrets.Source.Vault.KvV2,
                 address: "http://localhost",
                 unix_socket: "/run/bao.sock",
                 mount: "secret",
                 path: "myapp/api_key",
                 token: System.fetch_env!("VAULT_TOKEN")})

      # Authenticate via SPIRE JWT-SVID → OpenBao (requires a running SpiffeEx instance):
      RotatingSecrets.register(:api_key,
        source: {RotatingSecrets.Source.Vault.KvV2,
                 address: "http://127.0.0.1:8200",
                 mount: "secret",
                 path: "myapp/api_key",
                 auth: {:jwt_svid, [
                   spiffe_ex: MyApp.SpiffeEx,
                   audience: "openbao",
                   role: "my-openbao-role",
                   mount: "jwt-spire"
                 ]}})

      # Authenticate via generic OIDC client_credentials → OpenBao:
      RotatingSecrets.register(:api_key,
        source: {RotatingSecrets.Source.Vault.KvV2,
                 address: "http://127.0.0.1:8200",
                 mount: "secret",
                 path: "myapp/api_key",
                 auth: {:oidc, [
                   issuer_uri: "https://my-project.zitadel.cloud",
                   client_id: "my-app-id@project.zitadel.cloud",
                   client_secret: System.fetch_env!("ZITADEL_APP_SECRET"),
                   role: "my-openbao-role"
                 ]}})
  """
end
