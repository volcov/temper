defmodule Temper.Doctor do
  @moduledoc """
  Preflight checks behind `mix temper.doctor`, diagnosing the setup
  mistakes that fail silently: a formatter that never registers, a
  `history_path` invisible outside the test env, a suite that records
  nothing, records without a usable commit SHA.

  `gather/2` is the boundary: it evaluates the project's config for
  the test env (via `Config.Reader` — config files are data, nothing
  is applied), loads each umbrella child's real dependency list, scans
  `test_helper.exs` files for mentions, and reads the recorded
  history. `evaluate/1` and `render/1` are pure: facts in, checks out;
  checks in, report out.

  The checks follow one evidence policy: a check passes only on
  evaluated evidence (a computed config value, a loaded project's
  deps) or behavioral evidence (recorded history). Source-code scans
  cannot decide what code does at runtime, so a scan result is never
  worth more than a warning.
  """

  alias Temper.History.Reader
  alias Temper.History.Template

  @typedoc "One check result: what was checked, how it went, and how to fix it."
  @type check :: %{
          title: String.t(),
          status: :ok | :warn | :fail,
          detail: String.t(),
          hint: String.t() | nil
        }

  @typedoc "Everything `evaluate/1` needs, gathered from one project root."
  @type facts :: %{
          config: %{
            status: :ok | :missing | {:error, String.t()},
            formatters: [module()] | nil,
            history_path: String.t() | nil
          },
          helper_mentions: [Path.t()],
          umbrella: :not_umbrella | %{children: [Path.t()], without_dep: [Path.t()]},
          current_history_path: String.t() | nil,
          history: %{glob: Path.t(), result: Reader.result()},
          runs: %{last_test_run: integer() | nil, last_recorded: integer() | nil}
        }

  @doc """
  Gathers the facts the checks run on, relative to `root`.

  `:runs` carries two POSIX mtimes: the newest ExUnit failures
  manifest (`mix test` rewrites it on every run, recording or not)
  and the newest history file. Comparing them tells whether the last
  test run actually recorded — `nil` when the file does not exist.

  Options:

    * `:history` — read this path or glob instead of the configured or
      default one (mirrors the mix tasks' `--history`)
  """
  @spec gather(Path.t(), keyword()) :: facts()
  def gather(root \\ ".", opts \\ []) do
    config = read_test_config(join(root, "config/config.exs"))
    current = Application.get_env(:temper, :history_path)

    glob =
      Template.to_glob(opts[:history] || config.history_path || current || Reader.default_glob())

    result = Reader.read(join(root, glob))

    # match_dot: both the .mix directory and the manifest are dotfiles.
    manifests =
      Path.wildcard(join(root, "_build/test/lib/*/.mix/.mix_test_failures"), match_dot: true)

    %{
      config: config,
      helper_mentions: helper_mentions(root),
      umbrella: umbrella(root),
      current_history_path: current,
      history: %{glob: glob, result: result},
      runs: %{
        last_test_run: newest_mtime(manifests),
        last_recorded: newest_mtime(result.files)
      }
    }
  end

  @doc """
  Runs every applicable check against the gathered facts.

  The umbrella check only appears for umbrella projects; the SHA check
  only when there are records to inspect.
  """
  @spec evaluate(facts()) :: [check()]
  def evaluate(facts) do
    [
      registration_check(facts),
      history_path_check(facts),
      umbrella_check(facts),
      history_check(facts),
      sha_check(facts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Renders the checks as the terminal report, summary line included.
  """
  @spec render([check()]) :: String.t()
  def render(checks) do
    Enum.map_join(checks, "\n", &render_check/1) <> "\n\n" <> summary(checks)
  end

  @doc """
  Whether any check failed — the mix task's exit status.
  """
  @spec problems?([check()]) :: boolean()
  def problems?(checks) do
    Enum.any?(checks, &(&1.status == :fail))
  end

  ## Checks (pure)

  # Evidence policy: a source-code scan can never make this check
  # pass. `:ok` requires evaluated evidence (the Config.Reader-computed
  # formatter list) or behavioral evidence (the latest test run
  # demonstrably recorded); the test_helper.exs mention scan only
  # picks the warn or fail wording. Static analysis cannot decide what
  # ExUnit.start receives at runtime, so it is never trusted to.
  #
  # History proves the run that wrote it, nothing later — so records
  # count as current evidence only when the newest test-run manifest
  # is no younger than the newest history write. A manifest younger
  # than the history is the smoking gun this doctor exists for: a
  # test run happened and recorded nothing.
  defp registration_check(facts) do
    formatters = facts.config.formatters || []
    mentions = facts.helper_mentions
    recorded? = facts.history.result.records != []

    cond do
      Temper.Formatter in formatters ->
        ok("formatter registration", "registered via config :ex_unit for the test env")

      recorded? ->
        recorded_registration(facts.runs, mentions)

      mentions != [] ->
        warn(
          "formatter registration",
          "Temper.Formatter appears in #{Enum.join(mentions, ", ")}, but only a " <>
            "recorded run proves ExUnit.start receives it",
          "Run mix test once, then re-run mix temper.doctor — recorded history " <>
            "is the confirmation."
        )

      match?({:error, _reason}, facts.config.status) ->
        {:error, reason} = facts.config.status

        warn(
          "formatter registration",
          "could not evaluate the test-env config (#{reason}) and no " <>
            "test_helper.exs registers Temper.Formatter",
          registration_hint()
        )

      true ->
        fail(
          "formatter registration",
          "Temper.Formatter is not registered anywhere Temper can see — " <>
            "test runs record nothing",
          registration_hint()
        )
    end
  end

  # What existing records prove depends on when the last test run
  # happened relative to the last history write — and history is only
  # current evidence while the sources that produced it still show the
  # formatter: a clean removal since the last run is visible as
  # records with no remaining mention anywhere, and the next run would
  # record nothing.
  defp recorded_registration(runs, mentions) do
    cond do
      run_without_recording?(runs) ->
        fail(
          "formatter registration",
          "the last test run (#{at(runs.last_test_run)}) recorded nothing — " <>
            "history last grew at #{at(runs.last_recorded)}. The registration " <>
            "was removed or stopped loading",
          registration_hint()
        )

      run_recorded?(runs) and mentions == [] ->
        warn(
          "formatter registration",
          "the last test run recorded, but Temper.Formatter now appears in no " <>
            "evaluated config or test_helper.exs — if it was removed since, " <>
            "the next run will record nothing",
          registration_hint()
        )

      run_recorded?(runs) ->
        ok(
          "formatter registration",
          "confirmed by recorded history — the latest test-run manifest and " <>
            "the newest history write coincide"
        )

      true ->
        warn(
          "formatter registration",
          "recorded history exists (last written #{at(runs.last_recorded)}), " <>
            "but with no local test-run manifest to compare it proves a past " <>
            "registration only",
          "Run mix test once, then re-run mix temper.doctor — a fresh recorded " <>
            "run is the confirmation."
        )
    end
  end

  # Both files are written at the end of the same `mix test` run — the
  # history closes at :suite_finished, the manifest after ExUnit.run
  # returns — so a recording run leaves the manifest 0 to a few
  # seconds younger than the history: sibling formatters (a JUnit
  # reporter on a large suite) run their own :suite_finished in
  # between. The slack absorbs that gap, filesystem timestamp
  # granularity included.
  #
  # Known, accepted blind spot: a run whose registration was removed
  # and that COMPLETES within the slack of the previous history write
  # is indistinguishable from a recording run — both leave the same
  # timestamp signature. Shrinking the slack cannot separate them; it
  # only converts that contrived false pass into a plausible false
  # "recorded nothing" failure on healthy suites with slow sibling
  # formatters, which would be the worse error for a gating check.
  @run_slack_seconds 5

  defp run_without_recording?(%{last_test_run: run, last_recorded: recorded}) do
    is_integer(run) and (recorded == nil or run > recorded + @run_slack_seconds)
  end

  defp run_recorded?(%{last_test_run: run, last_recorded: recorded}) do
    is_integer(run) and is_integer(recorded) and run <= recorded + @run_slack_seconds
  end

  defp at(nil), do: "unknown"
  defp at(posix), do: posix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp registration_hint do
    """
    Register it in test/test_helper.exs:
        ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
    or (umbrellas) in config/test.exs:
        config :ex_unit, formatters: [ExUnit.CLIFormatter, Temper.Formatter]\
    """
  end

  defp history_path_check(facts) do
    test_env = facts.config.history_path
    current = facts.current_history_path
    hint = "Set it in config/config.exs, which every env loads — not config/test.exs."

    cond do
      match?({:error, _reason}, facts.config.status) ->
        {:error, reason} = facts.config.status

        warn(
          "history_path",
          "could not evaluate the test-env config (#{reason}) — " <>
            "unable to verify the path is visible outside the test env",
          nil
        )

      test_env == current and is_nil(test_env) ->
        ok("history_path", "using the default .temper/history-{partition}.jsonl in every env")

      test_env == current ->
        ok("history_path", "#{test_env} in every env")

      is_nil(current) ->
        fail(
          "history_path",
          "configured for the test env only (#{test_env}) — the dev-env " <>
            "mix temper.report looks in the default location and finds nothing",
          hint
        )

      is_nil(test_env) ->
        fail(
          "history_path",
          "configured for the current env only (#{current}) — the test-env " <>
            "formatter writes to the default location instead",
          hint
        )

      true ->
        fail(
          "history_path",
          "differs between envs — the formatter writes #{test_env}, " <>
            "this env reads #{current}",
          hint
        )
    end
  end

  defp umbrella_check(%{umbrella: :not_umbrella}), do: nil

  defp umbrella_check(%{umbrella: %{without_dep: []}}) do
    ok("umbrella dependency", "every child app declares :temper — app-dir runs record too")
  end

  defp umbrella_check(%{umbrella: umbrella}) do
    fail_count = length(umbrella.without_dep)

    warn(
      "umbrella dependency",
      "#{fail_count} of #{length(umbrella.children)} child apps do not declare " <>
        ":temper — a suite started inside those directories " <>
        "(cd apps/foo && mix test) records nothing, silently",
      "Run tests from the umbrella root (mix test apps/foo/test still works), " <>
        "or declare :temper in each child app's mix.exs."
    )
  end

  defp history_check(facts) do
    result = facts.history.result

    cond do
      result.files == [] ->
        fail(
          "recorded history",
          "no history files match #{facts.history.glob}",
          "Run mix test once, then re-run mix temper.doctor."
        )

      result.records == [] ->
        fail(
          "recorded history",
          "#{length(result.files)} files matched but hold no test records" <>
            corrupt_note(result),
          "Check the formatter registration above, then run mix test again."
        )

      true ->
        ok(
          "recorded history",
          "#{length(result.records)} test records in #{length(result.files)} files, " <>
            "last recorded at #{last_recorded_at(result.records)}" <> corrupt_note(result)
        )
    end
  end

  defp sha_check(%{history: %{result: %{records: []}}}), do: nil

  defp sha_check(facts) do
    records = facts.history.result.records
    total = length(records)
    missing = Enum.count(records, &is_nil(&1.context.sha))

    hint =
      "Runs outside a git repository record \"sha\":null. In containers, pass " <>
        "TEMPER_SHA in (see README: Containers and environments without git)."

    cond do
      missing == total ->
        fail(
          "recorded commit SHAs",
          "none of the #{total} records carry a commit SHA — " <>
            "no run can ever be classified as flaky",
          hint
        )

      missing > 0 ->
        warn(
          "recorded commit SHAs",
          "#{missing} of #{total} records carry no commit SHA and can never be classified",
          hint
        )

      true ->
        ok("recorded commit SHAs", "all #{total} records carry a commit SHA")
    end
  end

  defp ok(title, detail), do: %{title: title, status: :ok, detail: detail, hint: nil}
  defp warn(title, detail, hint), do: %{title: title, status: :warn, detail: detail, hint: hint}
  defp fail(title, detail, hint), do: %{title: title, status: :fail, detail: detail, hint: hint}

  defp corrupt_note(%{corrupt: 0}), do: ""
  defp corrupt_note(%{corrupt: corrupt}), do: " (#{corrupt} corrupt lines skipped)"

  # Context timestamps are ISO 8601 UTC strings, so the maximum is the
  # latest without parsing.
  defp last_recorded_at(records) do
    records |> Enum.map(& &1.context.at) |> Enum.max()
  end

  ## Rendering (pure)

  defp render_check(check) do
    line = "  #{glyph(check.status)} #{check.title} — #{check.detail}"

    case check.hint do
      nil -> line
      hint -> line <> "\n" <> indent(hint)
    end
  end

  defp glyph(:ok), do: "✓"
  defp glyph(:warn), do: "!"
  defp glyph(:fail), do: "✗"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("      " <> &1))
  end

  defp summary(checks) do
    counts = Enum.frequencies_by(checks, & &1.status)
    fails = Map.get(counts, :fail, 0)
    warns = Map.get(counts, :warn, 0)

    if fails > 0 or warns > 0 do
      "#{length(checks)} checks: #{Map.get(counts, :ok, 0)} ok, " <>
        "#{warns} warnings, #{fails} problems."
    else
      "All #{length(checks)} checks passed."
    end
  end

  ## Gathering (boundary)

  defp read_test_config(config_path) do
    if File.exists?(config_path) do
      evaluate_config(config_path)
    else
      %{status: :missing, formatters: nil, history_path: nil}
    end
  end

  defp evaluate_config(config_path) do
    config = Config.Reader.read!(config_path, env: :test, target: :host)

    %{
      status: :ok,
      formatters: get_in(config, [:ex_unit, :formatters]),
      history_path: get_in(config, [:temper, :history_path])
    }
  rescue
    exception ->
      %{status: {:error, Exception.message(exception)}, formatters: nil, history_path: nil}
  catch
    kind, reason ->
      %{status: {:error, "#{kind}: #{inspect(reason)}"}, formatters: nil, history_path: nil}
  end

  # The mention scan walks the parsed AST, not the raw text, so
  # comments, docstrings and string literals do not count. It makes no
  # stronger claim than "the alias appears in active code" — per the
  # evidence policy on registration_check/1, that can only shape a
  # warning, never a pass. An unreadable or unparsable helper counts
  # as no mention: a broken file fails test runs loudly on its own,
  # which is not the silent mode this doctor hunts.
  defp helper_mentions(root) do
    [
      join(root, "test/test_helper.exs")
      | Path.wildcard(join(root, "apps/*/test/test_helper.exs"))
    ]
    |> Enum.filter(&mentions_formatter?/1)
  end

  defp mentions_formatter?(path) do
    with {:ok, content} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(content) do
      {_ast, found} =
        Macro.prewalk(ast, false, fn node, acc -> {node, acc or formatter_alias?(node)} end)

      found
    else
      {:error, _unreadable_or_unparsable} -> false
    end
  end

  defp formatter_alias?({:__aliases__, _meta, [:Temper, :Formatter]}), do: true
  defp formatter_alias?(_node), do: false

  defp umbrella(root) do
    case Path.wildcard(join(root, "apps/*/mix.exs")) do
      [] ->
        :not_umbrella

      children ->
        apps = known_apps(root)

        %{
          children: children,
          without_dep: Enum.reject(children, &declares_temper_dep?(&1, apps))
        }
    end
  end

  # At the real umbrella root, Mix already knows the child apps — their
  # atoms come from Mix, never minted from directory names.
  defp known_apps(".") do
    Mix.Project.apps_paths() || %{}
  end

  defp known_apps(_other_root), do: %{}

  # Evaluated evidence, not a scan: load the child's mix.exs as a real
  # Mix project and inspect the deps list it actually returns. Dynamic
  # deps (`deps() ++ extra`) resolve correctly, and a `{:temper, ...}`
  # tuple anywhere outside `deps` cannot fake a declaration. A child
  # whose project cannot be loaded or named counts as not declaring —
  # per the evidence policy that can only strengthen the warning, and
  # a genuinely broken child fails its own test runs loudly anyway.
  defp declares_temper_dep?(mix_exs, apps) do
    dir = Path.dirname(mix_exs)
    app = child_app(dir, apps)

    deps = Mix.Project.in_project(app, dir, fn _module -> Mix.Project.config()[:deps] || [] end)

    Enum.any?(deps, &(dep_name(&1) == :temper))
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp child_app(dir, apps) do
    expanded = Path.expand(dir)

    case Enum.find(apps, fn {_app, path} -> Path.expand(path) == expanded end) do
      {app, _path} -> app
      # Raising on an unknown atom lands in the caller's rescue.
      nil -> dir |> Path.basename() |> String.to_existing_atom()
    end
  end

  defp dep_name(dep) when is_atom(dep), do: dep
  defp dep_name(dep) when is_tuple(dep) and tuple_size(dep) > 0, do: elem(dep, 0)
  defp dep_name(_malformed), do: nil

  defp newest_mtime(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} -> [mtime]
        {:error, _vanished} -> []
      end
    end)
    |> Enum.max(fn -> nil end)
  end

  # Absolute paths (e.g. a Path.expand-ed history_path) stay as they
  # are; "." as root keeps relative output readable.
  defp join(".", path), do: path

  defp join(root, path),
    do: if(Path.type(path) == :absolute, do: path, else: Path.join(root, path))
end
