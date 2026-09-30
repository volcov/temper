defmodule Temper.Push.AcknowledgementsTest do
  use ExUnit.Case, async: true

  alias Temper.Push.Acknowledgements

  @moduletag :tmp_dir

  test "merge/3 appends new ids once and keeps the newest" do
    assert Acknowledgements.merge(["a", "b"], ["b", "c", "c"]) == ["a", "b", "c"]
    assert Acknowledgements.merge(["a", "b", "c"], ["d"], 3) == ["b", "c", "d"]
    assert Acknowledgements.merge([], []) == []
  end

  test "a missing file reads as nothing acknowledged", %{tmp_dir: dir} do
    assert Acknowledgements.read(Acknowledgements.path(dir)) == MapSet.new()
  end

  test "record/2 writes and extends the file, one id per line", %{tmp_dir: dir} do
    path = Acknowledgements.path(Path.join(dir, ".temper"))

    assert :ok = Acknowledgements.record(path, ["a", "b"])
    assert :ok = Acknowledgements.record(path, ["b", "c"])

    assert File.read!(path) == "a\nb\nc\n"
    assert Acknowledgements.read(path) == MapSet.new(["a", "b", "c"])
    refute File.exists?(path <> ".tmp")
  end

  test "a failed write leaves the file as it was and nothing beside it", %{tmp_dir: dir} do
    # A directory where the file should be: the rename fails.
    path = Acknowledgements.path(dir)
    File.mkdir_p!(path)

    assert {:error, _reason} = Acknowledgements.record(path, ["a"])
    assert File.ls!(dir) == ["pushed-runs"]
  end

  test "blank lines and whitespace in the file are ignored", %{tmp_dir: dir} do
    path = Acknowledgements.path(dir)
    File.write!(path, "a\n\n  b \n")

    assert Acknowledgements.read(path) == MapSet.new(["a", "b"])
  end
end
