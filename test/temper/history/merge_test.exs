defmodule Temper.History.MergeTest do
  use ExUnit.Case, async: true

  alias Temper.History.Codec
  alias Temper.History.Merge
  alias Temper.Record
  alias Temper.RunContext

  defp test_line(overrides \\ []) do
    context =
      RunContext.new(%{
        run_id: Keyword.get(overrides, :run_id, "9f1c2b3a4d5e6f708192a3b4c5d6e7f8"),
        at: "2026-08-24T12:00:00Z",
        sha: "abc1234",
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

  test "byte-identical lines collapse to the first occurrence, order preserved" do
    a = test_line(name: "test a")
    b = test_line(name: "test b")

    result = Merge.merge([a, b, a, b, a])

    assert result.lines == [a, b]
    assert result.duplicates == 3
    assert result.corrupt == 0
  end

  test "suite summary lines pass through verbatim" do
    context =
      RunContext.new(%{
        run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
        at: "2026-08-24T12:00:00Z",
        elixir: "1.20.2",
        otp: "27"
      })

    suite = Codec.encode_suite(context, %{tests: 12, times_us: nil})

    assert Merge.merge([suite]).lines == [suite]
  end

  test "future schema versions pass through verbatim — merge must not strip newer data" do
    future = ~s({"schema":2,"kind":"test","run_id":"r1","brand_new_field":true})

    result = Merge.merge([future, future])

    assert result.lines == [future]
    assert result.duplicates == 1
    assert result.corrupt == 0
  end

  test "corrupt lines are dropped and counted" do
    truncated_tail = ~s({"schema":1,"kind":"test","run_id":"9f1c2b)
    missing_keys = ~s({"schema":1,"kind":"test"})
    kept = test_line()

    result = Merge.merge([truncated_tail, kept, missing_keys])

    assert result.lines == [kept]
    assert result.corrupt == 2
    assert result.duplicates == 0
  end

  test "blank lines are ignored, counting as nothing" do
    kept = test_line()

    result = Merge.merge(["", kept, ""])

    assert result.lines == [kept]
    assert result.duplicates == 0
    assert result.corrupt == 0
  end
end
