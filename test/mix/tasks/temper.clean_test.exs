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

  test "a {partition} placeholder deletes every partition's file", %{dir: dir} do
    for partition <- 0..2 do
      File.write!(Path.join(dir, "history-#{partition}.jsonl"), "{}\n")
    end

    output = run_clean(["--history", Path.join(dir, "history-{partition}.jsonl")])

    assert output == "Deleted 3 history files."
    assert File.ls!(dir) == []
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

  describe "pruning" do
    alias Temper.History.Codec
    alias Temper.Record
    alias Temper.RunContext

    defp line(overrides) do
      context =
        RunContext.new(%{
          run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
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

    defp days_ago(days) do
      DateTime.utc_now()
      |> DateTime.add(-days * 86_400, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
    end

    test "--older-than rewrites files in place, dropping old lines", %{dir: dir} do
      old = line(at: days_ago(120), name: "test old")
      recent = line(at: days_ago(5), name: "test recent")

      path = Path.join(dir, "history-0.jsonl")
      File.write!(path, old <> "\n" <> recent <> "\n")

      output = run_clean(["--history", path, "--older-than", "90"])

      assert output == "Pruned 1 of 2 lines across 1 files."
      assert File.read!(path) == recent <> "\n"
    end

    test "--keep-shas ranks SHAs across every partition's file", %{dir: dir} do
      current = line(sha: "sha_new", at: days_ago(1), name: "test new")
      stale = line(sha: "sha_old", at: days_ago(30), name: "test stale")

      File.write!(Path.join(dir, "history-0.jsonl"), current <> "\n")
      File.write!(Path.join(dir, "history-1.jsonl"), stale <> "\n")

      output =
        run_clean([
          "--history",
          Path.join(dir, "history-{partition}.jsonl"),
          "--keep-shas",
          "1"
        ])

      assert output == "Pruned 1 of 2 lines across 2 files. Removed 1 emptied files."
      assert File.read!(Path.join(dir, "history-0.jsonl")) == current <> "\n"
      refute File.exists?(Path.join(dir, "history-1.jsonl"))
    end

    test "corrupt lines are dropped from rewritten files and reported", %{dir: dir} do
      recent = line(at: days_ago(5), name: "test recent")

      path = Path.join(dir, "history-0.jsonl")
      File.write!(path, ~s({"schema":1,"kind) <> "\n" <> recent <> "\n")

      output = run_clean(["--history", path, "--older-than", "90"])

      assert output == "Pruned 0 of 2 lines across 1 files. 1 corrupt lines dropped."
      assert File.read!(path) == recent <> "\n"
    end

    test "a file that cannot be rewritten keeps its old content and is reported", %{dir: dir} do
      old = line(at: days_ago(120), name: "test old")
      recent = line(at: days_ago(5), name: "test recent")

      path = Path.join(dir, "history-0.jsonl")
      File.write!(path, old <> "\n" <> recent <> "\n")

      File.chmod!(dir, 0o555)
      on_exit(fn -> File.chmod(dir, 0o755) end)

      output = run_clean(["--history", path, "--older-than", "90"])

      assert output =~ "1 files kept their old content."
      assert_received {:mix_shell, :error, [error]}
      assert error == "Could not rewrite #{path}."
      assert File.read!(path) == old <> "\n" <> recent <> "\n"
    end

    test "a non-positive --older-than aborts", %{dir: dir} do
      assert_raise Mix.Error, ~r/positive/, fn ->
        Mix.Task.rerun("temper.clean", [
          "--history",
          Path.join(dir, "history-*.jsonl"),
          "--older-than",
          "0"
        ])
      end
    end

    test "a non-positive --keep-shas aborts", %{dir: dir} do
      assert_raise Mix.Error, ~r/positive/, fn ->
        Mix.Task.rerun("temper.clean", [
          "--history",
          Path.join(dir, "history-*.jsonl"),
          "--keep-shas",
          "-1"
        ])
      end
    end
  end
end
