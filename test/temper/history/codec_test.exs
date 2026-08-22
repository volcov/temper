defmodule Temper.History.CodecTest do
  use ExUnit.Case, async: true

  alias Temper.History.Codec
  alias Temper.Record
  alias Temper.RunContext

  @full_context RunContext.new(%{
                  run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
                  at: "2026-08-21T14:03:22Z",
                  sha: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
                  dirty: false,
                  branch: "main",
                  ci: %{provider: "github", run_id: "123"},
                  seed: 493_821,
                  partition: "0",
                  elixir: "1.20.2",
                  otp: "27"
                })

  @minimal_context RunContext.new(%{
                     run_id: "00000000000000000000000000000000",
                     at: "2026-08-21T00:00:00Z",
                     elixir: "1.20.2",
                     otp: "27"
                   })

  @full_record %Record{
    context: @full_context,
    module: "MyApp.UserTest",
    name: "test creates user with valid attrs",
    file: "test/my_app/user_test.exs",
    line: 42,
    async: true,
    test_type: "test",
    status: :failed,
    time_us: 18_342,
    failure: %{
      kind: "ExUnit.AssertionError",
      message: "Assertion with == failed",
      hash: "c0ffee12"
    }
  }

  @minimal_record %Record{
    context: @minimal_context,
    module: "MyApp.OtherTest",
    name: "test does nothing",
    status: :passed
  }

  describe "encode/1" do
    test "produces a single line" do
      line = Codec.encode(@full_record)

      refute line =~ "\n"
    end

    test "stamps schema and kind" do
      decoded = @full_record |> Codec.encode() |> Jason.decode!()

      assert decoded["schema"] == 1
      assert decoded["kind"] == "test"
    end

    test "denormalizes the run context into the line" do
      decoded = @full_record |> Codec.encode() |> Jason.decode!()

      assert decoded["run_id"] == @full_context.run_id
      assert decoded["sha"] == @full_context.sha
      assert decoded["ci"] == %{"provider" => "github", "run_id" => "123"}
      assert decoded["seed"] == 493_821
    end
  end

  describe "encode/1 → decode/1 round-trip" do
    test "a full record survives unchanged" do
      assert {:ok, @full_record} == @full_record |> Codec.encode() |> Codec.decode()
    end

    test "a minimal record survives with nil optionals" do
      assert {:ok, decoded} = @minimal_record |> Codec.encode() |> Codec.decode()

      assert decoded == @minimal_record
      assert decoded.context.sha == nil
      assert decoded.context.ci == nil
      assert decoded.failure == nil
    end

    test "every status survives" do
      for status <- [:passed, :failed, :skipped, :excluded, :invalid] do
        record = %Record{@minimal_record | status: status}

        assert {:ok, %Record{status: ^status}} = record |> Codec.encode() |> Codec.decode()
      end
    end

    test "unicode and JSON-hostile characters survive" do
      record = %Record{
        @minimal_record
        | name: ~s(test "quotes" and \n newlines and émojis 🔥),
          failure: %{kind: "RuntimeError", message: ~s(broke: "badly"\n\ttabs), hash: "deadbeef"}
      }

      assert {:ok, ^record} = record |> Codec.encode() |> Codec.decode()
    end
  end

  describe "decode/1 with the documented schema example" do
    test "decodes the plan's canonical line" do
      line =
        ~s({"schema":1,"kind":"test","run_id":"9f1c","at":"2026-08-21T14:03:22Z",) <>
          ~s("sha":"a1b2c3d","dirty":false,"branch":"main",) <>
          ~s("ci":{"provider":"github","run_id":"123"},) <>
          ~s("seed":493821,"partition":"0","elixir":"1.20.2","otp":"27",) <>
          ~s("module":"MyApp.UserTest","name":"test creates user with valid attrs",) <>
          ~s("file":"test/my_app/user_test.exs","line":42,"async":true,"test_type":"test",) <>
          ~s("status":"failed","time_us":18342,) <>
          ~s("failure":{"kind":"ExUnit.AssertionError","message":"Assertion...","hash":"c0ffee12"})

      assert {:ok, record} = Codec.decode(line <> "}")

      assert record.module == "MyApp.UserTest"
      assert record.status == :failed
      assert record.context.ci == %{provider: "github", run_id: "123"}
      assert record.failure.hash == "c0ffee12"
    end
  end

  describe "decode/1 rejects corrupt and foreign lines" do
    test "malformed JSON" do
      for line <- ["", "not json at all", ~s({"schema":1,"kind":"te), "{{{"] do
        assert Codec.decode(line) == {:error, :invalid_json}
      end
    end

    test "valid JSON that is not an object" do
      assert Codec.decode("[1,2,3]") == {:error, :invalid_json}
      assert Codec.decode(~s("just a string")) == {:error, :invalid_json}
    end

    test "unsupported schema version" do
      line = @full_record |> Codec.encode() |> String.replace(~s("schema":1), ~s("schema":2))

      assert Codec.decode(line) == {:error, {:unsupported_schema, 2}}
    end

    test "missing schema key" do
      assert Codec.decode(~s({"kind":"test"})) == {:error, {:missing_key, "schema"}}
    end

    test "non-test kinds such as suite summaries" do
      line =
        @full_record |> Codec.encode() |> String.replace(~s("kind":"test"), ~s("kind":"suite"))

      assert Codec.decode(line) == {:error, {:unsupported_kind, "suite"}}
    end

    test "missing required keys" do
      assert {:error, {:missing_key, "module"}} =
               ~s({"schema":1,"kind":"test","run_id":"x","at":"t","elixir":"1","otp":"27"})
               |> Codec.decode()
    end

    test "wrong-typed values" do
      bad_values = [
        {"run_id", nil},
        {"at", 20_260_821},
        {"module", 42},
        {"name", ["test"]},
        {"sha", 123},
        {"branch", true},
        {"dirty", "yes"},
        {"async", 1},
        {"seed", -1},
        {"seed", "493821"},
        {"time_us", "fast"},
        {"line", 0},
        {"ci", "github"},
        {"ci", %{"run_id" => "123"}},
        {"ci", %{"provider" => "github", "run_id" => 123}},
        {"failure", "boom"},
        {"failure", %{"kind" => "RuntimeError"}},
        {"failure", %{"kind" => "RuntimeError", "message" => "boom", "hash" => 42}}
      ]

      for {key, value} <- bad_values do
        line =
          @full_record
          |> Codec.encode()
          |> Jason.decode!()
          |> Map.put(key, value)
          |> Jason.encode!()

        assert Codec.decode(line) == {:error, {:invalid_type, key}},
               "expected #{key}=#{inspect(value)} to be rejected"
      end
    end

    test "a ci map without a run_id stays valid" do
      line =
        @full_record
        |> Codec.encode()
        |> Jason.decode!()
        |> Map.put("ci", %{"provider" => "github"})
        |> Jason.encode!()

      assert {:ok, record} = Codec.decode(line)
      assert record.context.ci == %{provider: "github", run_id: nil}
    end

    test "unknown status" do
      line =
        @full_record
        |> Codec.encode()
        |> String.replace(~s("status":"failed"), ~s("status":"exploded"))

      assert Codec.decode(line) == {:error, {:invalid_status, "exploded"}}
    end
  end
end
