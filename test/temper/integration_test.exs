defmodule Temper.IntegrationTest do
  @moduledoc """
  End-to-end proof over a real fixture project (`fixtures/demo_app`):
  shells out to `mix test` twice with chosen seeds — never nested
  in-process ExUnit — then asserts the report flags exactly the
  seed-dependent test.
  """

  # Shells out and uses the global Mix shell.
  use ExUnit.Case, async: false

  # Cold runs pay for deps.get plus two mix boots.
  @moduletag timeout: 300_000
  @moduletag :integration

  @demo_app Path.expand("../../fixtures/demo_app", __DIR__)

  # Forcing a CI-style context pins the SHA and the clean flag, so the
  # verdict does not depend on the state of Temper's own repository.
  @pinned_sha String.duplicate("e2", 20)
  @env [
    {"GITHUB_ACTIONS", "true"},
    {"GITHUB_RUN_ID", "e2e"},
    {"GITHUB_SHA", @pinned_sha},
    {"GITHUB_REF_NAME", "main"},
    {"GITHUB_HEAD_REF", nil},
    {"MIX_TEST_PARTITION", nil}
  ]

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    File.rm_rf!(Path.join(@demo_app, ".temper"))
    :ok
  end

  test "two real runs produce history that flags exactly the flaky test" do
    assert {_output, 0} = run_demo(["deps.get"])

    # Even seed: both demo tests pass.
    assert {_output, 0} = run_demo(["test", "--seed", "100"])

    # Odd seed: the seed-dependent test fails, so mix test exits nonzero.
    assert {_output, exit_code} = run_demo(["test", "--seed", "101"])
    assert exit_code > 0

    payload = report_json()

    assert [finding] = payload["flaky"]
    assert finding["module"] == "DemoAppTest"
    assert finding["name"] == "test seed dependent"
    assert finding["failing_seeds"] == [101]
    assert [evidence] = finding["evidence"]
    assert evidence["sha"] == @pinned_sha
    assert evidence["dirty"] == false
    assert evidence["runs"] == 2

    # The deterministic test is nowhere in the verdict.
    assert payload["suspects"] == []
    assert payload["stats"]["records"] == 4
  end

  defp run_demo(args) do
    System.cmd("mix", args, cd: @demo_app, env: @env, stderr_to_stdout: true)
  end

  defp report_json do
    glob = Path.join(@demo_app, ".temper/history-*.jsonl")
    Mix.Task.rerun("temper.report", ["--history", glob, "--json"])

    assert_received {:mix_shell, :info, [output]}
    Jason.decode!(output)
  end
end
