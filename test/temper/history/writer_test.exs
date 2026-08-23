defmodule Temper.History.WriterTest do
  use ExUnit.Case, async: true

  alias Temper.History.Codec
  alias Temper.History.Writer
  alias Temper.Record
  alias Temper.RunContext

  @context RunContext.new(%{
             run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
             at: "2026-08-21T14:03:22Z",
             sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
             elixir: "1.20.2",
             otp: "27"
           })

  @record %Record{
    context: @context,
    module: "MyApp.UserTest",
    name: "test creates user with valid attrs",
    status: :passed,
    time_us: 1_234
  }

  describe "default_path/1" do
    test "uses the partition in the file name" do
      assert Writer.default_path("2") == ".temper/history-2.jsonl"
    end

    test "maps a nil partition to 0" do
      assert Writer.default_path(nil) == ".temper/history-0.jsonl"
    end
  end

  describe "open/1, append/2 and close/1" do
    @tag :tmp_dir
    test "creates missing parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "deeper", "history-0.jsonl"])

      assert {:ok, writer} = Writer.open(path)
      assert :ok = Writer.close(writer)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "written records decode back from the file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "history-0.jsonl")

      {:ok, writer} = Writer.open(path)
      assert :ok = Writer.append(writer, @record)
      assert :ok = Writer.append(writer, %Record{@record | name: "test another", status: :failed})
      assert :ok = Writer.close(writer)

      assert [line_one, line_two] = path |> File.read!() |> String.split("\n", trim: true)
      assert {:ok, %Record{name: "test creates user with valid attrs"}} = Codec.decode(line_one)
      assert {:ok, %Record{name: "test another", status: :failed}} = Codec.decode(line_two)
    end

    @tag :tmp_dir
    test "appends to an existing file instead of truncating", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "history-0.jsonl")

      {:ok, first} = Writer.open(path)
      :ok = Writer.append(first, @record)
      :ok = Writer.close(first)

      {:ok, second} = Writer.open(path)
      :ok = Writer.append(second, @record)
      :ok = Writer.close(second)

      assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 2
    end

    test "returns a posix error for an unwritable path" do
      assert {:error, reason} = Writer.open("/dev/null/not/a/directory/history.jsonl")
      assert is_atom(reason)
    end
  end

  describe "append_suite/3" do
    @tag :tmp_dir
    test "writes a suite summary line that decode/1 skips as non-test", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "history-0.jsonl")

      {:ok, writer} = Writer.open(path)
      :ok = Writer.append(writer, @record)

      :ok =
        Writer.append_suite(writer, @context, %{
          tests: 1,
          times_us: %{run: 250_000, async: 100_000, load: nil}
        })

      :ok = Writer.close(writer)

      assert [_test_line, suite_line] = path |> File.read!() |> String.split("\n", trim: true)
      assert Codec.decode(suite_line) == {:error, {:unsupported_kind, "suite"}}

      decoded = Jason.decode!(suite_line)
      assert decoded["schema"] == 1
      assert decoded["run_id"] == @context.run_id
      assert decoded["tests"] == 1
      assert decoded["times_us"] == %{"run" => 250_000, "async" => 100_000, "load" => nil}
    end
  end
end
