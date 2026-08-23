defmodule Mix.Tasks.Temper.Report do
  @shortdoc "Reports flaky tests found in the recorded history"

  @moduledoc """
  Reports flaky tests: tests with divergent outcomes on the same git SHA.

      $ mix temper.report

  Reads every `.temper/history-*.jsonl` file (all partitions), runs the
  flake analysis and prints flaky tests sorted by flake rate, followed
  by lower-confidence suspects (divergence involving dirty-tree runs).

  The task always exits 0 — it informs, it does not gate CI.

  ## Options

    * `--json` — print a machine-readable JSON payload instead
    * `--min-runs N` — minimum runs on a SHA for its divergence to
      count as evidence (default: 2)
    * `--history GLOB` — read this path or glob instead of the default
      (also configurable with `config :temper, history_path: "..."`)

  """

  use Mix.Task

  alias Temper.Analysis
  alias Temper.History.Reader
  alias Temper.Report

  @switches [json: :boolean, min_runs: :integer, history: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)

    source =
      opts[:history] || Application.get_env(:temper, :history_path) || Reader.default_glob()

    result = Reader.read(source)
    analysis = Analysis.analyze(result.records, Keyword.take(opts, [:min_runs]))

    stats = %{
      source: source,
      files: length(result.files),
      records: length(result.records),
      corrupt: result.corrupt,
      skipped: result.skipped
    }

    output = if opts[:json], do: Report.json(analysis, stats), else: Report.human(analysis, stats)

    Mix.shell().info(output)
  end
end
