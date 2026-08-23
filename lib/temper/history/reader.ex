defmodule Temper.History.Reader do
  @moduledoc """
  Boundary module that reads history files back into records.

  Globs `.temper/history-*.jsonl` (one file per test partition, per
  the partitioned-CI design) and decodes each line via
  `Temper.History.Codec`. Imperfect input never crashes a read:
  corrupt lines (truncated CI cache tails, editor accidents) and
  well-formed lines this version does not interpret (suite summaries,
  future schema versions) are counted and skipped.
  """

  alias Temper.History.Codec
  alias Temper.Record

  @default_glob Path.join(".temper", "history-*.jsonl")

  @typedoc """
  The outcome of a read: decoded records in file order, the files that
  were actually read, counters for skipped lines, and any matches that
  could not be read at all (directories, files removed mid-read).
  """
  @type result :: %{
          records: [Record.t()],
          files: [Path.t()],
          corrupt: non_neg_integer(),
          skipped: non_neg_integer(),
          unreadable: [Path.t()]
        }

  @doc """
  The default glob covering every partition's history file.
  """
  @spec default_glob() :: Path.t()
  def default_glob, do: @default_glob

  @doc """
  Reads every history file matching `glob` into records.

  Defaults to `#{inspect(@default_glob)}`. Files are read in sorted
  order; blank lines are ignored. Nothing about imperfect input
  raises: undecodable lines are counted (`:corrupt` for malformed
  content, `:skipped` for valid lines that are not test outcomes, such
  as suite summaries and future schema versions), and matches that
  cannot be read at all — a directory caught by the glob, a file
  deleted between matching and opening — land in `:unreadable` while
  every other file's records survive.
  """
  @spec read(Path.t()) :: result()
  def read(glob \\ @default_glob) do
    {regular, unreadable} =
      glob |> Path.wildcard() |> Enum.sort() |> Enum.split_with(&File.regular?/1)

    initial = %{records: [], files: [], corrupt: 0, skipped: 0, unreadable: unreadable}

    result = Enum.reduce(regular, initial, &read_file/2)
    %{result | records: Enum.reverse(result.records), files: Enum.reverse(result.files)}
  end

  defp read_file(path, acc) do
    read =
      path
      |> File.stream!()
      |> Enum.reduce(acc, fn line, acc -> collect(String.trim(line), acc) end)

    %{read | files: [path | read.files]}
  rescue
    # The file existed when the glob matched but cannot be read now.
    File.Error -> %{acc | unreadable: acc.unreadable ++ [path]}
  end

  defp collect("", acc), do: acc

  defp collect(line, acc) do
    case Codec.decode(line) do
      {:ok, record} -> %{acc | records: [record | acc.records]}
      {:error, {:unsupported_kind, _kind}} -> %{acc | skipped: acc.skipped + 1}
      {:error, {:unsupported_schema, _version}} -> %{acc | skipped: acc.skipped + 1}
      {:error, _corrupt} -> %{acc | corrupt: acc.corrupt + 1}
    end
  end
end
