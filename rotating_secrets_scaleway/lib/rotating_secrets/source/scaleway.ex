defmodule RotatingSecrets.Source.Scaleway do
  @moduledoc """
  Scaleway Secret Manager integration for RotatingSecrets.

  Use the source module directly:

    - `RotatingSecrets.Source.Scaleway.Secret` — Scaleway Secret Manager (polling, version-aware)

  ## Example

      RotatingSecrets.register(:api_key,
        source: RotatingSecrets.Source.Scaleway.Secret,
        source_opts: [
          secret_key: System.fetch_env!("SCW_SECRET_KEY"),
          project_id: System.fetch_env!("SCW_DEFAULT_PROJECT_ID"),
          region: "fr-par",
          name: "my-api-key",
          ttl_seconds: 300
        ]
      )

  ## Note on TTL

  Scaleway Secret Manager has no native TTL on secrets. The `:ttl_seconds` opt
  controls how frequently `rotating_secrets` polls for new versions. Choose a
  value that balances API call volume against acceptable staleness for your use case.
  """
end
