defmodule Temper.History.ReaderTest do
  use ExUnit.Case, async: true

  alias Temper.History.Reader
  alias Temper.Record

  @fixtures Path.expand("../../fixtures/histories", __DIR__)

  describe "read/1 with corrupt and foreign lines" do
    test "keeps good records and counts the rest" do
      result = Reader.read(Path.join(@fixtures, "corrupt.jsonl"))

      assert [%Record{status: :passed}] = result.records
      assert length(result.files) == 1

      # Not-JSON, truncated, and wrong-typed lines are corruption; the
      # suite summary and the schema-2 line are expected skips. Blank
      # lines count as neither.
      assert result.corrupt == 3
      assert result.skipped == 2
    end
  end

  describe "read/1 across partitions" do
    test "merges records from every matching file in sorted order" do
      result = Reader.read(Path.join(@fixtures, "partitioned/history-*.jsonl"))

      assert length(result.files) == 2
      assert result.corrupt == 0
      assert result.skipped == 0

      assert [
               %Record{status: :passed, context: %{partition: "0", seed: 101}},
               %Record{status: :passed, context: %{partition: "0", seed: 102}},
               %Record{status: :failed, context: %{partition: "1", seed: 103}}
             ] = result.records
    end
  end

  describe "read/1 with nothing to read" do
    test "returns an empty result for a glob matching no files" do
      result = Reader.read(Path.join(@fixtures, "does-not-exist-*.jsonl"))

      assert result == %{records: [], files: [], corrupt: 0, skipped: 0, unreadable: []}
    end
  end

  describe "read/1 with unreadable matches" do
    test "a directory caught by the glob is reported, not raised on" do
      dir =
        Path.join(System.tmp_dir!(), "temper_reader_test_#{System.unique_integer([:positive])}")

      history_dir = Path.join(dir, "history-1.jsonl")
      File.mkdir_p!(history_dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      good_line =
        File.read!(Path.join(@fixtures, "partitioned/history-0.jsonl"))

      File.write!(Path.join(dir, "history-0.jsonl"), good_line)

      result = Reader.read(Path.join(dir, "history-*.jsonl"))

      assert length(result.records) == 2
      assert result.files == [Path.join(dir, "history-0.jsonl")]
      assert result.unreadable == [history_dir]
    end
  end
end
