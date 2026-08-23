defmodule Temper.Report do
  @moduledoc """
  Renders analysis results for humans or machines.

  `human/2` produces the terminal report shown by `mix temper.report`;
  `json/2` produces a machine-readable payload (the shape a future
  ingestion service will accept). Both are pure: analysis data and
  read stats in, a string out — printing is the mix task's job.
  """

  alias Temper.Analysis

  @typedoc "What was read to produce the report, for the footer/payload."
  @type stats :: %{
          source: String.t(),
          files: non_neg_integer(),
          records: non_neg_integer(),
          corrupt: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Renders the human-readable report.

  Flaky tests come first (sorted by the analysis), then suspects.
  With no history files at all, prints setup instructions instead.
  """
  @spec human(Analysis.report(), stats()) :: String.t()
  def human(_analysis, %{files: 0} = stats) do
    """
    No history files found matching #{stats.source}.

    Enable the formatter and run your suite first:

        # test/test_helper.exs
        ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
    """
  end

  def human(%{flaky: [], suspects: []}, stats) do
    "No flaky tests detected.\n\n" <> footer(stats)
  end

  def human(analysis, stats) do
    [
      section("Flaky tests (divergent outcomes on same git SHA):", analysis.flaky),
      section(
        "Suspects (divergence involving dirty-tree runs — lower confidence):",
        analysis.suspects
      ),
      footer(stats)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Renders the report as a JSON payload (single line).
  """
  @spec json(Analysis.report(), stats()) :: String.t()
  def json(analysis, stats) do
    Jason.encode!(%{
      schema: 1,
      kind: "report",
      stats: stats,
      flaky: analysis.flaky,
      suspects: analysis.suspects
    })
  end

  defp section(_title, []), do: nil

  defp section(title, findings) do
    blocks = Enum.map_join(findings, "\n\n", &finding_block/1)
    "#{title}\n\n#{blocks}\n"
  end

  defp finding_block(finding) do
    ["  #{finding.module} #{finding.name}"]
    |> append_location(finding)
    |> Kernel.++(Enum.map(finding.evidence, &evidence_line/1))
    |> append_seeds(finding)
    |> Enum.join("\n")
  end

  defp append_location(lines, %{file: nil}), do: lines

  defp append_location(lines, finding) do
    location = [finding.file, finding.line] |> Enum.reject(&is_nil/1) |> Enum.join(":")
    lines ++ ["    #{location}#{async_suffix(finding.async)}"]
  end

  defp async_suffix(nil), do: ""
  defp async_suffix(async), do: "  async: #{async}"

  defp evidence_line(evidence) do
    "    #{evidence.runs} runs on #{short_sha(evidence.sha)}#{dirty_marker(evidence)}: " <>
      "#{evidence.passed} passed / #{evidence.failed} failed " <>
      "(#{percent(evidence.flake_rate)} flake rate)"
  end

  defp dirty_marker(%{dirty: true}), do: " (dirty)"
  defp dirty_marker(_clean), do: ""

  defp append_seeds(lines, %{failing_seeds: []}), do: lines

  defp append_seeds(lines, finding) do
    lines ++ ["    failing seeds: #{Enum.join(finding.failing_seeds, ", ")}"]
  end

  defp short_sha(sha), do: String.slice(sha, 0, 7)

  defp percent(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end

  defp footer(stats) do
    "Read #{stats.records} test outcomes from #{stats.files} history files." <>
      corrupt_note(stats)
  end

  defp corrupt_note(%{corrupt: 0}), do: ""
  defp corrupt_note(stats), do: " #{stats.corrupt} corrupt lines skipped."
end
