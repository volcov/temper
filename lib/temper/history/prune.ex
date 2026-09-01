defmodule Temper.History.Prune do
  @moduledoc """
  Selective retention for history files — the pure core behind
  `mix temper.clean --older-than` and `--keep-shas`.

  A retention criterion only ever drops lines it can positively
  match: age drops a line only when it carries a readable timestamp
  older than the cutoff, and SHA retention only when it carries a
  SHA outside the kept set. Everything else — suite summaries under
  SHA retention, null-SHA records, future kinds — survives: what a
  criterion cannot read, it cannot claim. Corrupt lines (unreadable
  JSON) are the one exception: a rewrite is the chance to drop them,
  counted, exactly as `mix temper.merge` does.

  Part of the functional core: lines in, lines out, no side effects.
  """

  @typedoc "Each file's kept lines in order, plus counts of what was dropped."
  @type result :: %{
          files: [{Path.t(), [String.t()]}],
          pruned: non_neg_integer(),
          corrupt: non_neg_integer()
        }

  @doc """
  Applies the retention criteria to every file's lines.

  Options (a `nil` value disables that criterion):

    * `:cutoff` — a `DateTime`; lines whose `"at"` is older are
      dropped
    * `:keep_shas` — how many of the most recently recorded distinct
      SHAs to keep, ranked by each SHA's newest line across all files

  Lines must arrive trimmed; blank lines vanish without counting.
  """
  @spec prune([{Path.t(), [String.t()]}], keyword()) :: result()
  def prune(files, opts) do
    decoded =
      Enum.map(files, fn {path, lines} -> {path, Enum.map(lines, &decode/1)} end)

    cutoff = opts[:cutoff]
    kept_shas = kept_shas(decoded, opts[:keep_shas])
    initial = %{files: [], pruned: 0, corrupt: 0}

    result =
      Enum.reduce(decoded, initial, fn {path, lines}, acc ->
        file = filter(lines, cutoff, kept_shas)

        %{
          files: [{path, file.kept} | acc.files],
          pruned: acc.pruned + file.pruned,
          corrupt: acc.corrupt + file.corrupt
        }
      end)

    %{result | files: Enum.reverse(result.files)}
  end

  defp filter(lines, cutoff, kept_shas) do
    initial = %{kept: [], pruned: 0, corrupt: 0}

    result =
      Enum.reduce(lines, initial, fn
        :blank, acc ->
          acc

        {:corrupt, _line}, acc ->
          %{acc | corrupt: acc.corrupt + 1}

        {:ok, line, map}, acc ->
          if within_age?(map, cutoff) and within_shas?(map, kept_shas) do
            %{acc | kept: [line | acc.kept]}
          else
            %{acc | pruned: acc.pruned + 1}
          end
      end)

    %{result | kept: Enum.reverse(result.kept)}
  end

  # Fields are read generically from the JSON, not through the codec:
  # retention must see the timestamp of a suite summary or a future
  # kind the codec refuses to interpret.
  defp decode(""), do: :blank

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, line, map}
      _not_a_history_line -> {:corrupt, line}
    end
  end

  # Timestamps are parsed, never compared as strings: Temper's own
  # writer emits second-truncated UTC, but retention reads lines
  # generically, and a third-party producer's fractional seconds or
  # numeric offset would misorder lexically — and a misorder here
  # deletes data. An unparseable timestamp is unreadable, so the line
  # survives.
  defp within_age?(_map, nil), do: true

  defp within_age?(%{"at" => at}, cutoff) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> DateTime.compare(datetime, cutoff) != :lt
      {:error, _unreadable} -> true
    end
  end

  defp within_age?(_no_timestamp, _cutoff), do: true

  defp within_shas?(_map, nil), do: true

  defp within_shas?(%{"sha" => sha}, kept) when is_binary(sha),
    do: MapSet.member?(kept, sha)

  defp within_shas?(_no_sha, _kept), do: true

  defp kept_shas(_decoded, nil), do: nil

  defp kept_shas(decoded, count) do
    decoded
    |> Enum.flat_map(fn {_path, lines} -> lines end)
    |> Enum.reduce(%{}, &newest_by_sha/2)
    |> Enum.sort_by(fn {_sha, at} -> at end, {:desc, DateTime})
    |> Enum.take(count)
    |> MapSet.new(fn {sha, _at} -> sha end)
  end

  # Ranking parses timestamps for the same reason within_age?/2 does;
  # a SHA whose every timestamp is unparseable never ranks, and its
  # lines then drop with any other unkept SHA.
  defp newest_by_sha({:ok, _line, %{"sha" => sha, "at" => at}}, acc)
       when is_binary(sha) and is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> Map.update(acc, sha, datetime, &later(&1, datetime))
      {:error, _unreadable} -> acc
    end
  end

  defp newest_by_sha(_other, acc), do: acc

  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
end
