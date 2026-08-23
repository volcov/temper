defmodule Mix.Tasks.Temper.CleanTest do
  # Mix.shell/1 is global state.
  use ExUnit.Case, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    dir =
      Path.join(System.tmp_dir!(), "temper_clean_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp run_clean(args) do
    Mix.Task.rerun("temper.clean", args)

    assert_received {:mix_shell, :info, [output]}
    output
  end

  test "deletes every matching history file and nothing else", %{dir: dir} do
    for partition <- 0..2 do
      File.write!(Path.join(dir, "history-#{partition}.jsonl"), "{}\n")
    end

    unrelated = Path.join(dir, "keep-me.txt")
    File.write!(unrelated, "kept")

    output = run_clean(["--history", Path.join(dir, "history-*.jsonl")])

    assert output == "Deleted 3 history files."
    assert File.ls!(dir) == ["keep-me.txt"]
    assert File.read!(unrelated) == "kept"
  end

  test "skips directories caught by the glob instead of aborting", %{dir: dir} do
    File.write!(Path.join(dir, "history-0.jsonl"), "{}\n")
    trap = Path.join(dir, "history-1.jsonl")
    File.mkdir_p!(trap)

    output = run_clean(["--history", Path.join(dir, "history-*.jsonl")])

    assert output == "Deleted 1 history files."
    assert_received {:mix_shell, :error, [error]}
    assert error == "Skipping #{trap}: not a regular file."
    assert File.dir?(trap)
    refute File.exists?(Path.join(dir, "history-0.jsonl"))
  end

  test "says so when there is nothing to delete", %{dir: dir} do
    glob = Path.join(dir, "history-*.jsonl")

    output = run_clean(["--history", glob])

    assert output == "No history files matching #{glob}."
  end
end
