defmodule Temper.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/volcov/temper"

  def project do
    [
      app: :temper,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Flaky-test detection for ExUnit: records every test outcome and reports tests with divergent results on the same git SHA.",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "guides/history-schema.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
