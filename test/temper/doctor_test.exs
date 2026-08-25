defmodule Temper.DoctorTest do
  # gather/2 reads the :temper application env.
  use ExUnit.Case, async: false

  alias Temper.Doctor
  alias Temper.History.Codec
  alias Temper.Record
  alias Temper.RunContext

  defp record(overrides \\ []) do
    context =
      RunContext.new(%{
        run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
        at: Keyword.get(overrides, :at, "2026-08-24T12:00:00Z"),
        sha: Keyword.get(overrides, :sha, "abc1234"),
        elixir: "1.20.2",
        otp: "27"
      })

    %Record{context: context, module: "DemoTest", name: "test x", status: :passed}
  end

  defp read_result(overrides \\ []) do
    Map.merge(
      %{
        records: [record()],
        files: [".temper/history-0.jsonl"],
        corrupt: 0,
        skipped: 0,
        unreadable: []
      },
      Map.new(overrides)
    )
  end

  defp facts(overrides \\ []) do
    Map.merge(
      %{
        config: %{
          status: :ok,
          formatters: [ExUnit.CLIFormatter, Temper.Formatter],
          history_path: nil
        },
        helpers: %{registered: [], mentioned: []},
        umbrella: :not_umbrella,
        current_history_path: nil,
        history: %{glob: ".temper/history-*.jsonl", result: read_result()}
      },
      Map.new(overrides)
    )
  end

  defp check(checks, title) do
    Enum.find(checks, &(&1.title == title)) || flunk("no check titled #{title}")
  end

  describe "evaluate/1 — formatter registration" do
    test "registration via config :ex_unit passes" do
      checks = Doctor.evaluate(facts())

      assert %{status: :ok, detail: "registered via config :ex_unit" <> _rest} =
               check(checks, "formatter registration")
    end

    test "registration via a test_helper passes when config has none" do
      checks =
        Doctor.evaluate(
          facts(
            config: %{status: :missing, formatters: nil, history_path: nil},
            helpers: %{registered: ["test/test_helper.exs"], mentioned: []}
          )
        )

      assert %{status: :ok, detail: "registered in test/test_helper.exs"} =
               check(checks, "formatter registration")
    end

    test "a mention outside a formatters: list warns instead of passing" do
      checks =
        Doctor.evaluate(
          facts(
            config: %{status: :missing, formatters: nil, history_path: nil},
            helpers: %{registered: [], mentioned: ["test/test_helper.exs"]}
          )
        )

      assert %{status: :warn, detail: detail, hint: hint} =
               check(checks, "formatter registration")

      assert detail =~ "could not confirm ExUnit.start receives it"
      assert hint =~ "built dynamically"
    end

    test "no registration anywhere fails with both setup hints" do
      checks =
        Doctor.evaluate(facts(config: %{status: :missing, formatters: nil, history_path: nil}))

      assert %{status: :fail, hint: hint} = check(checks, "formatter registration")
      assert hint =~ "ExUnit.start(formatters:"
      assert hint =~ "config :ex_unit"
    end

    test "an unevaluable config downgrades the miss to a warning" do
      checks =
        Doctor.evaluate(
          facts(config: %{status: {:error, "boom"}, formatters: nil, history_path: nil})
        )

      assert %{status: :warn, detail: detail} = check(checks, "formatter registration")
      assert detail =~ "boom"
    end
  end

  describe "evaluate/1 — history_path" do
    test "unset everywhere is the partition-safe default" do
      assert %{status: :ok, detail: detail} =
               Doctor.evaluate(facts()) |> check("history_path")

      assert detail =~ "default .temper/history-{partition}.jsonl"
    end

    test "the same value in both envs passes" do
      checks =
        Doctor.evaluate(
          facts(
            config: %{status: :ok, formatters: [Temper.Formatter], history_path: "h.jsonl"},
            current_history_path: "h.jsonl"
          )
        )

      assert %{status: :ok, detail: "h.jsonl in every env"} = check(checks, "history_path")
    end

    test "a test-env-only value fails — the report task cannot see it" do
      checks =
        Doctor.evaluate(
          facts(config: %{status: :ok, formatters: [Temper.Formatter], history_path: "h.jsonl"})
        )

      assert %{status: :fail, detail: detail, hint: hint} = check(checks, "history_path")
      assert detail =~ "test env only"
      assert hint =~ "config/config.exs"
    end

    test "a current-env-only value fails — the formatter writes elsewhere" do
      checks = Doctor.evaluate(facts(current_history_path: "h.jsonl"))

      assert %{status: :fail, detail: detail} = check(checks, "history_path")
      assert detail =~ "current env only"
    end

    test "different values per env fail" do
      checks =
        Doctor.evaluate(
          facts(
            config: %{status: :ok, formatters: [Temper.Formatter], history_path: "a.jsonl"},
            current_history_path: "b.jsonl"
          )
        )

      assert %{status: :fail, detail: detail} = check(checks, "history_path")
      assert detail =~ "differs between envs"
    end

    test "an unevaluable config warns instead of guessing" do
      checks =
        Doctor.evaluate(
          facts(config: %{status: {:error, "boom"}, formatters: nil, history_path: nil})
        )

      assert %{status: :warn} = check(checks, "history_path")
    end
  end

  describe "evaluate/1 — umbrella dependency" do
    test "non-umbrella projects skip the check" do
      refute Enum.any?(Doctor.evaluate(facts()), &(&1.title == "umbrella dependency"))
    end

    test "every child declaring :temper passes" do
      checks =
        Doctor.evaluate(
          facts(umbrella: %{children: ["apps/a/mix.exs", "apps/b/mix.exs"], without_dep: []})
        )

      assert %{status: :ok} = check(checks, "umbrella dependency")
    end

    test "children without the dep warn about silent app-dir runs" do
      checks =
        Doctor.evaluate(
          facts(
            umbrella: %{
              children: ["apps/a/mix.exs", "apps/b/mix.exs"],
              without_dep: ["apps/b/mix.exs"]
            }
          )
        )

      assert %{status: :warn, detail: detail, hint: hint} = check(checks, "umbrella dependency")
      assert detail =~ "1 of 2 child apps"
      assert detail =~ "records nothing, silently"
      assert hint =~ "umbrella root"
    end
  end

  describe "evaluate/1 — recorded history and SHAs" do
    test "records with SHAs pass both checks and report freshness" do
      records = [record(at: "2026-08-23T09:00:00Z"), record(at: "2026-08-24T12:00:00Z")]

      checks =
        Doctor.evaluate(facts(history: %{glob: "g", result: read_result(records: records)}))

      assert %{status: :ok, detail: detail} = check(checks, "recorded history")
      assert detail =~ "2 test records in 1 files"
      assert detail =~ "last recorded at 2026-08-24T12:00:00Z"

      assert %{status: :ok, detail: "all 2 records carry a commit SHA"} =
               check(checks, "recorded commit SHAs")
    end

    test "no matching files fails and skips the SHA check" do
      checks =
        Doctor.evaluate(facts(history: %{glob: "g", result: read_result(records: [], files: [])}))

      assert %{status: :fail, hint: hint} = check(checks, "recorded history")
      assert hint =~ "Run mix test once"
      refute Enum.any?(checks, &(&1.title == "recorded commit SHAs"))
    end

    test "files without records fail and mention corruption" do
      checks =
        Doctor.evaluate(
          facts(history: %{glob: "g", result: read_result(records: [], corrupt: 3)})
        )

      assert %{status: :fail, detail: detail} = check(checks, "recorded history")
      assert detail =~ "hold no test records"
      assert detail =~ "3 corrupt lines skipped"
    end

    test "records entirely without SHAs fail with the container hint" do
      result = read_result(records: [record(sha: nil), record(sha: nil)])
      checks = Doctor.evaluate(facts(history: %{glob: "g", result: result}))

      assert %{status: :fail, detail: detail, hint: hint} = check(checks, "recorded commit SHAs")
      assert detail =~ "none of the 2 records"
      assert hint =~ "TEMPER_SHA"
    end

    test "a partial SHA gap warns" do
      result = read_result(records: [record(), record(sha: nil)])
      checks = Doctor.evaluate(facts(history: %{glob: "g", result: result}))

      assert %{status: :warn, detail: detail} = check(checks, "recorded commit SHAs")
      assert detail =~ "1 of 2 records"
    end
  end

  describe "render/1 and problems?/1" do
    test "a clean run renders all-passed" do
      checks = Doctor.evaluate(facts())
      output = Doctor.render(checks)

      assert output =~ "✓ formatter registration"
      assert output =~ "All 4 checks passed."
      refute Doctor.problems?(checks)
    end

    test "failures render glyph, indented hint and summary counts" do
      checks =
        Doctor.evaluate(facts(config: %{status: :missing, formatters: nil, history_path: nil}))

      output = Doctor.render(checks)

      assert output =~ "✗ formatter registration"
      assert output =~ "\n      Register it in test/test_helper.exs:"
      assert output =~ "4 checks: 3 ok, 0 warnings, 1 problems."
      assert Doctor.problems?(checks)
    end
  end

  describe "gather/2" do
    setup do
      previous = Application.get_env(:temper, :history_path)
      Application.delete_env(:temper, :history_path)

      on_exit(fn ->
        if previous, do: Application.put_env(:temper, :history_path, previous)
      end)

      dir =
        Path.join(System.tmp_dir!(), "temper_doctor_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "reads formatters and history_path from the test-env config", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "config"))

      File.write!(Path.join(dir, "config/config.exs"), """
      import Config
      import_config "\#{config_env()}.exs"
      """)

      File.write!(Path.join(dir, "config/test.exs"), """
      import Config
      config :ex_unit, formatters: [ExUnit.CLIFormatter, Temper.Formatter]
      config :temper, history_path: "custom/history-{partition}.jsonl"
      """)

      facts = Doctor.gather(dir)

      assert facts.config.status == :ok
      assert Temper.Formatter in facts.config.formatters
      assert facts.config.history_path == "custom/history-{partition}.jsonl"
      assert facts.history.glob == "custom/history-*.jsonl"
    end

    test "a raising config comes back as an error, not a crash", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "config"))
      File.write!(Path.join(dir, "config/config.exs"), ~s[raise "boom"])

      assert %{config: %{status: {:error, message}}} = Doctor.gather(dir)
      assert message =~ "boom"
    end

    test "finds registrations in test_helper files and umbrella deps", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(
        Path.join(dir, "test/test_helper.exs"),
        "ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])\n"
      )

      deps = [
        {"a", "[{:temper, \"~> 0.2\", only: [:dev, :test], runtime: false}]"},
        {"b", "[]"}
      ]

      for {app, list} <- deps do
        File.mkdir_p!(Path.join(dir, "apps/#{app}"))

        File.write!(Path.join(dir, "apps/#{app}/mix.exs"), """
        defmodule #{String.upcase(app)}.MixProject do
          defp deps, do: #{list}
        end
        """)
      end

      facts = Doctor.gather(dir)

      assert facts.helpers.registered == [Path.join(dir, "test/test_helper.exs")]
      assert %{children: [_a, _b], without_dep: [without]} = facts.umbrella
      assert without =~ "apps/b/mix.exs"
    end

    test "an alias or dynamic list is a mention, not a registration", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(Path.join(dir, "test/test_helper.exs"), """
      alias Temper.Formatter
      ExUnit.start()
      """)

      assert %{registered: [], mentioned: [helper]} = Doctor.gather(dir).helpers
      assert helper =~ "test/test_helper.exs"

      File.write!(Path.join(dir, "test/test_helper.exs"), """
      formatters = [ExUnit.CLIFormatter, Temper.Formatter]
      ExUnit.start(formatters: formatters)
      """)

      assert %{registered: [], mentioned: [_helper]} = Doctor.gather(dir).helpers
    end

    test "a :temper atom outside a dep tuple never counts as the dep", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "apps/web"))

      File.write!(Path.join(dir, "apps/web/mix.exs"), """
      defmodule Web.MixProject do
        def project, do: [dialyzer: [plt_add_apps: [:temper]]]
        defp deps, do: []
      end
      """)

      File.mkdir_p!(Path.join(dir, "apps/core"))

      File.write!(Path.join(dir, "apps/core/mix.exs"), """
      defmodule Core.MixProject do
        defp deps, do: [{:temper, in_umbrella: true}]
      end
      """)

      assert %{without_dep: [without]} = Doctor.gather(dir).umbrella
      assert without =~ "apps/web/mix.exs"
    end

    test "comments, strings and lookalike atoms never count as setup", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(Path.join(dir, "test/test_helper.exs"), """
      # TODO: enable Temper again
      # ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
      IO.puts("without Temper.Formatter")
      ExUnit.start()
      """)

      File.mkdir_p!(Path.join(dir, "apps/web"))

      File.write!(Path.join(dir, "apps/web/mix.exs"), """
      defmodule TemperWeb.MixProject do
        # {:temper, "~> 0.2"} lives at the umbrella root
        def project, do: [app: :temper_web, description: "uses :temper indirectly"]
        defp deps, do: []
      end
      """)

      facts = Doctor.gather(dir)

      assert facts.helpers == %{registered: [], mentioned: []}
      assert %{without_dep: [without]} = facts.umbrella
      assert without =~ "apps/web/mix.exs"
    end

    test "an unparsable helper counts as unregistered, not a crash", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "test"))
      File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start(formatters: [\n")

      assert Doctor.gather(dir).helpers == %{registered: [], mentioned: []}
    end

    test "reads recorded history through the resolved glob", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".temper"))

      File.write!(
        Path.join(dir, ".temper/history-0.jsonl"),
        Codec.encode(record()) <> "\n"
      )

      facts = Doctor.gather(dir)

      assert facts.history.glob == ".temper/history-*.jsonl"
      assert [%Record{}] = facts.history.result.records
    end

    test "the :history option overrides config and widens {partition}", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "elsewhere"))

      File.write!(
        Path.join(dir, "elsewhere/history-3.jsonl"),
        Codec.encode(record()) <> "\n"
      )

      facts = Doctor.gather(dir, history: "elsewhere/history-{partition}.jsonl")

      assert facts.history.glob == "elsewhere/history-*.jsonl"
      assert length(facts.history.result.records) == 1
    end
  end
end
