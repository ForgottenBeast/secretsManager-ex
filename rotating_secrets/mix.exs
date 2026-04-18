defmodule RotatingSecrets.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/TODO/rotating_secrets"

  def project do
    [
      app: :rotating_secrets,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Dialyzer
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],

      # Docs
      name: "RotatingSecrets",
      description: "Elixir secret lifecycle library with rotation, borrow semantics, and pluggable sources",
      source_url: @source_url,
      docs: [
        main: "RotatingSecrets",
        extras: [
          "guides/getting_started.md",
          "guides/rotation.md",
          "guides/security.md",
          "guides/writing_a_source.md",
          "guides/clustering.md",
          "guides/testing.md",
          "specs/README.md"
        ],
        groups_for_extras: [
          Guides: ~r/guides\/.*/,
          Specifications: ~r/specs\/.*/
        ]
      ],

      # Package
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:telemetry, "~> 1.0"},
      {:file_system, "~> 1.1", optional: true},

      # Dev/test
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:mox, "~> 1.0", only: :test},
      {:local_cluster, "~> 2.0", only: :test},
      {:snabbkaffe, "~> 1.0", only: [:dev, :test]},
      # TODO: fill in the GitHub repo for observlib before running mix deps.get
      # {:observlib, github: "OWNER/observlib", only: [:dev, :test]},

      # Tools
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev}
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
