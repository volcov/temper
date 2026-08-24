defmodule Temper.UmbrellaIntegrationTest do
  @moduledoc """
  End-to-end proof of the README's umbrella recipe over a real
  umbrella fixture (`fixtures/umbrella_demo`): Temper declared only at
  the umbrella root, the formatter registered only via
  `config :ex_unit`, real shelled-out `mix test` runs — then the
  report groups the child's real (absolute, per-child-cwd) file paths
  under the right app.
  """

  # Shells out and inspects shared fixture state.
  use ExUnit.Case, async: false

  # Cold runs pay for deps.get plus two mix boots.
  @moduletag timeout: 300_000
  @moduletag :integration

  @umbrella Path.expand("../../fixtures/umbrella_demo", __DIR__)

  # Pinning the context keeps the verdict independent of Temper's own
  # repository state (and exercises the TEMPER_* overrides for real).
  @pinned_sha String.duplicate("ab", 20)
  @env [
    {"TEMPER_SHA", @pinned_sha},
    {"TEMPER_DIRTY", nil},
    {"TEMPER_BRANCH", nil},
    {"MIX_TEST_PARTITION", nil}
  ]

  setup do
    File.rm_rf!(Path.join(@umbrella, ".temper"))
    :ok
  end

  test "root-only dep records every child and --by-app groups real paths" do
    assert {_output, 0} = run(["deps.get"])

    # Even seed: everything passes. Odd seed: alpha's test fails.
    assert {_output, 0} = run(["test", "--seed", "100"])
    assert {_output, exit_code} = run(["test", "--seed", "101"])
    assert exit_code > 0

    # The report task is available at the umbrella root (root-only dep)
    # and groups the recorded absolute paths under the child app.
    {report, 0} = run(["temper.report", "--by-app"])

    assert report =~ "alpha — 1 flaky across 1 files"
    assert report =~ "    AlphaTest test seed dependent"
    refute report =~ "beta —"

    {json_output, 0} = run(["temper.report", "--json"])
    payload = json_output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert [finding] = payload["flaky"]
    assert finding["app"] == "alpha"
    assert finding["file"] =~ "apps/alpha/test/alpha_test.exs"
    assert payload["stats"]["records"] == 4
  end

  defp run(args) do
    System.cmd("mix", args, cd: @umbrella, env: @env, stderr_to_stdout: true)
  end
end
