defmodule Mix.Tasks.Temper.Clean do
  @shortdoc "Deletes recorded test history"

  @moduledoc """
  Deletes Temper's recorded history files.

      $ mix temper.clean

  Removes every file matching `.temper/history-*.jsonl` (all
  partitions). Useful when the history predates a large refactor and
  its evidence no longer says anything about today's tests.

  ## Options

    * `--history GLOB` — delete files matching this path or glob
      instead of the default (also configurable with
      `config :temper, history_path: "..."`)

  """

  use Mix.Task

  alias Temper.History.Reader

  @switches [history: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)

    source =
      opts[:history] || Application.get_env(:temper, :history_path) || Reader.default_glob()

    files = Path.wildcard(source)

    Enum.each(files, &File.rm!/1)

    case files do
      [] -> Mix.shell().info("No history files matching #{source}.")
      files -> Mix.shell().info("Deleted #{length(files)} history files.")
    end
  end
end
