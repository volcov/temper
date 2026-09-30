defmodule Temper.Push.AcknowledgementsTest do
  use ExUnit.Case, async: true

  alias Temper.Push.Acknowledgements

  @moduletag :tmp_dir

  defmodule NoKeyAdapter do
    @behaviour Temper.Push.Adapter
    @impl true
    def push(batch, _config), do: {:ok, batch.run_ids, %{}}
  end

  test "file_name/2 follows the whole config of an adapter without a key" do
    name = Acknowledgements.file_name(NoKeyAdapter, bucket: "a", region: "eu")

    assert name =~ ~r/\Apushed-runs-[0-9a-f]{8}\z/
    assert name == Acknowledgements.file_name(NoKeyAdapter, region: "eu", bucket: "a")

    assert name ==
             Acknowledgements.file_name(NoKeyAdapter,
               bucket: "a",
               region: "eu",
               max_batch_bytes: 1
             )

    refute name == Acknowledgements.file_name(NoKeyAdapter, bucket: "b", region: "eu")
  end

  test "merge/3 adds new ids once and keeps only runs still in the history" do
    history = MapSet.new(["b", "c", "d"])

    assert Acknowledgements.merge(["a", "b"], ["c", "c", "d"], history) == ["b", "c", "d"]
    assert Acknowledgements.merge([], [], history) == []
    # Without a complete history, nothing is pruned.
    assert Acknowledgements.merge(["a", "b"], ["c"], nil) == ["a", "b", "c"]
  end

  test "a missing file reads as nothing accepted", %{tmp_dir: dir} do
    assert Acknowledgements.read(Path.join(dir, "pushed-runs-x")) == MapSet.new()
  end

  test "record/3 writes and extends the file, one id per line", %{tmp_dir: dir} do
    path = Path.join([dir, ".temper", "pushed-runs-x"])
    history = MapSet.new(["a", "b", "c"])

    assert :ok = Acknowledgements.record(path, ["a", "b"], history)
    assert :ok = Acknowledgements.record(path, ["b", "c"], history)

    assert File.read!(path) == "a\nb\nc\n"
    assert Acknowledgements.read(path) == history
    assert File.ls!(Path.dirname(path)) == ["pushed-runs-x"]
  end

  test "ids of runs pruned from the history are dropped", %{tmp_dir: dir} do
    path = Path.join(dir, "pushed-runs-x")
    File.write!(path, "old\nkept\n")

    assert :ok = Acknowledgements.record(path, ["new"], MapSet.new(["kept", "new"]))
    assert File.read!(path) == "kept\nnew\n"
  end

  test "a failed write leaves the file as it was and nothing beside it", %{tmp_dir: dir} do
    # A directory where the file should be: the rename fails.
    path = Path.join(dir, "pushed-runs-x")
    File.mkdir_p!(path)

    assert {:error, _reason} = Acknowledgements.record(path, ["a"], MapSet.new(["a"]))
    assert File.ls!(dir) == ["pushed-runs-x"]
  end

  test "blank lines and whitespace in the file are ignored", %{tmp_dir: dir} do
    path = Path.join(dir, "pushed-runs-x")
    File.write!(path, "a\n\n  b \n")

    assert Acknowledgements.read(path) == MapSet.new(["a", "b"])
  end
end
