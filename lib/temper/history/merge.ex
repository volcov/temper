defmodule Temper.History.Merge do
  @moduledoc """
  Merges history lines from several sources into one deduplicated
  stream — the aggregation step behind `mix temper.merge`.

  Dedupe is byte-exact on whole trimmed lines: overlapping CI cache
  restores and re-downloaded artifacts duplicate identical lines, and
  only those. Callers trim before handing lines in (as the reader
  trims before decoding), so whitespace-padded copies of one record
  collapse instead of decoding into double-counted records downstream. Lines are otherwise opaque — a merge rewrites files, so it
  must not drop what it merely does not interpret. Suite summaries and
  future schema versions pass through verbatim; only lines the codec
  calls corrupt (truncated cache tails) are dropped, and counted.

  Part of the functional core: lines in, lines out, no side effects.
  """

  alias Temper.History.Codec

  @typedoc "Kept lines in first-seen order, plus counts of what was not kept."
  @type result :: %{
          lines: [String.t()],
          duplicates: non_neg_integer(),
          corrupt: non_neg_integer()
        }

  @doc """
  Deduplicates `lines`, keeping the first occurrence of each.

  Lines must arrive trimmed; blank lines are ignored. Output order is
  input order, which makes a merge deterministic for the same inputs.
  """
  @spec merge(Enumerable.t()) :: result()
  def merge(lines) do
    initial = %{lines: [], seen: MapSet.new(), duplicates: 0, corrupt: 0}
    result = Enum.reduce(lines, initial, &collect/2)

    %{lines: Enum.reverse(result.lines), duplicates: result.duplicates, corrupt: result.corrupt}
  end

  defp collect("", acc), do: acc

  defp collect(line, acc) do
    cond do
      MapSet.member?(acc.seen, line) ->
        %{acc | duplicates: acc.duplicates + 1}

      keep?(line) ->
        %{acc | lines: [line | acc.lines], seen: MapSet.put(acc.seen, line)}

      true ->
        %{acc | corrupt: acc.corrupt + 1}
    end
  end

  defp keep?(line) do
    case Codec.decode(line) do
      {:ok, _record} -> true
      {:error, {:unsupported_kind, _kind}} -> true
      {:error, {:unsupported_schema, _version}} -> true
      {:error, _corrupt} -> false
    end
  end
end
