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

      assert result == %{records: [], files: [], corrupt: 0, skipped: 0}
    end
  end
end
