defmodule Temper.FormatterTest do
  # These tests mutate the :temper application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Temper.Formatter
  alias Temper.History.Codec

  setup do
    history_path =
      Path.join(
        System.tmp_dir!(),
        "temper_formatter_test_#{System.unique_integer([:positive])}/history.jsonl"
      )

    Application.put_env(:temper, :history_path, history_path)

    on_exit(fn ->
      Application.delete_env(:temper, :history_path)
      File.rm_rf!(Path.dirname(history_path))
    end)

    {:ok, history_path: history_path}
  end

  defp build_test(overrides \\ []) do
    defaults = [
      name: :"test records outcomes",
      module: MyApp.SampleTest,
      state: nil,
      time: 1_000,
      tags: %{file: "test/sample_test.exs", line: 1, async: true, test_type: :test}
    ]

    struct!(ExUnit.Test, Keyword.merge(defaults, overrides))
  end

  defp run_events(state, events) do
    Enum.reduce(events, state, fn event, state ->
      {:noreply, state} = Formatter.handle_cast(event, state)
      state
    end)
  end

  defp decoded_lines(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Codec.decode/1)
  end

  # A fake io device: accepts writes, but reports :enospc on close —
  # the shape of a full disk surfacing only at the final flush.
  defp close_error_device do
    spawn(fn -> close_error_device_loop() end)
  end

  defp close_error_device_loop do
    receive do
      {:io_request, from, reply_as, {:put_chars, _encoding, _chars}} ->
        send(from, {:io_reply, reply_as, :ok})
        close_error_device_loop()

      {:file_request, from, reply_as, :close} ->
        send(from, {:file_reply, reply_as, {:error, :enospc}})
    end
  end

  describe "a full suite run" do
    test "records each test and a suite summary line", %{history_path: history_path} do
      {:ok, state} = Formatter.init(seed: 494_000)

      run_events(state, [
        {:suite_started, []},
        {:test_finished, build_test()},
        {:test_finished, build_test(name: :"test another", state: {:skipped, "later"})},
        {:suite_finished, %{run: 250_000, async: 100_000, load: nil}}
      ])

      assert [line_one, line_two, suite_line] =
               history_path |> File.read!() |> String.split("\n", trim: true)

      assert {:ok, record} = Codec.decode(line_one)
      assert record.module == "MyApp.SampleTest"
      assert record.status == :passed
      assert record.context.seed == 494_000
      assert record.context.run_id =~ ~r/^[0-9a-f]{32}$/

      assert {:ok, %{status: :skipped}} = Codec.decode(line_two)

      assert Codec.decode(suite_line) == {:error, {:unsupported_kind, "suite"}}
      assert Jason.decode!(suite_line)["tests"] == 2
    end

    test "ignores unrelated and deprecated events", %{history_path: history_path} do
      {:ok, state} = Formatter.init(seed: 1)

      run_events(state, [
        {:suite_started, []},
        {:test_started, build_test()},
        {:case_started, nil},
        {:module_started, nil},
        {:test_finished, build_test()},
        {:case_finished, nil},
        {:module_finished, nil},
        {:suite_finished, %{run: 1, async: nil, load: nil}}
      ])

      assert length(decoded_lines(history_path)) == 2
    end

    test "sigquit flushes and a later suite_finished adds nothing", %{
      history_path: history_path
    } do
      {:ok, state} = Formatter.init(seed: 1)

      state =
        run_events(state, [
          {:suite_started, []},
          {:test_finished, build_test()},
          {:sigquit, []}
        ])

      assert length(decoded_lines(history_path)) == 2

      run_events(state, [{:suite_finished, %{run: 1, async: nil, load: nil}}])

      assert length(decoded_lines(history_path)) == 2
    end

    test "max_failures_reached closes the history early", %{history_path: history_path} do
      {:ok, state} = Formatter.init(seed: 1)

      run_events(state, [
        {:suite_started, []},
        {:test_finished, build_test(state: {:failed, [{:error, %RuntimeError{}, []}]})},
        :max_failures_reached
      ])

      assert [{:ok, %{status: :failed}}, {:error, {:unsupported_kind, "suite"}}] =
               decoded_lines(history_path)
    end
  end

  describe "crash safety (D4)" do
    test "an unwritable history path warns once and the run continues" do
      Application.put_env(:temper, :history_path, "/dev/null/not/a/dir/history.jsonl")

      {:ok, state} = Formatter.init(seed: 1)

      {state, output} =
        with_io(:stderr, fn ->
          run_events(state, [{:suite_started, []}])
        end)

      assert output =~ "Temper disabled for this run"
      assert state.inert

      # Later events neither crash nor warn again.
      output =
        capture_io(:stderr, fn ->
          run_events(state, [
            {:test_finished, build_test()},
            {:suite_finished, %{run: 1, async: nil, load: nil}}
          ])
        end)

      assert output == ""
    end

    test "a close error at suite end warns instead of losing history silently" do
      {:ok, state} = Formatter.init(seed: 1)
      state = run_events(state, [{:suite_started, []}])

      # Swap in a device that accepts writes but fails the closing flush.
      broken_writer = %Temper.History.Writer{device: close_error_device(), path: "fake.jsonl"}
      state = %{state | writer: broken_writer}

      {state, output} =
        with_io(:stderr, fn ->
          run_events(state, [{:suite_finished, %{run: 1, async: nil, load: nil}}])
        end)

      assert output =~ "Temper disabled for this run"
      assert output =~ "could not close history file"
      assert state.inert
    end

    test "an exception inside a handler makes the formatter inert, not dead", %{
      history_path: history_path
    } do
      {:ok, state} = Formatter.init(seed: 1)
      state = run_events(state, [{:suite_started, []}])

      # A malformed event payload that reaches a handler must be
      # swallowed by the guard, not crash the suite. A tuple name has
      # no String.Chars implementation, so recording it raises.
      {state, output} =
        with_io(:stderr, fn ->
          run_events(state, [
            {:test_finished, %ExUnit.Test{name: {:bad, :name}, module: nil, tags: %{}}}
          ])
        end)

      assert output =~ "Temper disabled for this run"
      assert state.inert

      output = capture_io(:stderr, fn -> run_events(state, [{:test_finished, build_test()}]) end)
      assert output == ""

      # Only the (empty) history remains; nothing was recorded after the crash.
      assert history_path |> File.read!() |> String.split("\n", trim: true) == []
    end
  end
end
