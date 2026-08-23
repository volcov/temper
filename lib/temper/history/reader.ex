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
  matched the glob, and counters for skipped lines.
  """
  @type result :: %{
          records: [Record.t()],
          files: [Path.t()],
          corrupt: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Reads every history file matching `glob` into records.

  Defaults to `#{inspect(@default_glob)}`. Files are read in sorted
  order; blank lines are ignored. Undecodable lines are counted
  instead of raising: `:corrupt` for malformed content (invalid JSON,
  missing keys, wrong types), `:skipped` for lines that are valid but
  not test outcomes (kind `"suite"` summaries, future schema versions).
  """
  @spec read(Path.t()) :: result()
  def read(glob \\ @default_glob) do
    files = glob |> Path.wildcard() |> Enum.sort()
    initial = %{records: [], files: files, corrupt: 0, skipped: 0}

    result = Enum.reduce(files, initial, &read_file/2)
    %{result | records: Enum.reverse(result.records)}
  end

  defp read_file(path, acc) do
    path
    |> File.stream!()
    |> Enum.reduce(acc, fn line, acc -> collect(String.trim(line), acc) end)
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
