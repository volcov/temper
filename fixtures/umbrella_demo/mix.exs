defmodule UmbrellaDemo.MixProject do
  use Mix.Project

  # Mirrors the README's umbrella recipe: Temper declared once, at the
  # umbrella root — child apps never mention it.
  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: false,
      deps: [
        {:temper, path: "../..", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
