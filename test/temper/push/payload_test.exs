defmodule Temper.Push.PayloadTest do
  use ExUnit.Case, async: true

  alias Temper.Push.Payload

  @run_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @run_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  defp line(run_id, name, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "schema" => 1,
          "kind" => "test",
          "run_id" => run_id,
          "name" => name,
          "status" => "passed"
        },
        extra
      )
    )
  end

  defp failed(run_id, name) do
    line(run_id, name, %{
      "status" => "failed",
      "failure" => %{
        "kind" => "ExUnit.AssertionError",
        "message" => "secret",
        "hash" => "0498be8e"
      }
    })
  end

  defp inflate(%{body: body}), do: body |> :zlib.gunzip() |> String.split("\n", trim: true)

  test "sends every line of unacknowledged runs, gzip compressed, in file order" do
    lines = [line(@run_a, "t1"), line(@run_b, "t1"), line(@run_a, "t2")]

    payload = Payload.build(lines, MapSet.new())

    assert [batch] = payload.batches
    assert inflate(batch) == [line(@run_a, "t1"), line(@run_a, "t2"), line(@run_b, "t1")]
    assert batch.run_ids == [@run_a, @run_b]
    assert batch.lines == 3
    assert payload.runs == 2
    assert payload.lines == 3
  end

  test "leaves out acknowledged runs, unless all" do
    lines = [line(@run_a, "t1"), line(@run_b, "t1")]

    payload = Payload.build(lines, MapSet.new([@run_a]))
    assert [%{run_ids: [@run_b]}] = payload.batches
    assert payload.acknowledged == 1

    assert [%{run_ids: [@run_a, @run_b]}] =
             Payload.build(lines, MapSet.new([@run_a]), all: true).batches
  end

  test "nothing to send when every run is acknowledged" do
    payload = Payload.build([line(@run_a, "t1")], MapSet.new([@run_a]))

    assert payload.batches == []
    assert payload.lines == 0
  end

  test "blank lines, surrounding whitespace and exact copies go once" do
    lines = ["", "  " <> line(@run_a, "t1") <> "\r", line(@run_a, "t1"), "   "]

    assert [batch] = Payload.build(lines, MapSet.new()).batches
    assert inflate(batch) == [line(@run_a, "t1")]
  end

  test "corrupt lines are dropped and counted; objects without a run id are kept" do
    lines = ["{broken", ~s({"schema":1,"kind":"note"}), "[1]", line(@run_a, "t1")]

    payload = Payload.build(lines, MapSet.new())

    assert payload.corrupt == 2
    assert [batch] = payload.batches
    assert inflate(batch) == [~s({"schema":1,"kind":"note"}), line(@run_a, "t1")]
    assert batch.run_ids == [@run_a]
    assert payload.runs == 1
  end

  test "scrubbing removes failure messages and keeps kind and hash" do
    passing = line(@run_a, "t1", %{"zz_unknown" => [1, 2]})
    lines = [passing, failed(@run_a, "t2")]

    assert [batch] = Payload.build(lines, MapSet.new(), scrub_messages: true).batches
    [kept, scrubbed] = inflate(batch)

    # Untouched lines go out byte for byte, unknown keys included.
    assert kept == passing

    decoded = Jason.decode!(scrubbed)
    assert decoded["failure"] == %{"kind" => "ExUnit.AssertionError", "hash" => "0498be8e"}
    assert decoded["name"] == "t2"
    refute scrubbed =~ "secret"
  end

  test "without scrubbing, failure messages go as recorded" do
    assert [batch] = Payload.build([failed(@run_a, "t1")], MapSet.new()).batches
    assert inflate(batch) == [failed(@run_a, "t1")]
  end

  test "large pushes are split into batches of whole runs" do
    lines = for run <- [@run_a, @run_b], i <- 1..10, do: line(run, "test #{i}")
    run_size = lines |> Enum.take(10) |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()

    payload = Payload.build(lines, MapSet.new(), max_batch_bytes: run_size + 1)

    assert [%{run_ids: [@run_a]} = first, %{run_ids: [@run_b]}] = payload.batches
    assert length(inflate(first)) == 10
    assert first.bytes == run_size

    # A run larger than the limit still goes, alone.
    assert [%{run_ids: [@run_a]}, %{run_ids: [@run_b]}] =
             Payload.build(lines, MapSet.new(), max_batch_bytes: 10).batches
  end
end
