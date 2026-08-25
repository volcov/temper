defmodule Temper.History.Template do
  @moduledoc """
  The `{partition}` placeholder in configured history paths.

  A custom `:history_path` containing `{partition}` is partition-safe
  by construction: the formatter expands the placeholder with the
  current `MIX_TEST_PARTITION` value before writing, and the report
  and clean tasks widen it to `*` so a read covers every partition's
  file — the same behavior the default
  `.temper/history-{partition}.jsonl` location has always had.

  A path without the placeholder passes through both functions
  unchanged.
  """

  @placeholder "{partition}"

  @doc """
  Expands `{partition}` with the partition value for writing.

  A `nil` partition (no `MIX_TEST_PARTITION` set) maps to `"0"`,
  mirroring `Temper.History.Writer.default_path/1`.
  """
  @spec expand(Path.t(), String.t() | nil) :: Path.t()
  def expand(path, partition) do
    String.replace(path, @placeholder, partition || "0")
  end

  @doc """
  Widens `{partition}` to `*` so one glob reads every partition's file.
  """
  @spec to_glob(Path.t()) :: Path.t()
  def to_glob(path) do
    String.replace(path, @placeholder, "*")
  end
end
