defmodule Temper.RecordTest do
  use ExUnit.Case, async: true

  alias Temper.Record
  alias Temper.RunContext

  @context RunContext.new(%{
             run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
             at: "2026-08-21T14:03:22Z",
             elixir: "1.20.2",
             otp: "27"
           })

  defp build_test(overrides \\ []) do
    defaults = [
      name: :"test creates user with valid attrs",
      module: MyApp.UserTest,
      state: nil,
      time: 18_342,
      tags: %{
        file: "/home/me/my_app/test/my_app/user_test.exs",
        line: 42,
        async: true,
        test_type: :test
      }
    ]

    struct!(ExUnit.Test, Keyword.merge(defaults, overrides))
  end

  describe "from_test/2 identity and tags" do
    test "maps module, name, file, line, async and test_type" do
      record = Record.from_test(build_test(), @context)

      assert record.module == "MyApp.UserTest"
      assert record.name == "test creates user with valid attrs"
      assert record.file == "/home/me/my_app/test/my_app/user_test.exs"
      assert record.line == 42
      assert record.async == true
      assert record.test_type == "test"
      assert record.time_us == 18_342
      assert record.context == @context
    end

    test "tolerates missing tags" do
      record = Record.from_test(build_test(tags: %{}), @context)

      assert record.file == nil
      assert record.line == nil
      assert record.async == nil
      assert record.test_type == nil
    end
  end

  describe "from_test/2 status mapping" do
    test "nil state means passed, without a failure" do
      record = Record.from_test(build_test(state: nil), @context)

      assert record.status == :passed
      assert record.failure == nil
    end

    for {state, status} <- [
          {{:skipped, "not today"}, :skipped},
          {{:excluded, "tagged out"}, :excluded},
          {{:invalid, MyApp.UserTest}, :invalid}
        ] do
      test "#{inspect(elem(state, 0))} state maps to #{inspect(status)} without a failure" do
        record = Record.from_test(build_test(state: unquote(Macro.escape(state))), @context)

        assert record.status == unquote(status)
        assert record.failure == nil
      end
    end
  end

  describe "from_test/2 failure signatures" do
    test "an exception failure keeps its module, message and hash" do
      error = %RuntimeError{message: "boom"}
      test_struct = build_test(state: {:failed, [{:error, error, []}]})

      record = Record.from_test(test_struct, @context)

      assert record.status == :failed
      assert record.failure.kind == "RuntimeError"
      assert record.failure.message == "boom"
      assert record.failure.hash =~ ~r/^[0-9a-f]{8}$/
    end

    test "an assertion failure uses ExUnit.AssertionError" do
      error = ExUnit.AssertionError.exception(message: "Assertion with == failed")
      test_struct = build_test(state: {:failed, [{:error, error, []}]})

      record = Record.from_test(test_struct, @context)

      assert record.failure.kind == "ExUnit.AssertionError"
      assert record.failure.message =~ "Assertion with == failed"
    end

    for kind <- [:exit, :throw] do
      test "a #{kind} failure keeps the kind and inspects the reason" do
        test_struct = build_test(state: {:failed, [{unquote(kind), :boom, []}]})

        record = Record.from_test(test_struct, @context)

        assert record.failure.kind == unquote(to_string(kind))
        assert record.failure.message == ":boom"
      end
    end

    test "only the first of multiple failures is kept" do
      failures = [
        {:error, %RuntimeError{message: "first"}, []},
        {:error, %RuntimeError{message: "second"}, []}
      ]

      record = Record.from_test(build_test(state: {:failed, failures}), @context)

      assert record.failure.message == "first"
    end

    test "an empty failure list yields no signature" do
      record = Record.from_test(build_test(state: {:failed, []}), @context)

      assert record.status == :failed
      assert record.failure == nil
    end

    test "long messages are truncated but hashed in full" do
      long = String.duplicate("a", 600)
      short_record = failed_record(String.duplicate("a", 600))
      other_record = failed_record(String.duplicate("a", 601))

      assert String.length(short_record.failure.message) == 500
      assert short_record.failure.hash != other_record.failure.hash
      assert short_record.failure.hash == failed_record(long).failure.hash
    end

    test "equal messages hash equally, different ones differently" do
      assert failed_record("same").failure.hash == failed_record("same").failure.hash
      refute failed_record("same").failure.hash == failed_record("other").failure.hash
    end
  end

  defp failed_record(message) do
    error = %RuntimeError{message: message}
    Record.from_test(build_test(state: {:failed, [{:error, error, []}]}), @context)
  end
end
