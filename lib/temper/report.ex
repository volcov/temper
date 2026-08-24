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

  Options:

    * `:by_app` — group findings by umbrella child app, derived from
      each finding's file path (the segment after `apps/`). Findings
      whose path carries no `apps/<name>/` segment group under
      `"(root)"`. Default `false`.
  """
  @spec human(Analysis.report(), stats(), keyword()) :: String.t()
  def human(analysis, stats, opts \\ [])

  def human(_analysis, %{files: 0} = stats, _opts) do
    """
    No history files found matching #{stats.source}.

    Enable the formatter and run your suite first:

        # test/test_helper.exs
        ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
    """
  end

  def human(%{flaky: [], suspects: []}, stats, _opts) do
    "No flaky tests detected.\n\n" <> footer(stats)
  end

  def human(analysis, stats, opts) do
    by_app = Keyword.get(opts, :by_app, false)

    [
      section(
        "Flaky tests (divergent outcomes on same git SHA):",
        analysis.flaky,
        "flaky",
        by_app
      ),
      section(
        "Suspects (divergence involving dirty-tree runs — lower confidence):",
        analysis.suspects,
        "suspect",
        by_app
      ),
      footer(stats)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Renders the report as a JSON payload (single line).

  Every finding carries a derived `"app"` field: the umbrella child
  app parsed from its file path, or `null` when there is none.
  """
  @spec json(Analysis.report(), stats()) :: String.t()
  def json(analysis, stats) do
    Jason.encode!(%{
      schema: 1,
      kind: "report",
      stats: stats,
      flaky: Enum.map(analysis.flaky, &put_app/1),
      suspects: Enum.map(analysis.suspects, &put_app/1)
    })
  end

  defp put_app(finding), do: Map.put(finding, :app, derive_app(finding.file))

  defp section(_title, [], _label, _by_app), do: nil

  defp section(title, findings, _label, false) do
    blocks = Enum.map_join(findings, "\n\n", &finding_block/1)
    "#{title}\n\n#{blocks}\n"
  end

  defp section(title, findings, label, true) do
    blocks =
      findings
      |> Enum.group_by(fn finding -> derive_app(finding.file) || "(root)" end)
      |> Enum.sort_by(fn {app, group} -> {-length(group), app} end)
      |> Enum.map_join("\n\n", fn {app, group} -> app_block(app, group, label) end)

    "#{title}\n\n#{blocks}\n"
  end

  defp app_block(app, findings, label) do
    heading = "  #{app} — #{length(findings)} #{label} across #{file_count(findings)} files"
    body = Enum.map_join(findings, "\n\n", fn finding -> indent(finding_block(finding)) end)

    heading <> "\n\n" <> body
  end

  defp file_count(findings) do
    findings |> Enum.map(& &1.file) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
  end

  defp indent(block) do
    block |> String.split("\n") |> Enum.map_join("\n", fn line -> "  " <> line end)
  end

  # The umbrella child app owning a file: the segment after the LAST
  # "apps" — a checkout under e.g. /home/ci/apps/project must not win
  # over the umbrella's own apps/ directory.
  defp derive_app(nil), do: nil

  defp derive_app(file) do
    segments = Path.split(file)

    segments
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {"apps", index}, _closer_match -> Enum.at(segments, index + 1)
      {_segment, _index}, closest -> closest
    end)
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
