defmodule RotatingSecretsVault.MixProject do
  use Mix.Project

  def project do
    [
      app: :rotating_secrets_vault,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix]
      ],
      name: "RotatingSecretsVault",
      description: "Vault HTTP source for rotating_secrets",
      docs: [main: "RotatingSecretsVault"],
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # NOTE: switch to {:rotating_secrets, "~> 0.1"} before publishing to Hex
      # req ~> 0.5: verify against your project's mix.lock before upgrading
      {:rotating_secrets, path: "../rotating_secrets"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: :test},
      {:postgrex, "~> 0.17", only: :test}
    ]
  end

  defp aliases do
    [
      "quality.check": ["format --check-formatted", "credo --strict", "dialyzer"],
      # Run OpenBao dynamic-secrets DB integration tests.
      # Requires a running PostgreSQL instance and PG_AVAILABLE=1.
      # Use scripts/run_db_tests.sh to start an ephemeral instance automatically.
      "test.db": ["test --only openbao_db"]
    ]
  end
end
