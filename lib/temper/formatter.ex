defmodule Temper.Formatter do
  @moduledoc """
  ExUnit formatter that records every test outcome to the history file.

  Add it alongside the default formatter in `test/test_helper.exs`:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])

  On `:suite_started` it gathers the run context (`Temper.Env`) and
  opens a `Temper.History.Writer`; each `:test_finished` appends one
  record; `:suite_finished` (or `:sigquit`/`:max_failures_reached`)
  appends a suite summary line and closes the file.

  The history path defaults to `.temper/history-{partition}.jsonl` and
  can be overridden with the `:history_path` application env:

      config :temper, history_path: "custom/history-{partition}.jsonl"

  A literal `{partition}` in the configured path expands to the current
  `MIX_TEST_PARTITION` value (`"0"` when unset), keeping custom paths
  partition-safe the same way the default is. Without the placeholder,
  concurrent partitioned runs would all write to the same file.

  Temper must never break a test run: every event handler is guarded —
  on any error the formatter logs a single warning and goes inert for
  the rest of the run.
  """

  use GenServer

  alias Temper.Env
  alias Temper.History.Template
  alias Temper.History.Writer
  alias Temper.Record
  alias Temper.RunContext

  @impl GenServer
  def init(opts) do
    {:ok, %{seed: opts[:seed], context: nil, writer: nil, tests: 0, inert: false}}
  end

  @impl GenServer
  def handle_cast({:suite_started, _opts}, state) do
    {:noreply, safely(state, &start_run/1)}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, safely(state, &record(&1, test))}
  end

  def handle_cast({:suite_finished, times_us}, state) when is_map(times_us) do
    {:noreply, safely(state, &finish(&1, times_us))}
  end

  def handle_cast({:sigquit, _current_tests}, state) do
    {:noreply, safely(state, &finish(&1, nil))}
  end

  def handle_cast(:max_failures_reached, state) do
    {:noreply, safely(state, &finish(&1, nil))}
  end

  # Everything else — module/case/test starts, deprecated case_* events,
  # future protocol additions — is none of our business.
  def handle_cast(_event, state), do: {:noreply, state}

  defp start_run(state) do
    env = Env.gather()
    context = env |> Map.put(:seed, state.seed) |> RunContext.new()

    path =
      case Application.get_env(:temper, :history_path) do
        nil -> Writer.default_path(env.partition)
        configured -> Template.expand(configured, env.partition)
      end

    case Writer.open(path) do
      {:ok, writer} ->
        %{state | context: context, writer: writer}

      {:error, reason} ->
        go_inert(state, "could not open history file #{path} (#{inspect(reason)})")
    end
  end

  defp record(%{writer: nil} = state, _test), do: state

  defp record(state, test) do
    :ok = Writer.append(state.writer, Record.from_test(test, state.context))
    %{state | tests: state.tests + 1}
  end

  # A nil writer means the suite never started or was already closed
  # (finish may fire twice: sigquit/max_failures plus suite_finished).
  defp finish(%{writer: nil} = state, _times_us), do: state

  defp finish(state, times_us) do
    Writer.append_suite(state.writer, state.context, %{tests: state.tests, times_us: times_us})

    # The close flushes buffered lines — an error here means history was
    # lost and deserves the promised warning, not silence.
    case Writer.close(state.writer) do
      :ok ->
        %{state | writer: nil}

      {:error, reason} ->
        go_inert(%{state | writer: nil}, "could not close history file (#{inspect(reason)})")
    end
  end

  defp safely(%{inert: true} = state, _handler), do: state

  defp safely(state, handler) do
    handler.(state)
  rescue
    exception -> go_inert(state, Exception.message(exception))
  catch
    kind, reason -> go_inert(state, "#{kind}: #{inspect(reason)}")
  end

  defp go_inert(state, message) do
    IO.warn("Temper disabled for this run: #{message}", [])
    close_quietly(state.writer)
    %{state | inert: true, writer: nil}
  end

  defp close_quietly(nil), do: :ok

  defp close_quietly(writer) do
    Writer.close(writer)
  rescue
    _any -> :ok
  end
end
