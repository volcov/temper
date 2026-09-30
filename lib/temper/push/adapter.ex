defmodule Temper.Push.Adapter do
  @moduledoc """
  Where `mix temper.push` sends history: a behaviour, so any system can
  receive it.

  Temper ships `Temper.Push.Adapters.HTTP`, which speaks the open push
  protocol (see the Push Protocol guide); any server implementing it can
  receive history, [Sinter](https://sinterlab.dev) among them. For
  anything else (an object store, an internal queue), write an adapter:

      defmodule MyApp.TemperToS3 do
        @behaviour Temper.Push.Adapter

        @impl true
        def push(batch, config) do
          key = "temper/" <> Base.encode16(:crypto.hash(:sha256, batch.body), case: :lower)
          # upload batch.body (gzip JSON Lines) under key, then:
          {:ok, batch.run_ids, %{}}
        end
      end

      # config/config.exs
      config :temper, :push, adapter: MyApp.TemperToS3, bucket: "ci-history"

  `config` is the `config :temper, :push` keyword list (with the
  `--url` flag applied), so adapters take their own options from it.
  """

  @typedoc """
  One request's worth of history: whole runs, gzip compressed JSON Lines
  (schema v1) in `body`, the ids of those runs, and the uncompressed size.
  """
  @type batch :: %{
          body: binary(),
          run_ids: [String.t()],
          lines: pos_integer(),
          bytes: non_neg_integer()
        }

  @doc """
  Sends one batch. On success, returns the run ids the destination now
  holds (they are not sent again) and any counters worth printing (a map
  of name to integer, possibly empty). On failure, a message for the CI
  log: nothing from this batch is recorded, so the next push retries it.
  """
  @callback push(batch(), config :: keyword()) ::
              {:ok, accepted_run_ids :: [String.t()], details :: map()}
              | {:error, message :: String.t()}

  @doc """
  Optional. Identifies where `config` sends history, so each destination
  keeps its own record of accepted runs (see
  `Temper.Push.Acknowledgements`). Two configs with the same key must
  reach the same stored history.

  Without it, the key is the whole config except `:max_batch_bytes`: any
  other option change (a url, a bucket) counts as a new destination. Keep
  secrets out of the returned term's plain form; hash them if they tell
  destinations apart, as `Temper.Push.Adapters.HTTP` does with its token.
  """
  @callback destination_key(config :: keyword()) :: term()

  @optional_callbacks destination_key: 1

  @doc """
  The destination key for `adapter` with `config` (see
  `c:destination_key/1`).
  """
  @spec destination_key(module(), keyword()) :: term()
  def destination_key(adapter, config) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :destination_key, 1),
      do: adapter.destination_key(config),
      else: config |> Keyword.delete(:max_batch_bytes) |> Enum.sort()
  end
end
