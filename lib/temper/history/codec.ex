defmodule Temper.History.Codec do
  @moduledoc """
  Encodes `Temper.Record`s as history lines and decodes them back.

  Each line is one self-contained JSON object (schema v1): the run
  context is denormalized into every line so a history file can be
  read without joins, and `run_id` groups lines from the same run.

  `decode/1` never raises — corrupt or foreign input (truncated CI
  cache tails, future schema versions, non-test lines) comes back as
  a tagged `{:error, reason}` so readers can count and skip it.

  This module is part of Temper's functional core: strings in,
  records out, no side effects.
  """

  alias Temper.Record
  alias Temper.RunContext

  @schema 1
  @kind "test"

  @required_keys ~w(schema kind run_id at elixir otp module name status)

  @statuses %{
    "passed" => :passed,
    "failed" => :failed,
    "skipped" => :skipped,
    "excluded" => :excluded,
    "invalid" => :invalid
  }

  # Wrong-typed values must fail decoding, not produce records that
  # violate the Record.t()/RunContext.t() contracts downstream.
  @field_types [
    {"run_id", :string},
    {"at", :string},
    {"elixir", :string},
    {"otp", :string},
    {"module", :string},
    {"name", :string},
    {"sha", :optional_string},
    {"branch", :optional_string},
    {"partition", :optional_string},
    {"file", :optional_string},
    {"test_type", :optional_string},
    {"dirty", :optional_boolean},
    {"async", :optional_boolean},
    {"seed", :optional_non_neg_integer},
    {"time_us", :optional_non_neg_integer},
    {"line", :optional_pos_integer},
    {"ci", :optional_ci},
    {"failure", :optional_failure}
  ]

  @typedoc "Reasons `decode/1` can reject a line."
  @type decode_error ::
          :invalid_json
          | {:unsupported_schema, term()}
          | {:unsupported_kind, term()}
          | {:missing_key, String.t()}
          | {:invalid_status, term()}
          | {:invalid_type, String.t()}

  @doc """
  Encodes a record as a single JSON line, without a trailing newline.
  """
  @spec encode(Record.t()) :: String.t()
  def encode(%Record{context: %RunContext{} = context} = record) do
    Jason.encode!(%{
      "schema" => @schema,
      "kind" => @kind,
      "run_id" => context.run_id,
      "at" => context.at,
      "sha" => context.sha,
      "dirty" => context.dirty,
      "branch" => context.branch,
      "ci" => context.ci,
      "seed" => context.seed,
      "partition" => context.partition,
      "elixir" => context.elixir,
      "otp" => context.otp,
      "module" => record.module,
      "name" => record.name,
      "file" => record.file,
      "line" => record.line,
      "async" => record.async,
      "test_type" => record.test_type,
      "status" => to_string(record.status),
      "time_us" => record.time_us,
      "failure" => record.failure
    })
  end

  @doc """
  Decodes one history line back into a `Temper.Record`.

  Returns `{:error, reason}` for malformed JSON, unknown schema
  versions, non-test kinds (e.g. future `"suite"` summary lines),
  missing required keys or unknown statuses. Never raises.
  """
  @spec decode(String.t()) :: {:ok, Record.t()} | {:error, decode_error()}
  def decode(line) when is_binary(line) do
    with {:ok, map} <- decode_json(line),
         :ok <- check_schema(map),
         :ok <- check_kind(map),
         :ok <- check_required_keys(map),
         {:ok, status} <- check_status(map),
         :ok <- check_field_types(map) do
      {:ok, build_record(map, status)}
    end
  end

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _not_an_object} -> {:error, :invalid_json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp check_schema(%{"schema" => @schema}), do: :ok
  defp check_schema(%{"schema" => other}), do: {:error, {:unsupported_schema, other}}
  defp check_schema(_map), do: {:error, {:missing_key, "schema"}}

  defp check_kind(%{"kind" => @kind}), do: :ok
  defp check_kind(%{"kind" => other}), do: {:error, {:unsupported_kind, other}}
  defp check_kind(_map), do: {:error, {:missing_key, "kind"}}

  defp check_required_keys(map) do
    case Enum.find(@required_keys, fn key -> not Map.has_key?(map, key) end) do
      nil -> :ok
      missing -> {:error, {:missing_key, missing}}
    end
  end

  defp check_status(%{"status" => status}) do
    case Map.fetch(@statuses, status) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_status, status}}
    end
  end

  defp check_field_types(map) do
    invalid =
      Enum.find(@field_types, fn {key, type} ->
        not valid_type?(Map.get(map, key), type)
      end)

    case invalid do
      nil -> :ok
      {key, _type} -> {:error, {:invalid_type, key}}
    end
  end

  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(nil, _optional_type), do: true
  defp valid_type?(value, :optional_string), do: is_binary(value)
  defp valid_type?(value, :optional_boolean), do: is_boolean(value)
  defp valid_type?(value, :optional_non_neg_integer), do: is_integer(value) and value >= 0
  defp valid_type?(value, :optional_pos_integer), do: is_integer(value) and value > 0
  defp valid_type?(value, :optional_ci), do: valid_ci?(value)
  defp valid_type?(value, :optional_failure), do: valid_failure?(value)

  defp valid_ci?(%{"provider" => provider} = ci) when is_binary(provider) do
    case Map.get(ci, "run_id") do
      nil -> true
      run_id -> is_binary(run_id)
    end
  end

  defp valid_ci?(_malformed), do: false

  defp valid_failure?(%{"kind" => kind, "message" => message, "hash" => hash}) do
    is_binary(kind) and is_binary(message) and is_binary(hash)
  end

  defp valid_failure?(_malformed), do: false

  defp build_record(map, status) do
    context =
      RunContext.new(%{
        run_id: map["run_id"],
        at: map["at"],
        sha: map["sha"],
        dirty: map["dirty"] == true,
        branch: map["branch"],
        ci: decode_ci(map["ci"]),
        seed: map["seed"],
        partition: map["partition"],
        elixir: map["elixir"],
        otp: map["otp"]
      })

    %Record{
      context: context,
      module: map["module"],
      name: map["name"],
      file: map["file"],
      line: map["line"],
      async: map["async"],
      test_type: map["test_type"],
      status: status,
      time_us: map["time_us"],
      failure: decode_failure(map["failure"])
    }
  end

  defp decode_ci(%{"provider" => provider} = ci), do: %{provider: provider, run_id: ci["run_id"]}
  defp decode_ci(_absent_or_malformed), do: nil

  defp decode_failure(%{"kind" => kind, "message" => message, "hash" => hash}) do
    %{kind: kind, message: message, hash: hash}
  end

  defp decode_failure(_absent_or_malformed), do: nil
end
