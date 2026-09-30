defmodule Temper.Push.Payload do
  @moduledoc """
  Builds what `mix temper.push` sends from history lines: batches for a
  `Temper.Push.Adapter`.

  Pure: the task reads the files and gives the lines here. Lines are
  trimmed, blank ones dropped and byte-identical copies (overlapping
  cache restores) sent once. Lines of runs the destination already accepted
  are left out, unless `all: true`. Corrupt lines (unreadable JSON such as
  truncated cache tails, or JSON that is not an object) are dropped and
  counted; objects without a `run_id` (a future kind) are kept.

  With `scrub_messages: true`, the `message` of every failed test line's
  `failure` is removed before anything leaves CI. The failure `kind` and
  `hash` stay, so failure modes still group. Only those lines are
  re-encoded; every other line goes out byte for byte.

  The lines are split into batches of whole runs, each at most
  `max_batch_bytes` uncompressed (32 MB by default), and each batch is
  gzip compressed. A run is never split (a receiver applies a run once,
  so a second half would be dropped): a run larger than the limit is not
  sent, and is listed in `:oversized`.

  A line that cannot be read is dropped, and the rest of its run is sent
  without it. History files are append-only, so the line cannot come
  back; holding the run back would lose all of it.
  """

  @default_max_batch_bytes 32_000_000

  @type t :: %{
          batches: [Temper.Push.Adapter.batch()],
          lines: non_neg_integer(),
          runs: non_neg_integer(),
          acknowledged: non_neg_integer(),
          corrupt: non_neg_integer(),
          oversized: [String.t()],
          history_run_ids: MapSet.t(String.t())
        }

  @doc """
  Builds the batches for `lines`, leaving out the runs in `acknowledged`
  (a `MapSet` of run ids).

  Options: `:all` (send acknowledged runs too), `:scrub_messages`,
  `:max_batch_bytes`. `:acknowledged` and `:corrupt` count the lines left
  out for each reason; `:lines` and `:runs` describe what is in the
  batches; `:oversized` names the runs too large to send, and
  `:history_run_ids` every run in `lines`, sent or not.
  """
  @spec build([String.t()], MapSet.t(String.t()), keyword()) :: t()
  def build(lines, acknowledged, opts \\ []) do
    all? = Keyword.get(opts, :all, false)
    scrub? = Keyword.get(opts, :scrub_messages, false)
    max_bytes = Keyword.get(opts, :max_batch_bytes, @default_max_batch_bytes)

    initial = %{kept: [], acknowledged: 0, corrupt: 0, seen: MapSet.new()}

    acc =
      lines
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.uniq()
      |> Enum.reduce(initial, fn line, acc ->
        case classify(line, acknowledged, all?, scrub?) do
          {:send, run_id, line} -> %{acc | kept: [{run_id, line} | acc.kept]} |> seen(run_id)
          {:acknowledged, run_id} -> %{acc | acknowledged: acc.acknowledged + 1} |> seen(run_id)
          :corrupt -> %{acc | corrupt: acc.corrupt + 1}
        end
      end)

    {runs, oversized} =
      acc.kept
      |> Enum.reverse()
      |> group_by_run()
      |> Enum.split_with(fn {_run_id, lines} -> size(lines) <= max_bytes end)

    %{
      batches: runs |> pack(max_bytes) |> Enum.map(&batch/1),
      lines: runs |> Enum.map(fn {_run_id, lines} -> length(lines) end) |> Enum.sum(),
      runs: Enum.count(runs, fn {run_id, _lines} -> run_id != nil end),
      acknowledged: acc.acknowledged,
      corrupt: acc.corrupt,
      oversized: for({run_id, _lines} <- oversized, do: run_id || "(a line without a run id)"),
      history_run_ids: acc.seen
    }
  end

  defp seen(acc, nil), do: acc
  defp seen(acc, run_id), do: %{acc | seen: MapSet.put(acc.seen, run_id)}

  defp size(lines), do: Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2))

  defp classify(line, acknowledged, all?, scrub?) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> classify_object(line, decoded, acknowledged, all?, scrub?)
      {:ok, _not_an_object} -> :corrupt
      {:error, _reason} -> :corrupt
    end
  end

  defp classify_object(line, decoded, acknowledged, all?, scrub?) do
    run_id = if is_binary(decoded["run_id"]), do: decoded["run_id"]
    line = if scrub?, do: scrub(line, decoded), else: line

    if not all? and run_id != nil and MapSet.member?(acknowledged, run_id),
      do: {:acknowledged, run_id},
      else: {:send, run_id, line}
  end

  defp scrub(_line, %{"kind" => "test", "failure" => %{"message" => _} = failure} = decoded) do
    Jason.encode!(%{decoded | "failure" => Map.delete(failure, "message")})
  end

  defp scrub(line, _decoded), do: line

  # Runs in the order they first appear, each with its lines in file
  # order. A line without a run id is a group of its own, so one large
  # such line never holds back the others.
  defp group_by_run(kept) do
    {order, groups} =
      Enum.reduce(kept, {[], %{}}, fn
        {nil, line}, {order, groups} ->
          key = {:line, map_size(groups)}
          {[key | order], Map.put(groups, key, [line])}

        {run_id, line}, {order, groups} ->
          case groups do
            %{^run_id => lines} -> {order, Map.put(groups, run_id, [line | lines])}
            _new -> {[run_id | order], Map.put(groups, run_id, [line])}
          end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn
      {:line, _n} = key -> {nil, groups[key]}
      run_id -> {run_id, Enum.reverse(groups[run_id])}
    end)
  end

  defp pack(runs, max_bytes) do
    Enum.chunk_while(
      runs,
      {[], 0},
      fn {_run_id, lines} = run, {batch, size} ->
        run_size = size(lines)

        if batch != [] and size + run_size > max_bytes,
          do: {:cont, Enum.reverse(batch), {[run], run_size}},
          else: {:cont, {[run | batch], size + run_size}}
      end,
      fn
        {[], _size} -> {:cont, {[], 0}}
        {batch, _size} -> {:cont, Enum.reverse(batch), {[], 0}}
      end
    )
  end

  defp batch(runs) do
    lines = Enum.flat_map(runs, fn {_run_id, lines} -> lines end)
    text = Enum.map(lines, &[&1, "\n"])

    %{
      body: :zlib.gzip(text),
      run_ids: for({run_id, _lines} <- runs, run_id != nil, do: run_id),
      lines: length(lines),
      bytes: IO.iodata_length(text)
    }
  end
end
