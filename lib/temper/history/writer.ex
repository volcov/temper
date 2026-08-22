defmodule Temper.History.Writer do
  @moduledoc """
  Boundary module that appends history lines to a `.jsonl` file.

  One writer wraps one open file. The default location is
  `.temper/history-{partition}.jsonl` — one file per
  `MIX_TEST_PARTITION` so concurrent partitioned CI runs never write
  to the same file (within one VM the formatter GenServer serializes
  all writes).

  All functions return tagged results instead of raising; the caller
  (`Temper.Formatter`) decides how to degrade.
  """

  alias Temper.History.Codec
  alias Temper.Record
  alias Temper.RunContext

  @default_dir ".temper"

  @enforce_keys [:device, :path]
  defstruct [:device, :path]

  @type t :: %__MODULE__{device: IO.device(), path: Path.t()}

  @doc """
  The default history path for a partition: `.temper/history-{partition}.jsonl`.

  A `nil` partition (no `MIX_TEST_PARTITION` set) maps to `"0"`.
  """
  @spec default_path(String.t() | nil) :: Path.t()
  def default_path(partition) do
    Path.join(@default_dir, "history-#{partition || "0"}.jsonl")
  end

  @doc """
  Opens `path` for appending, creating parent directories as needed.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, File.posix()}
  def open(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, device} <- File.open(path, [:append, :binary]) do
      {:ok, %__MODULE__{device: device, path: path}}
    end
  end

  @doc """
  Appends one encoded test record as a line.
  """
  @spec append(t(), Record.t()) :: :ok | {:error, term()}
  def append(%__MODULE__{device: device}, %Record{} = record) do
    write_line(device, Codec.encode(record))
  end

  @doc """
  Appends the end-of-run suite summary line.
  """
  @spec append_suite(t(), RunContext.t(), %{tests: non_neg_integer(), times_us: map() | nil}) ::
          :ok | {:error, term()}
  def append_suite(%__MODULE__{device: device}, %RunContext{} = context, summary) do
    write_line(device, Codec.encode_suite(context, summary))
  end

  @doc """
  Closes the underlying file, flushing buffered lines.
  """
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{device: device}) do
    File.close(device)
  end

  defp write_line(device, line) do
    IO.binwrite(device, [line, "\n"])
  end
end
