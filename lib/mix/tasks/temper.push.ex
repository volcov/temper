defmodule Mix.Tasks.Temper.Push do
  @shortdoc "Pushes recorded history to a configured destination"

  @moduledoc """
  Pushes recorded history to a system that collects it across CI runs,
  such as [Sinter](https://sinterlab.dev).

      $ mix temper.push

  Reads every `.temper/history-*.jsonl` file (all partitions) and sends
  the runs the destination has not acknowledged yet. The destination
  answers with the runs it now holds; they are kept in a `pushed-runs-*`
  file next to the history files (one per destination), so the next push
  leaves them out. Keep it in the same CI cache as the history. A push
  that fails records nothing, and a fresh cache simply resends
  everything.

  A history file that cannot be read, or a run larger than the batch
  limit, is not sent and makes the push count as failed (a warning, or
  exit 1 with `--strict`); everything else still goes.

  The destination comes from `config :temper, :push` (or `--preset`):

      # Sinter: history goes to sinterlab.dev, token from SINTER_TOKEN
      config :temper, :push, preset: :sinter

      # any server speaking the open push protocol (see the Push
      # Protocol guide)
      config :temper, :push,
        adapter: Temper.Push.Adapters.HTTP,
        url: "https://ci-history.example.com/ingest",
        token_env: "CI_HISTORY_TOKEN"

      # anything else: your own Temper.Push.Adapter
      config :temper, :push, adapter: MyApp.TemperToS3, bucket: "ci-history"

  Nothing is configured by default: Temper never sends history anywhere
  on its own. Tokens are read from the environment only. Set the push
  config in `config/config.exs`: mix tasks do not read `runtime.exs`.
  `max_batch_bytes` (default 32 MB, uncompressed) lowers the batch size
  for a destination that accepts less per request.

  A failed push warns and exits 0, so it never turns a green build red;
  pass `--strict` to exit 1 instead. Large histories go out in several
  batches of whole runs; each batch's runs are recorded as soon as the
  destination accepts them.

  ## Options

    * `--preset NAME` - use a preset destination (`sinter`), over the
      config
    * `--url URL` - the endpoint, over the config (for adapters that take
      a url)
    * `--history GLOB` - read this path or glob instead of the default
      (also configurable with `config :temper, history_path: "..."`). A
      literal `{partition}` widens to `*`
    * `--scrub-messages` - remove failure messages before sending; the
      failure kind and hash still go, so failure modes still group
    * `--all` - send every run, accepted before or not
    * `--strict` - exit 1 when the push fails or cannot start
    * `--dry-run` - print what would be sent and send nothing

  """

  use Mix.Task

  alias Temper.History.Reader
  alias Temper.History.Template
  alias Temper.Push.Acknowledgements
  alias Temper.Push.Destination
  alias Temper.Push.Payload

  @switches [
    preset: :string,
    url: :string,
    history: :string,
    scrub_messages: :boolean,
    all: :boolean,
    strict: :boolean,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    config = Application.get_env(:temper, :push, [])

    case Destination.resolve(config, Keyword.take(opts, [:preset, :url])) do
      {:ok, adapter, config} -> push(adapter, config, opts)
      {:error, message} -> fail(message, opts)
    end
  end

  defp push(adapter, config, opts) do
    source =
      Template.to_glob(
        opts[:history] || Application.get_env(:temper, :history_path) || Reader.default_glob()
      )

    files =
      source
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    case files do
      [] -> Mix.shell().info("No history files matching #{source}. Nothing to push.")
      files -> push_files(files, adapter, config, opts)
    end
  end

  defp push_files(files, adapter, config, opts) do
    dir = files |> hd() |> Path.dirname()
    acknowledgements = Path.join(dir, Acknowledgements.file_name(adapter, config))
    {lines, unreadable} = read_lines(files)

    payload =
      Payload.build(
        lines,
        Acknowledgements.read(acknowledgements),
        [all: opts[:all] == true, scrub_messages: opts[:scrub_messages] == true] ++
          Keyword.take(config, [:max_batch_bytes])
      )

    # What cannot go out this time: a failed push even if the rest goes.
    problems = unreadable_problem(unreadable) ++ oversized_problem(payload.oversized, config)

    cond do
      payload.batches == [] and problems == [] ->
        Mix.shell().info(nothing_to_push(payload, files))

      opts[:dry_run] ->
        Mix.shell().info(dry_run_message(payload, adapter, config))
        Enum.each(problems, fn message -> Mix.shell().error(message) end)

      payload.batches == [] ->
        fail(problems, opts)

      true ->
        send_batches(payload, adapter, config, acknowledgements, problems, opts)
    end
  end

  defp send_batches(payload, adapter, config, acknowledgements, problems, opts) do
    {accepted, details, failure} =
      Enum.reduce_while(payload.batches, {0, %{}, nil}, fn batch, {accepted, details, nil} ->
        case push_batch(adapter, batch, config) do
          {:ok, run_ids, batch_details} ->
            record(acknowledgements, run_ids, payload.history_run_ids)
            {:cont, {accepted + length(run_ids), add(details, batch_details), nil}}

          {:error, message} ->
            {:halt, {accepted, details, message}}
        end
      end)

    if accepted > 0 or details != %{}, do: Mix.shell().info(summary(accepted, details))

    case List.wrap(failure) ++ problems do
      [] -> :ok
      messages -> fail(messages, opts)
    end
  end

  defp unreadable_problem([]), do: []

  defp unreadable_problem(files) do
    ["Could not read #{plural(length(files), "history file")}: #{Enum.join(files, ", ")}."]
  end

  defp oversized_problem([], _config), do: []

  defp oversized_problem(run_ids, config) do
    limit = format_bytes(config[:max_batch_bytes] || 32_000_000)
    shown = run_ids |> Enum.take(5) |> Enum.join(", ")
    more = if length(run_ids) > 5, do: " and #{length(run_ids) - 5} more", else: ""

    [
      "#{plural(length(run_ids), "run")} larger than the #{limit} batch limit not sent " <>
        "(#{shown}#{more}). Raise max_batch_bytes if the destination accepts more."
    ]
  end

  # A crashing adapter (or one that is not there) is a failed push like
  # any other: it warns, and only --strict fails the build.
  defp push_batch(adapter, batch, config) do
    adapter.push(batch, config)
  rescue
    exception ->
      {:error, "The #{inspect(adapter)} push adapter failed: #{Exception.message(exception)}"}
  catch
    kind, reason ->
      {:error, "The #{inspect(adapter)} push adapter failed: #{inspect({kind, reason})}"}
  end

  defp nothing_to_push(%{acknowledged: acknowledged} = payload, files) when acknowledged > 0 do
    "Nothing new to push: every run in #{plural(length(files), "file")} was already accepted." <>
      note(payload.corrupt, "corrupt lines left out")
  end

  defp nothing_to_push(payload, files) do
    "Nothing to push: no usable history lines in #{plural(length(files), "file")}." <>
      note(payload.corrupt, "corrupt lines left out")
  end

  # The acknowledgements only save work later, so failing to write them
  # is a warning, never a failed push.
  defp record(path, run_ids, history) do
    case Acknowledgements.record(path, run_ids, history) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error(
          "Could not update #{path} (#{inspect(reason)}); the next push resends these runs."
        )
    end
  end

  # The lines of every readable file, and the files that could not be
  # read (each with its reason).
  defp read_lines(files) do
    {lines, unreadable} =
      Enum.reduce(files, {[], []}, fn file, {lines, unreadable} ->
        case File.read(file) do
          {:ok, content} -> {[String.split(content, "\n") | lines], unreadable}
          {:error, reason} -> {lines, ["#{file} (#{inspect(reason)})" | unreadable]}
        end
      end)

    {lines |> Enum.reverse() |> Enum.concat(), Enum.reverse(unreadable)}
  end

  defp add(details, batch_details) do
    Enum.reduce(batch_details, details, fn {key, value}, details ->
      if is_integer(value), do: Map.update(details, key, value, &(&1 + value)), else: details
    end)
  end

  # Sinter's counters read as a sentence; any other destination's are
  # listed as they came.
  defp summary(accepted, details) do
    "Pushed history: #{plural(accepted, "run")} accepted." <>
      note(details["runs_new"], "new") <>
      note(details["runs_known"], "already known") <>
      note(details["runs_without_sha"], "without a clean commit (not used for flake detection)") <>
      note(details["lines_skipped"], "lines skipped") <>
      note(details["failures_truncated"], "failures past the stored limit") <>
      other_details(details)
  end

  @summarized ~w(runs_new runs_known runs_without_sha lines_skipped failures_truncated)

  defp other_details(details) do
    details
    |> Map.drop(@summarized)
    |> Enum.sort()
    |> Enum.map_join(fn {key, value} -> " #{key}: #{value}." end)
  end

  defp dry_run_message(payload, adapter, config) do
    compressed = payload.batches |> Enum.map(&byte_size(&1.body)) |> Enum.sum()
    target = if config[:url], do: config[:url], else: inspect(adapter)

    "Would push #{plural(payload.runs, "run")} (#{plural(payload.lines, "line")}, " <>
      "#{format_bytes(compressed)} compressed, #{plural(length(payload.batches), "batch")}) " <>
      "to #{target}. Nothing was sent." <>
      note(payload.acknowledged, "lines of accepted runs left out") <>
      note(payload.corrupt, "corrupt lines left out")
  end

  defp fail(messages, opts) do
    Enum.each(List.wrap(messages), fn message -> Mix.shell().error(message) end)

    if opts[:strict] do
      exit({:shutdown, 1})
    else
      Mix.shell().error("Not failing the build (pass --strict to).")
    end
  end

  defp format_bytes(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, "batch"), do: "#{count} batches"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp note(count, _label) when count in [nil, 0], do: ""
  defp note(count, label), do: " #{count} #{label}."
end
