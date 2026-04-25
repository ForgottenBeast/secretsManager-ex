defmodule RotatingSecretsTesting.MixProject do
  use Mix.Project

  def project do
    [
      app: :rotating_secrets_testing,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix]
      ],
      name: "RotatingSecretsTesting",
      description: "ExUnit helpers and a controllable test source for rotating_secrets",
      docs: [main: "RotatingSecrets.Testing"],
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # NOTE: switch to {:rotating_secrets, "~> 0.1"} before publishing to Hex
      {:rotating_secrets, path: "../rotating_secrets"},
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "quality.check": ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
