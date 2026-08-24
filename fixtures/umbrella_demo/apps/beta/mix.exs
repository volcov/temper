defmodule Beta.MixProject do
  use Mix.Project

  def project do
    [
      app: :beta,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: false,
      deps: []
    ]
  end
end
