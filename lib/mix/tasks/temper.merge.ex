defmodule Mix.Tasks.Temper.Merge do
  @shortdoc "Merges history files into one deduplicated file"

  @moduledoc """
  Merges recorded history files into a single deduplicated file.

      $ mix temper.merge --output merged.jsonl artifacts/*/history-*.jsonl
      $ mix temper.merge --output .temper/history-0.jsonl

  This is the aggregation step of the CI artifact flow: each job
  uploads its `.temper/` directory as an artifact, a later step (or
  your machine) downloads them all, merges, and runs
  `mix temper.report` against the result. Merging also compacts
  overlapping cache restores — byte-identical lines are written once.

  Positional arguments are input globs (a plain path is a glob
  matching just itself); a literal `{partition}` widens to `*`.
  Without arguments, inputs default to
  the configured history path (`config :temper, history_path`) or the
  default `.temper/history-*.jsonl` — useful for compacting every
  partition's file into one.

  Lines this Temper version does not interpret (suite summaries,
  future schema versions) are preserved verbatim; corrupt lines
  (truncated cache tails) are skipped and counted. Surrounding
  whitespace is normalized away before comparison, exactly as the
  reader does — so whitespace-padded copies of a record (a
  CRLF-converted file, an edited line) dedupe instead of turning into
  double-counted records. The output file is replaced, and may itself
  be one of the inputs.

  ## Options

    * `--output PATH` (required) — the file to write

  """

  use Mix.Task

  alias Temper.History.Merge
  alias Temper.History.Reader
  alias Temper.History.Template

  @switches [output: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, sources} = OptionParser.parse!(argv, strict: @switches)
    output = output!(opts)

    sources = if sources == [], do: [default_source()], else: sources

    {files, irregular} =
      sources
      |> Enum.map(&Template.to_glob/1)
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.split_with(&File.regular?/1)

    Enum.each(irregular, fn path ->
      Mix.shell().error("Skipping #{path}: not a regular file.")
    end)

    case files do
      [] -> Mix.shell().info("No history files matching #{Enum.join(sources, " ")}.")
      files -> merge(files, output)
    end
  end

  defp merge(files, output) do
    {lines, unreadable} = read_lines(files)

    Enum.each(unreadable, fn path ->
      Mix.shell().error("Could not read #{path}.")
    end)

    result = Merge.merge(lines)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Enum.map(result.lines, &[&1, "\n"]))

    Mix.shell().info(message(result, length(files) - length(unreadable), output))
  end

  defp output!(opts) do
    output = opts[:output] || Mix.raise("mix temper.merge requires --output PATH")

    if String.contains?(output, "{partition}") do
      Mix.raise(
        "--output must be a concrete file path — merging collapses partitions, " <>
          "so {partition} has no meaning there"
      )
    end

    output
  end

  defp default_source do
    Application.get_env(:temper, :history_path) || Reader.default_glob()
  end

  # All inputs are read before the output is opened, so merging into a
  # file that is also an input never truncates unread lines.
  defp read_lines(files) do
    {chunks, unreadable} =
      Enum.reduce(files, {[], []}, fn file, {chunks, unreadable} ->
        case File.read(file) do
          {:ok, content} -> {[lines(content) | chunks], unreadable}
          {:error, _vanished} -> {chunks, unreadable ++ [file]}
        end
      end)

    {chunks |> Enum.reverse() |> Enum.concat(), unreadable}
  end

  defp lines(content) do
    content |> String.split("\n") |> Enum.map(&String.trim/1)
  end

  defp message(result, file_count, output) do
    "Merged #{length(result.lines)} lines from #{file_count} files into #{output}." <>
      note(result.duplicates, "duplicate lines dropped") <>
      note(result.corrupt, "corrupt lines skipped")
  end

  defp note(0, _label), do: ""
  defp note(count, label), do: " #{count} #{label}."
end
