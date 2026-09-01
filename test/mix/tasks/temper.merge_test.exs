defmodule Mix.Tasks.Temper.MergeTest do
  # Mix.shell/1 and the :temper application env are global state.
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

    dir =
      Path.join(System.tmp_dir!(), "temper_merge_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp line(name) do
    context =
      RunContext.new(%{
        run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
        at: "2026-08-24T12:00:00Z",
        sha: "abc1234",
        elixir: "1.20.2",
        otp: "27"
      })

    Codec.encode(%Record{context: context, module: "DemoTest", name: name, status: :passed})
  end

  defp run_merge(args) do
    Mix.Task.rerun("temper.merge", args)

    assert_received {:mix_shell, :info, [output]}
    output
  end

  test "merges files from several globs into one deduped output", %{dir: dir} do
    shared = line("test shared")
    only_a = line("test a")
    only_b = line("test b")

    File.mkdir_p!(Path.join(dir, "job_a"))
    File.mkdir_p!(Path.join(dir, "job_b"))
    File.write!(Path.join(dir, "job_a/history-0.jsonl"), shared <> "\n" <> only_a <> "\n")
    File.write!(Path.join(dir, "job_b/history-0.jsonl"), shared <> "\n" <> only_b <> "\n")

    output_path = Path.join(dir, "merged.jsonl")

    output =
      run_merge([
        "--output",
        output_path,
        Path.join(dir, "job_a/history-*.jsonl"),
        Path.join(dir, "job_b/history-*.jsonl")
      ])

    assert File.read!(output_path) == shared <> "\n" <> only_a <> "\n" <> only_b <> "\n"
    assert output == "Merged 3 lines from 2 files into #{output_path}. 1 duplicate lines dropped."
  end

  test "the output file may itself be one of the inputs", %{dir: dir} do
    existing = line("test existing")
    fresh = line("test fresh")

    target = Path.join(dir, "history-0.jsonl")
    File.write!(target, existing <> "\n")
    File.write!(Path.join(dir, "history-1.jsonl"), fresh <> "\n" <> existing <> "\n")

    run_merge(["--output", target, Path.join(dir, "history-*.jsonl")])

    assert File.read!(target) == existing <> "\n" <> fresh <> "\n"
  end

  test "inputs default to the configured history path, {partition} widened", %{dir: dir} do
    Application.put_env(:temper, :history_path, Path.join(dir, "history-{partition}.jsonl"))

    File.write!(Path.join(dir, "history-0.jsonl"), line("test p0") <> "\n")
    File.write!(Path.join(dir, "history-1.jsonl"), line("test p1") <> "\n")

    output_path = Path.join(dir, "merged.jsonl")
    output = run_merge(["--output", output_path])

    assert output =~ "Merged 2 lines from 2 files"
    assert File.read!(output_path) == line("test p0") <> "\n" <> line("test p1") <> "\n"
  end

  test "corrupt lines are skipped and reported; unrecognized lines survive", %{dir: dir} do
    future = ~s({"schema":2,"kind":"test","run_id":"r1"})

    File.write!(
      Path.join(dir, "history-0.jsonl"),
      line("test x") <> "\n" <> ~s({"schema":1,"kind) <> "\n" <> future <> "\n"
    )

    output_path = Path.join(dir, "merged.jsonl")
    output = run_merge(["--output", output_path, Path.join(dir, "history-*.jsonl")])

    assert output ==
             "Merged 2 lines from 1 files into #{output_path}. 1 corrupt lines skipped."

    assert File.read!(output_path) == line("test x") <> "\n" <> future <> "\n"
  end

  test "no matching files reports and creates nothing", %{dir: dir} do
    output_path = Path.join(dir, "merged.jsonl")
    output = run_merge(["--output", output_path, Path.join(dir, "nope-*.jsonl")])

    assert output =~ "No history files matching"
    refute File.exists?(output_path)
  end

  test "directories caught by a glob are skipped with an error", %{dir: dir} do
    File.write!(Path.join(dir, "history-0.jsonl"), line("test x") <> "\n")
    trap = Path.join(dir, "history-1.jsonl")
    File.mkdir_p!(trap)

    output =
      run_merge(["--output", Path.join(dir, "merged.jsonl"), Path.join(dir, "history-*.jsonl")])

    assert output =~ "Merged 1 lines from 1 files"
    assert_received {:mix_shell, :error, [error]}
    assert error == "Skipping #{trap}: not a regular file."
  end

  test "a missing --output aborts with usage guidance", %{dir: dir} do
    assert_raise Mix.Error, ~r/--output/, fn ->
      Mix.Task.rerun("temper.merge", [Path.join(dir, "history-*.jsonl")])
    end
  end

  test "a {partition} template as --output aborts", %{dir: dir} do
    assert_raise Mix.Error, ~r/concrete/, fn ->
      Mix.Task.rerun("temper.merge", [
        "--output",
        Path.join(dir, "history-{partition}.jsonl"),
        Path.join(dir, "history-*.jsonl")
      ])
    end
  end
end
