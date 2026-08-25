defmodule Mix.Tasks.Temper.DoctorTest do
  # Mix.shell/1 is global state, and the task runs against the cwd.
  use ExUnit.Case, async: false

  alias Temper.History.Codec
  alias Temper.Record
  alias Temper.RunContext

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    previous = Application.get_env(:temper, :history_path)
    Application.delete_env(:temper, :history_path)

    on_exit(fn ->
      if previous, do: Application.put_env(:temper, :history_path, previous)
    end)

    dir = Path.join(System.tmp_dir!(), "temper_doctor_task_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp history_line do
    context =
      RunContext.new(%{
        run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
        at: "2026-08-24T12:00:00Z",
        sha: "abc1234",
        elixir: "1.20.2",
        otp: "27"
      })

    Codec.encode(%Record{context: context, module: "DemoTest", name: "test x", status: :passed})
  end

  defp run_doctor(dir, args \\ []) do
    File.cd!(dir, fn -> Mix.Task.rerun("temper.doctor", args) end)

    assert_received {:mix_shell, :info, [output]}
    output
  end

  test "a healthy setup passes every check and exits normally", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config
    import_config "\#{config_env()}.exs"
    """)

    File.write!(Path.join(dir, "config/test.exs"), """
    import Config
    config :ex_unit, formatters: [ExUnit.CLIFormatter, Temper.Formatter]
    """)

    File.mkdir_p!(Path.join(dir, ".temper"))
    File.write!(Path.join(dir, ".temper/history-0.jsonl"), history_line() <> "\n")

    output = run_doctor(dir)

    assert output =~ "✓ formatter registration"
    assert output =~ "✓ history_path"
    assert output =~ "✓ recorded history"
    assert output =~ "✓ recorded commit SHAs"
    assert output =~ "All 4 checks passed."
  end

  test "an empty project fails the preflight with exit status 1", %{dir: dir} do
    assert catch_exit(run_doctor(dir)) == {:shutdown, 1}

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "✗ formatter registration"
    assert output =~ "✗ recorded history"
    assert output =~ "problems."
  end

  test "--history inspects the given glob", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "elsewhere"))
    File.write!(Path.join(dir, "elsewhere/history-0.jsonl"), history_line() <> "\n")

    catch_exit(run_doctor(dir, ["--history", "elsewhere/history-{partition}.jsonl"]))

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "✓ recorded history"
    assert output =~ "1 test records in 1 files"
  end
end
