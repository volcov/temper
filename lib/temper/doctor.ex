defmodule Temper.Doctor do
  @moduledoc """
  Preflight checks behind `mix temper.doctor`, diagnosing the setup
  mistakes that fail silently: a formatter that never registers, a
  `history_path` invisible outside the test env, a suite that records
  nothing, records without a usable commit SHA.

  `gather/2` is the boundary: it evaluates the project's config for
  the test env (via `Config.Reader` — config files are data, nothing
  is applied), scans `test_helper.exs` and umbrella child `mix.exs`
  files, and reads the recorded history. `evaluate/1` and `render/1`
  are pure: facts in, checks out; checks in, report out.
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
          helpers: %{registered: [Path.t()], mentioned: [Path.t()]},
          umbrella: :not_umbrella | %{children: [Path.t()], without_dep: [Path.t()]},
          current_history_path: String.t() | nil,
          history: %{glob: Path.t(), result: Reader.result()}
        }

  @doc """
  Gathers the facts the checks run on, relative to `root`.

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

    %{
      config: config,
      helpers: scan_helpers(root),
      umbrella: umbrella(root),
      current_history_path: current,
      history: %{glob: glob, result: Reader.read(join(root, glob))}
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

  defp registration_check(facts) do
    formatters = facts.config.formatters || []

    cond do
      Temper.Formatter in formatters ->
        ok("formatter registration", "registered via config :ex_unit for the test env")

      facts.helpers.registered != [] ->
        ok(
          "formatter registration",
          "registered in #{Enum.join(facts.helpers.registered, ", ")}"
        )

      facts.helpers.mentioned != [] ->
        warn(
          "formatter registration",
          "Temper.Formatter appears in #{Enum.join(facts.helpers.mentioned, ", ")} " <>
            "but not visibly inside a formatters: list — could not confirm " <>
            "ExUnit.start receives it",
          "If the formatter list is built dynamically, confirm a recorded run " <>
            "below; otherwise register it:\n" <>
            "    ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])"
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

  defp scan_helpers(root) do
    classified =
      [
        join(root, "test/test_helper.exs")
        | Path.wildcard(join(root, "apps/*/test/test_helper.exs"))
      ]
      |> Enum.group_by(&classify_helper/1)

    %{
      registered: Map.get(classified, :registered, []),
      mentioned: Map.get(classified, :mentioned, [])
    }
  end

  # :registered — the Temper.Formatter alias sits inside a
  # `formatters:` keyword value, the canonical inline registration.
  # :mentioned — the alias appears somewhere else (an `alias` line, a
  # list assigned to a variable that may or may not reach
  # ExUnit.start), which the check reports as unverifiable rather
  # than guessing either way.
  defp classify_helper(path) do
    case parse(path) do
      {:ok, ast} ->
        cond do
          contains?(ast, &registered_formatter?/1) -> :registered
          contains?(ast, &formatter_alias?/1) -> :mentioned
          true -> :absent
        end

      :error ->
        :absent
    end
  end

  defp umbrella(root) do
    case Path.wildcard(join(root, "apps/*/mix.exs")) do
      [] ->
        :not_umbrella

      children ->
        %{
          children: children,
          without_dep: Enum.reject(children, &declares_temper_dep?/1)
        }
    end
  end

  defp declares_temper_dep?(path) do
    case parse(path) do
      {:ok, ast} -> contains?(ast, &temper_dep?/1)
      :error -> false
    end
  end

  # The scans walk the parsed AST, not the raw text, so comments,
  # docstrings and string literals cannot fake a registration or a
  # dependency. A file that cannot be read or parsed counts as not
  # containing the node — a broken file fails test runs loudly on its
  # own, which is not the silent mode this doctor hunts.
  defp parse(path) do
    with {:ok, content} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(content) do
      {:ok, ast}
    else
      {:error, _unreadable_or_unparsable} -> :error
    end
  end

  defp contains?(ast, node?) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or node?.(node)} end)

    found
  end

  defp registered_formatter?({:formatters, value}), do: contains?(value, &formatter_alias?/1)
  defp registered_formatter?(_node), do: false

  defp formatter_alias?({:__aliases__, _meta, [:Temper, :Formatter]}), do: true
  defp formatter_alias?(_node), do: false

  # Dependency-tuple shapes only: `{:temper, "~> 0.2"}` and
  # `{:temper, in_umbrella: true}` are literal 2-tuples in the AST,
  # `{:temper, "~> 0.2", only: [:dev, :test], runtime: false}` is a
  # `:{}` node. A bare `:temper` atom (plt_add_apps, an app named
  # :temper_web) never counts.
  defp temper_dep?({:temper, _requirement_or_opts}), do: true
  defp temper_dep?({:{}, _meta, [:temper | _rest]}), do: true
  defp temper_dep?(_node), do: false

  # Absolute paths (e.g. a Path.expand-ed history_path) stay as they
  # are; "." as root keeps relative output readable.
  defp join(".", path), do: path

  defp join(root, path),
    do: if(Path.type(path) == :absolute, do: path, else: Path.join(root, path))
end
