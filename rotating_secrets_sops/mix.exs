defmodule RotatingSecretsSops.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/TODO/rotating_secrets"

  def project do
    [
      app: :rotating_secrets_sops,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Dialyzer
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix, :crypto],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],

      # Docs
      name: "RotatingSecretsSops",
      description:
        "SOPS-backed secret source for RotatingSecrets, with AES-256-GCM transit operations",
      source_url: @source_url,
      docs: [
        main: "RotatingSecrets.Source.Sops",
        extras: []
      ],

      # Package
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core
      {:rotating_secrets, path: "../rotating_secrets"},

      # Optional runtime
      {:file_system, "~> 1.1", optional: true},
      {:jason, "~> 1.0", optional: true},

      # Dev/test
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:mox, "~> 1.0", only: :test},

      # Tools
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "quality.check": ["format --check-formatted", "credo --strict", "dialyzer"],
      test: ["test"]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
