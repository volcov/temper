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

    matches = Path.wildcard(source)
    {files, directories} = Enum.split_with(matches, &File.regular?/1)
    {deleted, failed} = Enum.split_with(files, fn file -> File.rm(file) == :ok end)

    Enum.each(directories, fn dir ->
      Mix.shell().error("Skipping #{dir}: not a regular file.")
    end)

    Enum.each(failed, fn file ->
      Mix.shell().error("Could not delete #{file}.")
    end)

    case matches do
      [] -> Mix.shell().info("No history files matching #{source}.")
      _matches -> Mix.shell().info("Deleted #{length(deleted)} history files.")
    end
  end
end
