defmodule Temper.Push.Destination do
  @moduledoc """
  Resolves where `mix temper.push` sends history, from
  `config :temper, :push` and the task's flags.

  A preset fills in the adapter and its options (see `resolve/2` for what
  wins over what). The one preset today:

    * `:sinter` - `Temper.Push.Adapters.HTTP` to
      `https://sinterlab.dev/api/v1/ingest`, token from `SINTER_TOKEN`

  Without an adapter (explicit or from a preset) there is no
  destination: Temper never picks one on its own.

  Pure: the caller passes the configuration in.
  """

  @presets %{
    "sinter" => [
      adapter: Temper.Push.Adapters.HTTP,
      url: "https://sinterlab.dev/api/v1/ingest",
      token_env: "SINTER_TOKEN"
    ]
  }

  @doc """
  The preset names Temper knows.
  """
  @spec presets() :: [String.t()]
  def presets, do: Map.keys(@presets)

  @doc """
  The adapter and its config. `config` is `config :temper, :push`;
  `flags` may carry `:preset` and `:url` from the command line.

  Precedence, lowest first: a preset named in the config, the config
  itself, a preset named by flag, the `--url` flag. So `--preset sinter`
  sends to Sinter whatever the config says, while a config that names a
  preset can still change its url or token variable.
  """
  @spec resolve(keyword(), keyword()) :: {:ok, module(), keyword()} | {:error, String.t()}
  def resolve(config, flags) do
    with {:ok, config} <- apply_presets(config, flags[:preset]) do
      config = if flags[:url], do: Keyword.put(config, :url, flags[:url]), else: config

      case config[:adapter] do
        adapter when is_atom(adapter) and adapter != nil -> {:ok, adapter, config}
        _missing -> {:error, no_destination()}
      end
    end
  end

  defp apply_presets(config, flag_preset) do
    {config_preset, config} = Keyword.pop(config, :preset)

    with {:ok, under} <- preset(config_preset),
         {:ok, over} <- preset(flag_preset) do
      {:ok, under |> Keyword.merge(config) |> Keyword.merge(over)}
    end
  end

  defp preset(nil), do: {:ok, []}

  defp preset(name) do
    case Map.fetch(@presets, to_string(name)) do
      {:ok, preset} ->
        {:ok, preset}

      :error ->
        {:error,
         "Unknown push preset #{inspect(to_string(name))}. Known: #{Enum.join(presets(), ", ")}."}
    end
  end

  defp no_destination do
    "No push destination configured. Set config :temper, :push (an adapter, " <>
      "or preset: :sinter) or pass --preset. See the Push Protocol guide."
  end
end
