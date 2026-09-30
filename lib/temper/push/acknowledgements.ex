defmodule Temper.Push.Acknowledgements do
  @moduledoc """
  The runs the push destination has accepted, kept next to the history so
  CI caches them with it: `pushed-runs`, one run id per line.

  `mix temper.push` reads it to send only new runs, and appends the
  run ids of every accepted batch. A lost file only means the next push
  resends everything, which a destination applying each run once skips.

  `merge/3` is pure; `read/1` and `record/2` touch the file.
  """

  @file_name "pushed-runs"
  @default_cap 50_000

  @doc """
  Where the acknowledgements live for history files in `dir`.
  """
  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join(dir, @file_name)

  @doc """
  The acknowledged run ids, or an empty set when there is no file yet.
  """
  @spec read(Path.t()) :: MapSet.t(String.t())
  def read(path) do
    case File.read(path) do
      {:ok, content} -> content |> ids() |> MapSet.new()
      {:error, _missing} -> MapSet.new()
    end
  end

  @doc """
  Adds `run_ids` to the file, keeping the newest #{@default_cap} ids. The
  file is replaced atomically: written to a new file beside it (created
  exclusively, so an existing file or link there is never written
  through), then renamed over it.
  """
  @spec record(Path.t(), [String.t()]) :: :ok | {:error, File.posix()}
  def record(path, run_ids) do
    existing =
      case File.read(path) do
        {:ok, content} -> ids(content)
        {:error, _missing} -> []
      end

    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    content = Enum.map(merge(existing, run_ids), &[&1, "\n"])

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
  `existing` followed by the ids of `new` not already in it, keeping the
  last `cap`.
  """
  @spec merge([String.t()], [String.t()], pos_integer()) :: [String.t()]
  def merge(existing, new, cap \\ @default_cap) do
    known = MapSet.new(existing)
    fresh = new |> Enum.uniq() |> Enum.reject(&MapSet.member?(known, &1))

    (existing ++ fresh) |> Enum.take(-cap)
  end

  defp ids(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
