defmodule Mix.Tasks.Temper.PushTest do
  # Mix.shell/1, the :temper application env and environment variables are
  # global state.
  use ExUnit.Case, async: false

  import Mox

  alias Temper.Push.Acknowledgements
  alias Temper.Push.AdapterMock
  alias Temper.Push.Destination
  alias Temper.Push.HTTPClientMock

  setup :verify_on_exit!

  # Mox defines the optional callback too; answer it like an adapter
  # without one (the whole config but the batch size).
  setup do
    stub(AdapterMock, :destination_key, fn config ->
      config |> Keyword.delete(:max_batch_bytes) |> Enum.sort()
    end)

    :ok
  end

  @run_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @run_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    for key <- [:history_path, :push] do
      previous = Application.fetch_env(:temper, key)
      Application.delete_env(:temper, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:temper, key, value)
          :error -> Application.delete_env(:temper, key)
        end
      end)
    end

    dir = Path.join(System.tmp_dir!(), "temper_push_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".temper"))
    on_exit(fn -> File.rm_rf!(dir) end)

    Application.put_env(
      :temper,
      :history_path,
      Path.join(dir, ".temper/history-{partition}.jsonl")
    )

    Application.put_env(:temper, :push, adapter: AdapterMock, bucket: "b")

    {:ok, dir: dir}
  end

  defp line(run_id, name, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "schema" => 1,
          "kind" => "test",
          "run_id" => run_id,
          "name" => name,
          "status" => "passed"
        },
        extra
      )
    )
  end

  defp write_history(dir, partition, lines) do
    File.write!(
      Path.join(dir, ".temper/history-#{partition}.jsonl"),
      Enum.map(lines, &[&1, "\n"])
    )
  end

  defp run_push(args \\ []), do: Mix.Task.rerun("temper.push", args)

  # Where the task keeps accepted runs for the configured destination
  # (and flags), as it resolves them.
  defp pushed_runs(ctx, flags \\ []) do
    {:ok, adapter, config} =
      Destination.resolve(Application.get_env(:temper, :push, []), flags)

    Path.join([ctx.dir, ".temper", Acknowledgements.file_name(adapter, config)])
  end

  defp sinter_pushed_runs(ctx), do: pushed_runs(ctx, preset: "sinter")

  defp messages do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:mix_shell, kind, [text]} -> receive_all([{kind, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "pushes the runs of every partition and records what was accepted", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    write_history(ctx.dir, 1, [line(@run_b, "t1")])

    expect(AdapterMock, :push, fn batch, config ->
      assert batch.run_ids == [@run_a, @run_b]
      assert config[:bucket] == "b"
      {:ok, batch.run_ids, %{"runs_new" => 2, "runs_known" => 0}}
    end)

    run_push()

    assert File.read!(pushed_runs(ctx)) == "#{@run_a}\n#{@run_b}\n"
    assert [{:info, "Pushed history: 2 runs accepted. 2 new."}] = messages()
  end

  test "the next push sends only new runs, and nothing when there are none", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    File.write!(pushed_runs(ctx), @run_a <> "\n")

    run_push()

    assert [{:info, "Nothing new to push: every run in 1 file was already accepted."}] =
             messages()

    write_history(ctx.dir, 0, [line(@run_a, "t1"), line(@run_b, "t1")])

    expect(AdapterMock, :push, fn %{run_ids: [@run_b]} = batch, _config ->
      {:ok, batch.run_ids, %{}}
    end)

    run_push()
    assert File.read!(pushed_runs(ctx)) == "#{@run_a}\n#{@run_b}\n"
  end

  test "--all sends acknowledged runs too", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    File.write!(pushed_runs(ctx), @run_a <> "\n")

    expect(AdapterMock, :push, fn %{run_ids: [@run_a]}, _config -> {:ok, [@run_a], %{}} end)

    run_push(["--all"])
    assert File.read!(pushed_runs(ctx)) == "#{@run_a}\n"
  end

  test "--scrub-messages removes failure messages before the adapter sees them", ctx do
    failure = %{"kind" => "RuntimeError", "message" => "secret", "hash" => "0498be8e"}
    write_history(ctx.dir, 0, [line(@run_a, "t1", %{"status" => "failed", "failure" => failure})])

    expect(AdapterMock, :push, fn batch, _config ->
      refute :zlib.gunzip(batch.body) =~ "secret"
      {:ok, batch.run_ids, %{}}
    end)

    run_push(["--scrub-messages"])
  end

  test "a failed push records nothing, warns, and exits 0", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])

    expect(AdapterMock, :push, fn _batch, _config ->
      {:error, "The upload was refused (429): slow down"}
    end)

    run_push()

    refute File.exists?(pushed_runs(ctx))

    assert [
             {:error, "The upload was refused (429): slow down"},
             {:error, "Not failing the build (pass --strict to)."}
           ] = messages()
  end

  test "--strict exits 1 on a failed push", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    expect(AdapterMock, :push, fn _batch, _config -> {:error, "nope"} end)

    assert catch_exit(run_push(["--strict"])) == {:shutdown, 1}
  end

  test "a failure midway keeps the batches already accepted", ctx do
    # A tiny batch size: one run per batch.
    Application.put_env(:temper, :push, adapter: AdapterMock, max_batch_bytes: 150)
    write_history(ctx.dir, 0, [line(@run_a, "t1"), line(@run_b, "t1")])

    AdapterMock
    |> expect(:push, fn %{run_ids: [@run_a]}, _config -> {:ok, [@run_a], %{}} end)
    |> expect(:push, fn %{run_ids: [@run_b]}, _config ->
      {:error, "The upload was refused (503): busy"}
    end)

    run_push()

    assert File.read!(pushed_runs(ctx)) == "#{@run_a}\n"

    assert [
             {:info, "Pushed history: 1 run accepted."},
             {:error, "The upload was refused (503): busy"},
             {:error, "Not failing the build (pass --strict to)."}
           ] = messages()
  end

  test "counters are added up across batches, unknown ones listed by name", ctx do
    Application.put_env(:temper, :push, adapter: AdapterMock, max_batch_bytes: 150)
    write_history(ctx.dir, 0, [line(@run_a, "t1"), line(@run_b, "t1")])

    expect(AdapterMock, :push, 2, fn batch, _config ->
      {:ok, batch.run_ids, %{"runs_new" => 1, "stored_kb" => 3}}
    end)

    run_push()

    assert [{:info, "Pushed history: 2 runs accepted. 2 new. stored_kb: 6."}] = messages()
  end

  test "an adapter that crashes is a failed push, not a failed build", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    expect(AdapterMock, :push, fn _batch, _config -> raise ArgumentError, "boom" end)

    run_push()

    assert [
             {:error, "The Temper.Push.AdapterMock push adapter failed: boom"},
             {:error, "Not failing the build (pass --strict to)."}
           ] = messages()

    refute File.exists?(pushed_runs(ctx))
  end

  test "an adapter whose destination key raises is a failed push, with nothing sent", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    stub(AdapterMock, :destination_key, fn _config -> raise "no key" end)

    run_push()

    assert [
             {:error,
              "The Temper.Push.AdapterMock push adapter failed to name its destination: no key"},
             {:error, "Not failing the build (pass --strict to)."}
           ] = messages()

    assert catch_exit(run_push(["--strict"])) == {:shutdown, 1}
  end

  test "an adapter that does not exist is a failed push too", ctx do
    Application.put_env(:temper, :push, adapter: Temper.Push.NoSuchAdapter)
    write_history(ctx.dir, 0, [line(@run_a, "t1")])

    run_push()

    assert [{:error, "The Temper.Push.NoSuchAdapter push adapter failed: " <> _}, _not_failing] =
             messages()
  end

  test "--history reads another place, and pushed-runs lives beside it", ctx do
    other = Path.join(ctx.dir, "elsewhere")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "h.jsonl"), line(@run_a, "t1") <> "\n")

    expect(AdapterMock, :push, fn batch, _config -> {:ok, batch.run_ids, %{}} end)

    run_push(["--history", Path.join(other, "*.jsonl")])

    assert File.read!(Path.join(other, Path.basename(pushed_runs(ctx)))) == @run_a <> "\n"

    refute File.exists?(pushed_runs(ctx))
  end

  test "another destination starts from nothing", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    File.write!(pushed_runs(ctx), @run_a <> "\n")

    Application.put_env(:temper, :push, adapter: AdapterMock, url: "https://elsewhere")
    expect(AdapterMock, :push, fn %{run_ids: [@run_a]}, _config -> {:ok, [@run_a], %{}} end)

    run_push()
  end

  test "a new bucket is a new destination, even with the same adapter", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    File.write!(pushed_runs(ctx), @run_a <> "\n")

    Application.put_env(:temper, :push, adapter: AdapterMock, bucket: "another")
    expect(AdapterMock, :push, fn %{run_ids: [@run_a]}, _config -> {:ok, [@run_a], %{}} end)

    run_push()
  end

  test "an unreadable partition keeps its accepted runs on record", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    unreadable = Path.join(ctx.dir, ".temper/history-1.jsonl")
    File.write!(unreadable, line(@run_b, "t1"))
    File.write!(pushed_runs(ctx), @run_b <> "\n")
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o644) end)

    expect(AdapterMock, :push, fn %{run_ids: [@run_a]}, _config -> {:ok, [@run_a], %{}} end)

    run_push()

    # The run of the partition that could not be read stays acknowledged.
    assert File.read!(pushed_runs(ctx)) == "#{@run_b}\n#{@run_a}\n"
  end

  test "--dry-run --strict fails on what could not be sent", ctx do
    Application.put_env(:temper, :push, adapter: AdapterMock, max_batch_bytes: 200)
    write_history(ctx.dir, 0, [line(@run_a, String.duplicate("x", 500)), line(@run_b, "t1")])

    assert catch_exit(run_push(["--dry-run", "--strict"])) == {:shutdown, 1}

    assert [{:info, "Would push 1 run " <> _}, {:error, "1 run larger than the 200 B" <> _}] =
             messages()
  end

  test "an unreadable history file is a failed push; the rest still goes", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1")])
    unreadable = Path.join(ctx.dir, ".temper/history-2.jsonl")
    File.write!(unreadable, line(@run_b, "t1"))
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o644) end)

    expect(AdapterMock, :push, fn %{run_ids: [@run_a]}, _config -> {:ok, [@run_a], %{}} end)

    assert catch_exit(run_push(["--strict"])) == {:shutdown, 1}

    assert [
             {:info, "Pushed history: 1 run accepted."},
             {:error, "Could not read 1 history file: " <> _}
           ] = messages()
  end

  test "when no history file can be read, the push fails instead of finding nothing", ctx do
    unreadable = Path.join(ctx.dir, ".temper/history-0.jsonl")
    File.write!(unreadable, line(@run_a, "t1"))
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o644) end)

    assert catch_exit(run_push(["--strict"])) == {:shutdown, 1}
    assert [{:error, "Could not read 1 history file: " <> _}] = messages()
  end

  test "a run over the batch limit is not sent and fails the push; the others go", ctx do
    Application.put_env(:temper, :push, adapter: AdapterMock, max_batch_bytes: 200)
    write_history(ctx.dir, 0, [line(@run_a, String.duplicate("x", 500)), line(@run_b, "t1")])

    expect(AdapterMock, :push, fn %{run_ids: [@run_b]}, _config -> {:ok, [@run_b], %{}} end)

    run_push()

    assert File.read!(pushed_runs(ctx)) == @run_b <> "\n"

    assert [
             {:info, "Pushed history: 1 run accepted."},
             {:error, "1 run larger than the 200 B batch limit not sent (" <> _},
             {:error, "Not failing the build (pass --strict to)."}
           ] = messages()
  end

  test "a history with nothing usable says so", ctx do
    write_history(ctx.dir, 0, ["{corrupt", "[1]"])

    run_push()

    assert [
             {:info,
              "Nothing to push: no usable history lines in 1 file. 2 corrupt lines left out."}
           ] = messages()
  end

  test "--dry-run sends nothing and says what would go", ctx do
    write_history(ctx.dir, 0, [line(@run_a, "t1"), "{corrupt"])

    run_push(["--dry-run"])

    assert [{:info, message}] = messages()
    assert message =~ ~r/\AWould push 1 run \(1 line, \d+ B compressed, 1 batch\) /
    assert message =~ "to Temper.Push.AdapterMock. Nothing was sent. 1 corrupt lines left out."
    refute File.exists?(pushed_runs(ctx))
  end

  test "nothing configured pushes nothing, and --strict exits 1", ctx do
    Application.delete_env(:temper, :push)
    write_history(ctx.dir, 0, [line(@run_a, "t1")])

    run_push()
    assert [{:error, "No push destination configured." <> _}, _not_failing] = messages()

    assert catch_exit(run_push(["--strict"])) == {:shutdown, 1}
  end

  test "no history files, nothing to push", ctx do
    File.rm_rf!(Path.join(ctx.dir, ".temper"))

    run_push()
    assert [{:info, "No history files matching " <> _}] = messages()
  end

  describe "the sinter preset, end to end over HTTP" do
    setup do
      previous = System.get_env("SINTER_TOKEN")
      System.put_env("SINTER_TOKEN", "sntr_secret")

      on_exit(fn ->
        if previous,
          do: System.put_env("SINTER_TOKEN", previous),
          else: System.delete_env("SINTER_TOKEN")
      end)

      Application.delete_env(:temper, :push)
      :ok
    end

    test "--preset wins over an adapter in the config", ctx do
      Application.put_env(:temper, :push, adapter: AdapterMock, token_env: "OTHER")
      write_history(ctx.dir, 0, [line(@run_a, "t1")])

      expect(HTTPClientMock, :post, fn "https://sinterlab.dev/api/v1/ingest", headers, _body ->
        assert {"authorization", "Bearer sntr_secret"} in headers
        {:ok, 200, ~s({"accepted_run_ids":["#{@run_a}"]})}
      end)

      run_push(["--preset", "sinter"])
      assert File.read!(sinter_pushed_runs(ctx)) == @run_a <> "\n"
    end

    test "posts to sinterlab.dev with the token, and never prints it", ctx do
      write_history(ctx.dir, 0, [line(@run_a, "t1")])

      expect(HTTPClientMock, :post, fn url, headers, body ->
        assert url == "https://sinterlab.dev/api/v1/ingest"
        assert {"authorization", "Bearer sntr_secret"} in headers
        assert :zlib.gunzip(body) == line(@run_a, "t1") <> "\n"

        {:ok, 200,
         Jason.encode!(%{
           accepted_run_ids: [@run_a],
           runs_new: 1,
           runs_known: 0,
           runs_without_sha: 1,
           lines_skipped: 0,
           failures_truncated: 0
         })}
      end)

      run_push(["--preset", "sinter"])

      assert [{:info, summary}] = messages()
      pushed_runs = sinter_pushed_runs(ctx)

      assert summary ==
               "Pushed history: 1 run accepted. 1 new. " <>
                 "1 without a clean commit (not used for flake detection)."

      refute summary =~ "sntr_secret"
      assert File.read!(pushed_runs) == @run_a <> "\n"
    end

    test "--url points the preset elsewhere", ctx do
      write_history(ctx.dir, 0, [line(@run_a, "t1")])

      expect(HTTPClientMock, :post, fn "http://localhost:4000/api/v1/ingest", _headers, _body ->
        {:ok, 200, ~s({"accepted_run_ids":[]})}
      end)

      run_push(["--preset", "sinter", "--url", "http://localhost:4000/api/v1/ingest"])
    end

    test "a missing token is a failed push, with nothing sent", ctx do
      System.delete_env("SINTER_TOKEN")
      write_history(ctx.dir, 0, [line(@run_a, "t1")])

      run_push(["--preset", "sinter"])

      assert [{:error, "SINTER_TOKEN is not set, so nothing was pushed."}, _not_failing] =
               messages()
    end
  end
end
