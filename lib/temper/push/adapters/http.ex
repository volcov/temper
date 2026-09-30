defmodule Temper.Push.Adapters.HTTP do
  @moduledoc """
  Pushes history over the open push protocol (see the Push Protocol
  guide): one POST per batch, gzip JSON Lines, a bearer token, and a JSON
  answer naming the runs the server now holds.

  Options, from `config :temper, :push`:

    * `:url` (required) - the endpoint; the `--url` flag overrides it.
      Must be `https`, or `http` to the local machine
    * `:token_env` - the environment variable holding the token (default
      `TEMPER_PUSH_TOKEN`). The token is only ever read from the
      environment, so it stays out of config files and shell history
    * `:allow_http` - send to a plain `http://` url that is not the local
      machine (default `false`: the token would travel unencrypted)

  Anything the server writes back is shown in the CI log only after
  control characters are removed and long text is cut, so a hostile
  server cannot rewrite the log. Only accepted run ids that were in the
  batch are recorded.

  `:httpc` ignores `HTTP_PROXY` and `HTTPS_PROXY`; behind a proxy, send
  the history with curl (see the Push Protocol guide) or your own
  adapter.
  """

  @behaviour Temper.Push.Adapter

  alias Temper.Push.HTTPClient

  @default_token_env "TEMPER_PUSH_TOKEN"
  @loopback ["localhost", "127.0.0.1", "::1"]
  @max_text 300

  @impl Temper.Push.Adapter
  def push(batch, config) do
    with {:ok, url} <- url(config),
         {:ok, token} <- token(config) do
      headers = [
        {"authorization", "Bearer " <> token},
        {"content-encoding", "gzip"},
        {"content-type", "application/x-ndjson"}
      ]

      url
      |> HTTPClient.impl().post(headers, batch.body)
      |> answer(batch, shown_url(url))
    end
  end

  # The url and a digest of the token: one endpoint can route
  # repositories by token, so each token is its own destination. Rotating
  # the token resends history once, which receivers skip.
  @impl Temper.Push.Adapter
  def destination_key(config) do
    token =
      case token(config) do
        {:ok, token} -> :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
        {:error, _missing} -> nil
      end

    {config[:url], token}
  end

  defp url(config) do
    with url when is_binary(url) and url != "" <- config[:url],
         %URI{scheme: scheme, host: host} when is_binary(host) and host != "" <- URI.parse(url) do
      cond do
        scheme == "https" ->
          {:ok, url}

        scheme == "http" and (host in @loopback or config[:allow_http] == true) ->
          {:ok, url}

        scheme == "http" ->
          {:error,
           "Refusing to send the token over plain http to #{host}. " <>
             "Use an https url (or allow_http: true on a trusted network)."}

        true ->
          {:error, "The push url must be https (got #{shown_url(url)})."}
      end
    else
      _missing_or_malformed ->
        {:error, "The HTTP push adapter needs a url (config :temper, :push, url: ...)."}
    end
  end

  # A url as it may appear in the log: without credentials.
  defp shown_url(url) do
    url |> URI.parse() |> Map.put(:userinfo, nil) |> URI.to_string()
  end

  defp token(config) do
    env = config[:token_env] || @default_token_env

    case System.get_env(env) do
      nil -> {:error, "#{env} is not set, so nothing was pushed."}
      value -> nonblank_token(env, String.trim(value))
    end
  end

  defp nonblank_token(env, ""), do: {:error, "#{env} is empty, so nothing was pushed."}
  defp nonblank_token(_env, token), do: {:ok, token}

  defp answer({:ok, status, body}, batch, _shown) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"accepted_run_ids" => ids} = reply} when is_list(ids) ->
        sent = MapSet.new(batch.run_ids)
        {:ok, Enum.filter(ids, &(is_binary(&1) and MapSet.member?(sent, &1))), counters(reply)}

      _unexpected ->
        {:error, "The server answered #{status} without accepted_run_ids."}
    end
  end

  defp answer({:ok, status, body}, _batch, _shown),
    do: {:error, "The upload was refused (#{status}): #{error_text(body)}"}

  defp answer({:error, reason}, _batch, shown),
    do: {:error, "Could not reach #{shown}: #{printable(inspect(reason))}"}

  # The reply's integer fields with plain names, for the summary.
  defp counters(reply) do
    for {key, value} <- reply,
        is_integer(value),
        key =~ ~r/\A[a-z][a-z0-9_]{0,39}\z/,
        into: %{},
        do: {key, value}
  end

  # A JSON {"error": ...} when the server wrote one, otherwise the start
  # of whatever came back (a proxy page, say).
  defp error_text(body) do
    text =
      case Jason.decode(body) do
        {:ok, %{"error" => error}} when is_binary(error) -> printable(error)
        _other -> printable(body)
      end

    if text == "", do: "no details", else: text
  end

  # Server text for the CI log: control characters (newlines, escape
  # sequences, which could start CI workflow commands or hide lines)
  # become spaces, and the text is cut short.
  defp printable(text) do
    text
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_text)
  end
end
