defmodule Mix.Tasks.Temper.Clean do
  @shortdoc "Deletes or prunes recorded test history"

  @moduledoc """
  Deletes Temper's recorded history files, or prunes lines from them.

      $ mix temper.clean
      $ mix temper.clean --older-than 90
      $ mix temper.clean --keep-shas 50

  Without retention flags, removes every file matching
  `.temper/history-*.jsonl` (all partitions). Useful when the history
  predates a large refactor and its evidence no longer says anything
  about today's tests.

  With retention flags, files are rewritten in place instead: lines
  outside the retention window are dropped, files left empty are
  removed, and corrupt lines (truncated cache tails) are dropped and
  counted. This keeps a history persisted across CI runs bounded
  without discarding the current evidence window.

  ## Options

    * `--history GLOB` — operate on files matching this path or glob
      instead of the default (also configurable with
      `config :temper, history_path: "..."`). A literal `{partition}`
      widens to `*`, covering every partition's file
    * `--older-than DAYS` — keep only lines recorded within the last
      DAYS days
    * `--keep-shas N` — keep only lines whose commit SHA is among the
      N most recently recorded distinct SHAs. Lines without a SHA
      (suite summaries, null-SHA records, future kinds) are untouched
      by this flag: what it cannot read, it cannot claim. Use
      `--older-than` to age those out

  With both flags, a line must satisfy both to survive.
  """

  use Mix.Task

  alias Temper.History.Prune
  alias Temper.History.Reader
  alias Temper.History.Template

  @switches [history: :string, older_than: :integer, keep_shas: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    retention = retention!(opts)

    source =
      Template.to_glob(
        opts[:history] || Application.get_env(:temper, :history_path) || Reader.default_glob()
      )

    matches = Path.wildcard(source)
    {files, directories} = Enum.split_with(matches, &File.regular?/1)

    Enum.each(directories, fn dir ->
      Mix.shell().error("Skipping #{dir}: not a regular file.")
    end)

    cond do
      matches == [] -> Mix.shell().info("No history files matching #{source}.")
      retention == [] -> delete(files)
      true -> prune(files, retention)
    end
  end

  defp retention!(opts) do
    retention = Keyword.take(opts, [:older_than, :keep_shas])

    Enum.each(retention, fn {flag, value} ->
      if value < 1 do
        name = flag |> Atom.to_string() |> String.replace("_", "-")
        Mix.raise("--#{name} must be a positive integer, got: #{value}")
      end
    end)

    retention
  end

  defp delete(files) do
    {deleted, failed} = Enum.split_with(files, fn file -> File.rm(file) == :ok end)

    Enum.each(failed, fn file ->
      Mix.shell().error("Could not delete #{file}.")
    end)

    Mix.shell().info("Deleted #{length(deleted)} history files.")
  end

  defp prune(files, retention) do
    {pairs, unreadable} = read_lines(files)

    Enum.each(unreadable, fn file ->
      Mix.shell().error("Could not read #{file}.")
    end)

    result =
      Prune.prune(pairs,
        cutoff: cutoff(retention[:older_than]),
        keep_shas: retention[:keep_shas]
      )

    outcomes = Enum.map(result.files, fn {path, kept} -> rewrite(path, kept) end)

    Enum.zip(result.files, outcomes)
    |> Enum.each(fn
      {{path, _kept}, :failed} -> Mix.shell().error("Could not rewrite #{path}.")
      {_file, _ok} -> :ok
    end)

    removed = Enum.count(outcomes, &(&1 == :removed))
    failed = Enum.count(outcomes, &(&1 == :failed))

    Mix.shell().info(message(result, removed, failed))
  end

  defp read_lines(files) do
    Enum.reduce(files, {[], []}, fn file, {pairs, unreadable} ->
      case File.read(file) do
        {:ok, content} ->
          lines = content |> String.split("\n") |> Enum.map(&String.trim/1)
          {pairs ++ [{file, lines}], unreadable}

        {:error, _vanished} ->
          {pairs, unreadable ++ [file]}
      end
    end)
  end

  defp cutoff(nil), do: nil

  defp cutoff(days) do
    DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end

  defp rewrite(path, []) do
    case File.rm(path) do
      :ok -> :removed
      {:error, _reason} -> :failed
    end
  end

  # Write-to-temp-then-rename keeps each file all-or-nothing: a
  # failure leaves the old content intact instead of a half-truncated
  # file, which is what makes the failure report below true.
  defp rewrite(path, lines) do
    temp = path <> ".tmp"

    with :ok <- File.write(temp, Enum.map(lines, &[&1, "\n"])),
         :ok <- File.rename(temp, path) do
      :rewritten
    else
      {:error, _reason} ->
        _ = File.rm(temp)
        :failed
    end
  end

  defp message(result, removed, failed) do
    kept = result.files |> Enum.map(fn {_path, lines} -> length(lines) end) |> Enum.sum()
    total = kept + result.pruned + result.corrupt

    "Pruned #{result.pruned} of #{total} lines across #{length(result.files)} files." <>
      removed_note(removed) <> corrupt_note(result.corrupt) <> failed_note(failed)
  end

  defp removed_note(0), do: ""
  defp removed_note(count), do: " Removed #{count} emptied files."

  defp corrupt_note(0), do: ""
  defp corrupt_note(count), do: " #{count} corrupt lines dropped."

  defp failed_note(0), do: ""
  defp failed_note(count), do: " #{count} files kept their old content."
end
