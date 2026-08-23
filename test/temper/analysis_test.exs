defmodule Temper.AnalysisTest do
  use ExUnit.Case, async: true

  alias Temper.Analysis
  alias Temper.History.Reader
  alias Temper.Record
  alias Temper.RunContext

  @fixtures Path.expand("../fixtures/histories", __DIR__)

  defp analyze_fixture(file, opts \\ []) do
    @fixtures
    |> Path.join(file)
    |> Reader.read()
    |> Map.fetch!(:records)
    |> Analysis.analyze(opts)
  end

  defp build_record(overrides) do
    context =
      RunContext.new(%{
        run_id: overrides[:run_id] || "r1",
        at: overrides[:at] || "2026-08-20T10:00:00Z",
        sha: Map.get(Map.new(overrides), :sha, "aaa1111"),
        dirty: overrides[:dirty] || false,
        seed: overrides[:seed],
        elixir: "1.20.2",
        otp: "27"
      })

    %Record{
      context: context,
      module: overrides[:module] || "DemoTest",
      name: overrides[:name] || "test something",
      status: Keyword.fetch!(overrides, :status),
      failure: overrides[:failure]
    }
  end

  describe "clean flake (same clean SHA, both outcomes)" do
    test "is reported as flaky with per-SHA evidence" do
      assert %{flaky: [finding], suspects: []} = analyze_fixture("clean_flake.jsonl")

      assert finding.module == "DemoTest"
      assert finding.name == "test flaky"
      assert finding.runs == 4
      assert finding.passed == 2
      assert finding.failed == 2
      assert finding.flake_rate == 0.5
      assert finding.failing_seeds == [103, 104]
      assert finding.first_seen == "2026-08-20T10:00:00Z"
      assert finding.last_seen == "2026-08-20T14:00:00Z"

      # Metadata comes from the most recent record (the bbb2222 run).
      assert finding.line == 7

      # Two distinct failure modes were observed.
      assert finding.failures |> Enum.map(& &1.hash) |> Enum.sort() == ["c0ffee12", "deadbeef"]

      # Only the divergent SHA is evidence; the passing bbb2222 run is not.
      assert [%{sha: "aaa1111", dirty: false, runs: 4, flake_rate: 0.5}] = finding.evidence
    end

    test "the stable test in the same history is not reported" do
      report = analyze_fixture("clean_flake.jsonl")

      refute Enum.any?(report.flaky ++ report.suspects, &(&1.name == "test stable"))
    end
  end

  describe "fail-only-on-a-broken-SHA" do
    test "cross-SHA divergence is NOT flaky" do
      assert %{flaky: [], suspects: []} = analyze_fixture("broken_sha.jsonl")
    end
  end

  describe "dirty-tree divergence" do
    test "lands in the suspects bucket, not flaky" do
      assert %{flaky: [], suspects: [finding]} = analyze_fixture("dirty_divergence.jsonl")

      assert finding.name == "test dirty divergence"
      assert [%{sha: "ccc3333", dirty: true, runs: 2, passed: 1, failed: 1}] = finding.evidence
    end
  end

  describe "multi-partition history" do
    test "divergence across partition files is detected after the merge" do
      assert %{flaky: [finding], suspects: []} =
               analyze_fixture("partitioned/history-*.jsonl")

      assert finding.name == "test flaky"
      assert finding.runs == 3
      assert finding.failing_seeds == [103]
    end
  end

  describe "min_runs" do
    test "filters out evidence from thin SHAs" do
      assert %{flaky: [], suspects: []} = analyze_fixture("clean_flake.jsonl", min_runs: 5)
    end

    test "keeps evidence meeting the threshold" do
      assert %{flaky: [_finding]} = analyze_fixture("clean_flake.jsonl", min_runs: 4)
    end
  end

  describe "records that cannot provide same-SHA evidence" do
    test "runs without a SHA are ignored" do
      records = [
        build_record(status: :passed, sha: nil),
        build_record(status: :failed, sha: nil)
      ]

      assert %{flaky: [], suspects: []} = Analysis.analyze(records)
    end

    test "non-run statuses are ignored" do
      records = [
        build_record(status: :passed),
        build_record(status: :skipped),
        build_record(status: :excluded),
        build_record(status: :invalid)
      ]

      assert %{flaky: [], suspects: []} = Analysis.analyze(records)
    end
  end

  describe "a test with both clean and dirty evidence" do
    test "appears only under flaky" do
      records = [
        build_record(status: :passed, seed: 1),
        build_record(status: :failed, seed: 2),
        build_record(status: :passed, sha: "ddd4444", seed: 3),
        build_record(status: :failed, sha: "ddd4444", dirty: true, seed: 4)
      ]

      assert %{flaky: [finding], suspects: []} = Analysis.analyze(records)
      assert [%{sha: "aaa1111"}] = finding.evidence
    end
  end

  describe "report ordering" do
    test "sorts by flake rate, then run count, descending" do
      records =
        [
          Enum.map(1..9, fn i -> build_record(name: "test mild", status: :passed, seed: i) end),
          [build_record(name: "test mild", status: :failed, seed: 10)],
          [
            build_record(name: "test wild", status: :passed, seed: 1),
            build_record(name: "test wild", status: :failed, seed: 2)
          ]
        ]
        |> List.flatten()

      assert %{flaky: [%{name: "test wild"}, %{name: "test mild"}]} = Analysis.analyze(records)
    end
  end
end
