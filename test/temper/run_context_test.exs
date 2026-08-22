defmodule Temper.RunContextTest do
  use ExUnit.Case, async: true

  doctest Temper.RunContext

  alias Temper.RunContext

  @required %{
    run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
    at: "2026-08-21T14:03:22Z",
    elixir: "1.20.2",
    otp: "27"
  }

  describe "new/1 with a full map" do
    test "keeps every gathered value" do
      context =
        RunContext.new(
          Map.merge(@required, %{
            sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
            dirty: true,
            branch: "main",
            ci: %{provider: "github", run_id: "123"},
            seed: 493_821,
            partition: "0"
          })
        )

      assert context.run_id == @required.run_id
      assert context.at == "2026-08-21T14:03:22Z"
      assert context.sha == "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
      assert context.dirty == true
      assert context.branch == "main"
      assert context.ci == %{provider: "github", run_id: "123"}
      assert context.seed == 493_821
      assert context.partition == "0"
      assert context.elixir == "1.20.2"
      assert context.otp == "27"
    end
  end

  describe "new/1 with a minimal map" do
    test "defaults every optional field" do
      context = RunContext.new(@required)

      assert context.sha == nil
      assert context.dirty == false
      assert context.branch == nil
      assert context.ci == nil
      assert context.seed == nil
      assert context.partition == nil
    end
  end

  describe "new/1 with missing required keys" do
    test "raises KeyError when any required key is absent" do
      for key <- [:run_id, :at, :elixir, :otp] do
        assert_raise KeyError, fn ->
          @required |> Map.delete(key) |> RunContext.new()
        end
      end
    end
  end
end
