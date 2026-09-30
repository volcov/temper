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
end
