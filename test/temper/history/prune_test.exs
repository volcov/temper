defmodule Temper.History.PruneTest do
  use ExUnit.Case, async: true

  alias Temper.History.Codec
  alias Temper.History.Prune
  alias Temper.Record
  alias Temper.RunContext

  defp test_line(overrides \\ []) do
    context =
      RunContext.new(%{
        run_id: Keyword.get(overrides, :run_id, "9f1c2b3a4d5e6f708192a3b4c5d6e7f8"),
        at: Keyword.get(overrides, :at, "2026-08-24T12:00:00Z"),
        sha: Keyword.get(overrides, :sha, "abc1234"),
        elixir: "1.20.2",
        otp: "27"
      })

    Codec.encode(%Record{
      context: context,
      module: "DemoTest",
      name: Keyword.get(overrides, :name, "test x"),
      status: :passed
    })
  end

  defp suite_line(at) do
    context =
      RunContext.new(%{
        run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
        at: at,
        elixir: "1.20.2",
        otp: "27"
      })

    Codec.encode_suite(context, %{tests: 3, times_us: nil})
  end

  describe "prune/2 with :cutoff" do
    test "drops lines recorded before the cutoff, keeps the rest" do
      old = test_line(at: "2026-05-01T00:00:00Z")
      new = test_line(at: "2026-08-24T12:00:00Z")

      result = Prune.prune([{"h-0.jsonl", [old, new]}], cutoff: "2026-08-01T00:00:00Z")

      assert result.files == [{"h-0.jsonl", [new]}]
      assert result.pruned == 1
      assert result.corrupt == 0
    end

    test "suite summary lines age out with their run" do
      old_suite = suite_line("2026-05-01T00:00:00Z")
      new_suite = suite_line("2026-08-24T12:00:00Z")

      result =
        Prune.prune([{"h-0.jsonl", [old_suite, new_suite]}], cutoff: "2026-08-01T00:00:00Z")

      assert result.files == [{"h-0.jsonl", [new_suite]}]
      assert result.pruned == 1
    end

    test "lines without a readable timestamp are preserved" do
      future = ~s({"schema":2,"kind":"checkpoint","payload":true})

      result = Prune.prune([{"h-0.jsonl", [future]}], cutoff: "2026-08-01T00:00:00Z")

      assert result.files == [{"h-0.jsonl", [future]}]
      assert result.pruned == 0
    end
  end

  describe "prune/2 with :keep_shas" do
    test "keeps the N most recent distinct SHAs, ranked by newest record" do
      oldest = test_line(sha: "sha_old", at: "2026-08-01T00:00:00Z")
      middle = test_line(sha: "sha_mid", at: "2026-08-10T00:00:00Z")
      newest = test_line(sha: "sha_new", at: "2026-08-20T00:00:00Z")

      result = Prune.prune([{"h-0.jsonl", [oldest, middle, newest]}], keep_shas: 2)

      assert result.files == [{"h-0.jsonl", [middle, newest]}]
      assert result.pruned == 1
    end

    test "a SHA is ranked by its newest record across all files" do
      spread_early = test_line(sha: "sha_spread", at: "2026-08-01T00:00:00Z")
      spread_late = test_line(sha: "sha_spread", at: "2026-08-21T00:00:00Z")
      other = test_line(sha: "sha_other", at: "2026-08-10T00:00:00Z")

      result =
        Prune.prune(
          [{"h-0.jsonl", [spread_early, other]}, {"h-1.jsonl", [spread_late]}],
          keep_shas: 1
        )

      assert result.files == [{"h-0.jsonl", [spread_early]}, {"h-1.jsonl", [spread_late]}]
      assert result.pruned == 1
    end

    test "lines without a SHA are untouched by SHA retention" do
      null_sha = test_line(sha: nil, at: "2026-01-01T00:00:00Z")
      suite = suite_line("2026-01-01T00:00:00Z")
      kept = test_line(sha: "sha_new", at: "2026-08-20T00:00:00Z")
      dropped = test_line(sha: "sha_old", at: "2026-08-01T00:00:00Z")

      result = Prune.prune([{"h-0.jsonl", [null_sha, suite, kept, dropped]}], keep_shas: 1)

      assert result.files == [{"h-0.jsonl", [null_sha, suite, kept]}]
      assert result.pruned == 1
    end
  end

  test "both criteria compose: a line survives only by passing both" do
    old_kept_sha = test_line(sha: "sha_new", at: "2026-05-01T00:00:00Z")
    new_kept_sha = test_line(sha: "sha_new", at: "2026-08-20T00:00:00Z")
    new_dropped_sha = test_line(sha: "sha_old", at: "2026-08-19T00:00:00Z")

    result =
      Prune.prune(
        [{"h-0.jsonl", [old_kept_sha, new_kept_sha, new_dropped_sha]}],
        cutoff: "2026-08-01T00:00:00Z",
        keep_shas: 1
      )

    assert result.files == [{"h-0.jsonl", [new_kept_sha]}]
    assert result.pruned == 2
  end

  test "corrupt lines are dropped and counted; blank lines vanish silently" do
    kept = test_line()

    result =
      Prune.prune(
        [{"h-0.jsonl", ["not json", "", kept]}],
        cutoff: "2026-01-01T00:00:00Z"
      )

    assert result.files == [{"h-0.jsonl", [kept]}]
    assert result.corrupt == 1
    assert result.pruned == 0
  end
end
