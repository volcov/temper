defmodule Temper.Push.Httpc do
  @moduledoc """
  `Temper.Push.HTTPClient` over OTP's `:httpc`, so Temper needs no HTTP
  dependency.

  TLS is verified: the peer certificate against the system's CA store
  (`:public_key.cacerts_get/0`, OTP 25+) and the host name against the
  certificate. `:inets` and `:ssl` are Temper's extra applications, so
  they are on the code path; they are started here as well, since a mix
  task does not start the application.
  """

  @behaviour Temper.Push.HTTPClient

  @impl Temper.Push.HTTPClient
  def post(url, headers, body) do
    with :ok <- start([:inets, :ssl]),
         {:ok, ssl} <- ssl_options() do
      request(url, headers, body, ssl)
    end
  end

  defp request(url, headers, body, ssl) do
    {content_type, headers} = pop_content_type(headers)
    request = {String.to_charlist(url), Enum.map(headers, &charlist_header/1), content_type, body}

    http_options = [
      timeout: :timer.minutes(2),
      connect_timeout: :timer.seconds(15),
      autoredirect: false,
      ssl: ssl
    ]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:could_not_start, app, reason}}}
      end
    end)
  end

  # cacerts_get/0 raises when the system has no CA store to read.
  defp ssl_options do
    {:ok,
     [
       verify: :verify_peer,
       cacerts: :public_key.cacerts_get(),
       customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
       depth: 3
     ]}
  rescue
    _no_ca_store -> {:error, :no_system_ca_certificates}
  end

  # :httpc takes the content type apart from the other headers.
  defp pop_content_type(headers) do
    case List.keytake(headers, "content-type", 0) do
      {{_name, value}, rest} -> {String.to_charlist(value), rest}
      nil -> {~c"application/octet-stream", headers}
    end
  end

  defp charlist_header({name, value}), do: {String.to_charlist(name), String.to_charlist(value)}
end
