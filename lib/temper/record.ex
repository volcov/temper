defmodule Temper.Record do
  @moduledoc """
  One recorded test outcome — the unit Temper's history is made of.

  `from_test/2` maps a finished `%ExUnit.Test{}` plus the run's
  `Temper.RunContext` into a flat, serializable record: test identity
  (module + name), location and tags, the outcome status, timing, and —
  for failures — a *failure signature* (exception kind, truncated
  message, and a stable hash of the full message) so that later
  analysis can group distinct flake modes.

  This module is part of Temper's functional core: data in, data out,
  no side effects.
  """

  alias Temper.RunContext

  # Failure messages are truncated for storage, but hashed in full so
  # equal failures group together even when truncation hides the tail.
  @message_limit 500
  @hash_bytes 4

  @enforce_keys [:context, :module, :name, :status]
  defstruct [
    :context,
    :module,
    :name,
    :file,
    :line,
    :async,
    :test_type,
    :status,
    :time_us,
    :failure
  ]

  @typedoc "Outcome of a single test, mirroring `ExUnit.Test` states."
  @type status :: :passed | :failed | :skipped | :excluded | :invalid

  @typedoc "Signature of a failure, used to group flake modes."
  @type failure :: %{kind: String.t(), message: String.t(), hash: String.t()}

  @type t :: %__MODULE__{
          context: RunContext.t(),
          module: String.t(),
          name: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          async: boolean() | nil,
          test_type: String.t() | nil,
          status: status(),
          time_us: non_neg_integer() | nil,
          failure: failure() | nil
        }

  @doc """
  Builds a record from a finished ExUnit test and the current run context.

  The mapping from `test.state` to `:status`:

    * `nil` → `:passed`
    * `{:failed, failures}` → `:failed`, with a failure signature taken
      from the first failure
    * `{:skipped, _}`, `{:excluded, _}`, `{:invalid, _}` → the
      corresponding atom

  `:module` and `:name` together identify the test across runs;
  `:file`, `:line`, `:async` and `:test_type` come from `test.tags`.
  `:time_us` is ExUnit's measured runtime in microseconds (`nil` for
  tests that never ran, e.g. excluded ones).
  """
  @spec from_test(ExUnit.Test.t(), RunContext.t()) :: t()
  def from_test(%ExUnit.Test{} = test, %RunContext{} = context) do
    {status, failure} = interpret_state(test.state)

    %__MODULE__{
      context: context,
      module: inspect(test.module),
      name: to_string(test.name),
      file: test.tags[:file] && to_string(test.tags[:file]),
      line: test.tags[:line],
      async: test.tags[:async],
      test_type: test.tags[:test_type] && to_string(test.tags[:test_type]),
      status: status,
      time_us: test.time,
      failure: failure
    }
  end

  defp interpret_state(nil), do: {:passed, nil}
  defp interpret_state({:failed, failures}), do: {:failed, signature(failures)}
  defp interpret_state({:skipped, _reason}), do: {:skipped, nil}
  defp interpret_state({:excluded, _reason}), do: {:excluded, nil}
  defp interpret_state({:invalid, _module}), do: {:invalid, nil}

  defp signature([{kind, reason, _stacktrace} | _rest]) do
    {name, message} = describe(kind, reason)
    %{kind: name, message: truncate(message), hash: hash(message)}
  end

  defp signature(_unexpected_shape), do: nil

  defp describe(:error, %module{} = exception), do: {inspect(module), safe_message(exception)}
  defp describe(kind, reason), do: {to_string(kind), inspect(reason, limit: 50)}

  defp safe_message(exception) do
    Exception.message(exception)
  rescue
    # A broken message/1 implementation must not break recording.
    _any -> inspect(exception, limit: 50)
  end

  defp truncate(message) do
    if String.length(message) > @message_limit do
      String.slice(message, 0, @message_limit)
    else
      message
    end
  end

  defp hash(message) do
    :sha256
    |> :crypto.hash(message)
    |> binary_part(0, @hash_bytes)
    |> Base.encode16(case: :lower)
  end
end
