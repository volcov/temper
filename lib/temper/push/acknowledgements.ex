defmodule Temper.Push.Acknowledgements do
  @moduledoc """
  The runs a push destination has accepted, kept next to the history so
  CI caches them with it: one file per destination, `pushed-runs-<id>`,
  one run id per line. `<id>` is a short hash of the destination (the
  adapter and its `Temper.Push.Adapter.destination_key/2`), so pointing
  the task somewhere else starts from nothing instead of skipping runs
  the new destination never saw.

  `mix temper.push` reads it to send only new runs, and adds the run ids
  of every accepted batch. Ids of runs no longer in the history are
  dropped as it is written (unless part of the history could not be
  read), so the file shrinks with the history. A lost file only means
  the next push resends everything, which a destination applying each
  run once skips.

  `merge/3` and `file_name/2` are pure; `read/1` and `record/3` touch the
  file.
  """

  alias Temper.Push.Adapter

  @doc """
  The file name for the destination `adapter` with `config`.
  """
  @spec file_name(module(), keyword()) :: String.t()
  def file_name(adapter, config) do
    key = {adapter, Adapter.destination_key(adapter, config)}
    hash = :sha256 |> :crypto.hash(:erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    "pushed-runs-" <> binary_part(hash, 0, 8)
  end

  @doc """
  The accepted run ids, or an empty set when there is no file yet.
  """
  @spec read(Path.t()) :: MapSet.t(String.t())
  def read(path) do
    case File.read(path) do
      {:ok, content} -> content |> ids() |> MapSet.new()
      {:error, _missing} -> MapSet.new()
    end
  end

  @doc """
  Adds `run_ids` to the file and keeps only the ids in `history` (a
  `MapSet` of the run ids the history holds now), or every id when
  `history` is `nil` (part of the history could not be read, so absent
  ids may still be there). The file is replaced atomically: written to a
  new file beside it (created exclusively, so an existing file or link
  there is never written through), then renamed over it.
  """
  @spec record(Path.t(), [String.t()], MapSet.t(String.t()) | nil) ::
          :ok | {:error, File.posix()}
  def record(path, run_ids, history) do
    existing =
      case File.read(path) do
        {:ok, content} -> ids(content)
        {:error, _missing} -> []
      end

    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    content = Enum.map(merge(existing, run_ids, history), &[&1, "\n"])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, content, [:exclusive]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc """
  `existing` followed by the ids of `new` not already in it, keeping only
  ids in `history` (all of them when `history` is `nil`).
  """
  @spec merge([String.t()], [String.t()], MapSet.t(String.t()) | nil) :: [String.t()]
  def merge(existing, new, nil), do: Enum.uniq(existing ++ new)

  def merge(existing, new, history) do
    existing |> merge(new, nil) |> Enum.filter(&MapSet.member?(history, &1))
  end

  defp ids(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
