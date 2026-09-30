defmodule Temper.Push.HTTPClient do
  @moduledoc """
  The transport under `Temper.Push.Adapters.HTTP`: one POST of a body.

  Behind a behaviour so tests replace it. The implementation is read from
  `config :temper, :push_http_client` and defaults to `Temper.Push.Httpc`
  (OTP's `:httpc`, so Temper needs no HTTP dependency).
  """

  @type header :: {String.t(), String.t()}

  @doc """
  POSTs `body` to `url` with `headers`. Any status is `{:ok, status,
  body}`; only a failure to talk to the server is an error.
  """
  @callback post(url :: String.t(), headers :: [header()], body :: binary()) ::
              {:ok, pos_integer(), binary()} | {:error, term()}

  @doc """
  The configured implementation.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:temper, :push_http_client, Temper.Push.Httpc)
end
