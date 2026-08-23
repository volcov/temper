defmodule Temper.Analysis do
  @moduledoc """
  Classifies recorded test outcomes into flaky tests and suspects.

  The definition of flaky is deliberately conservative: a test is
  **flaky** when it both passed and failed on the *same clean git SHA*
  — the code did not change, the outcome did. Divergence that only
  shows up when dirty-tree runs are included lands in the secondary
  **suspects** bucket: uncommitted changes could explain it, so the
  confidence is lower.

  What never counts: divergence across *different* SHAs (a commit may
  simply have broken and fixed the test), runs without a SHA, and
  non-run statuses (skipped/excluded/invalid). This trades recall for
  zero false positives — the report is meant to be trusted.

  This module is part of Temper's functional core: records in, report
  data out, no side effects.
  """

  alias Temper.Record

  @default_min_runs 2

  @typedoc "A distinct failure signature observed in failing runs."
  @type failure_signature :: %{kind: String.t(), message: String.t(), hash: String.t()}

  @typedoc "Per-SHA tallies backing a finding. `dirty: true` marks suspect evidence."
  @type evidence :: %{
          sha: String.t(),
          dirty: boolean(),
          runs: pos_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          flake_rate: float(),
          failing_seeds: [integer()],
          failures: [failure_signature()]
        }

  @typedoc "One flaky or suspect test, with its aggregated evidence."
  @type finding :: %{
          module: String.t(),
          name: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          async: boolean() | nil,
          runs: pos_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          flake_rate: float(),
          first_seen: String.t(),
          last_seen: String.t(),
          failing_seeds: [integer()],
          failures: [failure_signature()],
          evidence: [evidence()]
        }

  @type report :: %{flaky: [finding()], suspects: [finding()]}

  @doc """
  Analyzes records into a report of flaky tests and suspects.

  Options:

    * `:min_runs` — minimum runs on a SHA for its divergence to count
      as evidence (default #{@default_min_runs}). Raising it trades
      detection speed for confidence.

  Both lists are sorted by flake rate (then run count), descending.
  A test with clean-SHA evidence appears only under `:flaky`, never
  under `:suspects` as well.
  """
  @spec analyze([Record.t()], keyword()) :: report()
  def analyze(records, opts \\ []) do
    min_runs = Keyword.get(opts, :min_runs, @default_min_runs)

    records
    |> Enum.filter(&considered?/1)
    |> Enum.group_by(fn record -> {record.module, record.name} end)
    |> Enum.map(fn {_test_id, test_records} -> classify(test_records, min_runs) end)
    |> Enum.reduce(%{flaky: [], suspects: []}, fn
      {:flaky, finding}, report -> %{report | flaky: [finding | report.flaky]}
      {:suspect, finding}, report -> %{report | suspects: [finding | report.suspects]}
      :stable, report -> report
    end)
    |> sort_report()
  end

  # Only actual runs on known code can provide same-SHA evidence.
  defp considered?(%Record{status: status, context: context}) do
    status in [:passed, :failed] and is_binary(context.sha)
  end

  defp classify(test_records, min_runs) do
    by_sha = Enum.group_by(test_records, fn record -> record.context.sha end)

    case {flaky_evidence(by_sha, min_runs), suspect_evidence(by_sha, min_runs)} do
      {[_ | _] = evidence, _suspect} -> {:flaky, build_finding(test_records, evidence)}
      {[], [_ | _] = evidence} -> {:suspect, build_finding(test_records, evidence)}
      {[], []} -> :stable
    end
  end

  defp flaky_evidence(by_sha, min_runs) do
    by_sha
    |> Enum.map(fn {sha, runs} -> {sha, Enum.reject(runs, & &1.context.dirty)} end)
    |> Enum.filter(fn {_sha, clean} -> length(clean) >= min_runs and divergent?(clean) end)
    |> Enum.map(fn {sha, clean} -> build_evidence(sha, false, clean) end)
  end

  defp suspect_evidence(by_sha, min_runs) do
    by_sha
    |> Enum.filter(fn {_sha, runs} ->
      Enum.any?(runs, & &1.context.dirty) and length(runs) >= min_runs and divergent?(runs)
    end)
    |> Enum.map(fn {sha, runs} -> build_evidence(sha, true, runs) end)
  end

  defp divergent?(runs) do
    Enum.any?(runs, &(&1.status == :passed)) and Enum.any?(runs, &(&1.status == :failed))
  end

  defp build_evidence(sha, dirty, runs) do
    {passed, failed} = Enum.split_with(runs, &(&1.status == :passed))

    %{
      sha: sha,
      dirty: dirty,
      runs: length(runs),
      passed: length(passed),
      failed: length(failed),
      flake_rate: length(failed) / length(runs),
      failing_seeds: failing_seeds(failed),
      failures: distinct_failures(failed)
    }
  end

  defp build_finding(test_records, evidence) do
    latest = Enum.max_by(test_records, & &1.context.at)
    timestamps = Enum.map(test_records, & &1.context.at)
    runs = evidence |> Enum.map(& &1.runs) |> Enum.sum()
    failed = evidence |> Enum.map(& &1.failed) |> Enum.sum()

    %{
      module: latest.module,
      name: latest.name,
      file: latest.file,
      line: latest.line,
      async: latest.async,
      runs: runs,
      passed: runs - failed,
      failed: failed,
      flake_rate: failed / runs,
      first_seen: Enum.min(timestamps),
      last_seen: Enum.max(timestamps),
      failing_seeds: evidence |> Enum.flat_map(& &1.failing_seeds) |> Enum.uniq() |> Enum.sort(),
      failures: evidence |> Enum.flat_map(& &1.failures) |> Enum.uniq_by(& &1.hash),
      evidence: Enum.sort_by(evidence, & &1.runs, :desc)
    }
  end

  defp failing_seeds(failed_runs) do
    failed_runs
    |> Enum.map(& &1.context.seed)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp distinct_failures(failed_runs) do
    failed_runs
    |> Enum.map(& &1.failure)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.hash)
  end

  defp sort_report(report) do
    %{
      flaky: sort_findings(report.flaky),
      suspects: sort_findings(report.suspects)
    }
  end

  defp sort_findings(findings) do
    Enum.sort_by(findings, fn finding -> {finding.flake_rate, finding.runs} end, :desc)
  end
end
