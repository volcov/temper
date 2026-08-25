defmodule Mix.Tasks.Temper.ReportTest do
  # Mix.shell/1 is global state.
  use ExUnit.Case, async: false

  @fixtures Path.expand("../../fixtures/histories", __DIR__)

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp run_report(args) do
    Mix.Task.rerun("temper.report", args)

    assert_received {:mix_shell, :info, [output]}
    output
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "human report" do
    test "lists flaky tests with location, evidence and seeds" do
      output = run_report(["--history", fixture("clean_flake.jsonl")])

      assert output =~ "Flaky tests (divergent outcomes on same git SHA):"
      assert output =~ "DemoTest test flaky"
      assert output =~ "test/demo_test.exs:7  async: true"
      assert output =~ "4 runs on aaa1111: 2 passed / 2 failed (50.0% flake rate)"
      assert output =~ "failing seeds: 103, 104"
      assert output =~ "Read 7 test outcomes from 1 history files."
      refute output =~ "test stable"
      refute output =~ "Suspects"
    end

    test "lists dirty-tree divergence under suspects" do
      output = run_report(["--history", fixture("dirty_divergence.jsonl")])

      assert output =~ "Suspects (divergence involving dirty-tree runs — lower confidence):"
      assert output =~ "DemoTest test dirty divergence"
      assert output =~ "2 runs on ccc3333 (dirty): 1 passed / 1 failed (50.0% flake rate)"
      refute output =~ "Flaky tests"
    end

    test "reports a clean bill of health" do
      output = run_report(["--history", fixture("broken_sha.jsonl")])

      assert output =~ "No flaky tests detected."
      assert output =~ "Read 4 test outcomes from 1 history files."
    end

    test "mentions corrupt lines in the footer" do
      output = run_report(["--history", fixture("corrupt.jsonl")])

      assert output =~ "3 corrupt lines skipped."
    end

    test "explains setup when no history exists" do
      output = run_report(["--history", fixture("nothing-here-*.jsonl")])

      assert output =~ "No history files found matching"
      assert output =~ "ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])"
    end

    test "merges partitioned histories through a glob" do
      output = run_report(["--history", fixture("partitioned/history-*.jsonl")])

      assert output =~ "DemoTest test flaky"
      assert output =~ "Read 3 test outcomes from 2 history files."
    end

    test "a {partition} placeholder widens to every partition's file" do
      output = run_report(["--history", fixture("partitioned/history-{partition}.jsonl")])

      assert output =~ "DemoTest test flaky"
      assert output =~ "Read 3 test outcomes from 2 history files."
    end

    test "--min-runs raises the evidence threshold" do
      output = run_report(["--history", fixture("clean_flake.jsonl"), "--min-runs", "5"])

      assert output =~ "No flaky tests detected."
    end
  end

  describe "--by-app report" do
    test "groups findings by umbrella child app with counts and files" do
      output = run_report(["--history", fixture("umbrella.jsonl"), "--by-app"])

      assert output =~ "accounts — 2 flaky across 2 files"
      assert output =~ "billing — 1 flaky across 1 files"

      # The accounts group (more findings) comes first, with its
      # findings indented beneath the heading.
      assert [_before, accounts_section] = String.split(output, "accounts — 2 flaky", parts: 2)
      [accounts_body, _rest] = String.split(accounts_section, "billing —", parts: 2)
      assert accounts_body =~ "    Accounts.UserTest test concurrent update"
      assert accounts_body =~ "    Accounts.RoleTest test race"
      refute accounts_body =~ "Billing.InvoiceTest"
    end

    test "findings without an apps/ path segment group under (root)" do
      output = run_report(["--history", fixture("clean_flake.jsonl"), "--by-app"])

      assert output =~ "(root) — 1 flaky across 1 files"
      assert output =~ "    DemoTest test flaky"
    end

    test "without the flag the report stays flat" do
      output = run_report(["--history", fixture("umbrella.jsonl")])

      refute output =~ "across"
      assert output =~ "  Accounts.UserTest test concurrent update"
    end
  end

  describe "--json report" do
    test "emits the machine-readable payload" do
      output = run_report(["--history", fixture("clean_flake.jsonl"), "--json"])

      payload = Jason.decode!(output)

      assert payload["schema"] == 1
      assert payload["kind"] == "report"
      assert payload["stats"]["records"] == 7
      assert payload["suspects"] == []

      assert [finding] = payload["flaky"]
      assert finding["name"] == "test flaky"
      assert finding["flake_rate"] == 0.5
      assert finding["failing_seeds"] == [103, 104]
      assert [%{"sha" => "aaa1111"}] = finding["evidence"]

      # No apps/ segment in this fixture's paths.
      assert finding["app"] == nil
    end

    test "findings carry the derived umbrella app" do
      output = run_report(["--history", fixture("umbrella.jsonl"), "--json"])

      apps =
        output
        |> Jason.decode!()
        |> Map.fetch!("flaky")
        |> Enum.map(& &1["app"])
        |> Enum.sort()

      assert apps == ["accounts", "accounts", "billing"]
    end
  end
end
