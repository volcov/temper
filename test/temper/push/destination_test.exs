defmodule Temper.Push.DestinationTest do
  use ExUnit.Case, async: true

  alias Temper.Push.Adapters.HTTP
  alias Temper.Push.Destination

  test "nothing configured is no destination" do
    assert {:error, "No push destination configured." <> _} = Destination.resolve([], [])
  end

  test "the sinter preset, from config or flag" do
    for {config, flags} <- [{[preset: :sinter], []}, {[], [preset: "sinter"]}] do
      assert {:ok, HTTP, resolved} = Destination.resolve(config, flags)
      assert resolved[:url] == "https://sinterlab.dev/api/v1/ingest"
      assert resolved[:token_env] == "SINTER_TOKEN"
      refute Keyword.has_key?(resolved, :preset)
    end
  end

  test "a flag preset wins over the config; a config preset does not" do
    config = [adapter: MyAdapter, token_env: "MY_TOKEN", bucket: "b"]

    assert {:ok, HTTP, resolved} = Destination.resolve(config, preset: "sinter")
    assert resolved[:token_env] == "SINTER_TOKEN"
    assert resolved[:bucket] == "b"

    assert {:ok, MyAdapter, resolved} = Destination.resolve([preset: :sinter] ++ config, [])
    assert resolved[:token_env] == "MY_TOKEN"
  end

  test "a config without an adapter is no destination" do
    assert {:error, "No push destination configured." <> _} =
             Destination.resolve([adapter: nil, url: "https://x"], [])
  end

  test "explicit settings win over the preset, and the url flag over both" do
    assert {:ok, HTTP, resolved} =
             Destination.resolve(
               [preset: :sinter, token_env: "MY_TOKEN", url: "https://config"],
               url: "http://localhost:4000/api/v1/ingest"
             )

    assert resolved[:token_env] == "MY_TOKEN"
    assert resolved[:url] == "http://localhost:4000/api/v1/ingest"
  end

  test "a custom adapter keeps its own options" do
    assert {:ok, MyAdapter, [adapter: MyAdapter, bucket: "b"]} =
             Destination.resolve([adapter: MyAdapter, bucket: "b"], [])
  end

  test "an unknown preset says which ones exist" do
    assert {:error, "Unknown push preset \"nope\". Known: sinter."} =
             Destination.resolve([], preset: "nope")
  end
end
