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
  gzip compressed. A run larger than that goes alone.
  """

  @default_max_batch_bytes 32_000_000

  @type t :: %{
          batches: [Temper.Push.Adapter.batch()],
          lines: non_neg_integer(),
          runs: non_neg_integer(),
          acknowledged: non_neg_integer(),
          corrupt: non_neg_integer()
        }

  @doc """
  Builds the batches for `lines`, leaving out the runs in `acknowledged`
  (a `MapSet` of run ids).

  Options: `:all` (send acknowledged runs too), `:scrub_messages`,
  `:max_batch_bytes`. `:acknowledged` and `:corrupt` count the lines left
  out for each reason; `:lines` and `:runs` describe what is sent.
  """
  @spec build([String.t()], MapSet.t(String.t()), keyword()) :: t()
  def build(lines, acknowledged, opts \\ []) do
    all? = Keyword.get(opts, :all, false)
    scrub? = Keyword.get(opts, :scrub_messages, false)
    max_bytes = Keyword.get(opts, :max_batch_bytes, @default_max_batch_bytes)

    {kept, counts} =
      lines
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.uniq()
      |> Enum.reduce({[], %{acknowledged: 0, corrupt: 0}}, fn line, {kept, counts} ->
        case classify(line, acknowledged, all?, scrub?) do
          {:send, run_id, line} -> {[{run_id, line} | kept], counts}
          reason -> {kept, Map.update!(counts, reason, &(&1 + 1))}
        end
      end)

    runs = kept |> Enum.reverse() |> group_by_run()

    %{
      batches: runs |> pack(max_bytes) |> Enum.map(&batch/1),
      lines: length(kept),
      runs: Enum.count(runs, fn {run_id, _lines} -> run_id != nil end),
      acknowledged: counts.acknowledged,
      corrupt: counts.corrupt
    }
  end

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
      do: :acknowledged,
      else: {:send, run_id, line}
  end

  defp scrub(_line, %{"kind" => "test", "failure" => %{"message" => _} = failure} = decoded) do
    Jason.encode!(%{decoded | "failure" => Map.delete(failure, "message")})
  end

  defp scrub(line, _decoded), do: line

  # Runs in the order they first appear, each with its lines in file
  # order. Lines without a run id form one group of their own.
  defp group_by_run(kept) do
    {order, groups} =
      Enum.reduce(kept, {[], %{}}, fn {run_id, line}, {order, groups} ->
        case groups do
          %{^run_id => lines} -> {order, Map.put(groups, run_id, [line | lines])}
          _new -> {[run_id | order], Map.put(groups, run_id, [line])}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&{&1, Enum.reverse(groups[&1])})
  end

  defp pack(runs, max_bytes) do
    Enum.chunk_while(
      runs,
      {[], 0},
      fn {_run_id, lines} = run, {batch, size} ->
        run_size = Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2))

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
