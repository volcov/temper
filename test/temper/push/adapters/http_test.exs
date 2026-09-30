defmodule Temper.Push.Adapters.HTTPTest do
  # Reads and sets environment variables.
  use ExUnit.Case, async: false

  import Mox

  alias Temper.Push.Adapters.HTTP
  alias Temper.Push.HTTPClientMock

  setup :verify_on_exit!

  @batch %{body: "gzip", run_ids: ["a"], lines: 1, bytes: 10}
  @config [url: "https://example.com/ingest", token_env: "TEMPER_TEST_PUSH_TOKEN"]

  setup do
    for name <- ["TEMPER_TEST_PUSH_TOKEN", "TEMPER_PUSH_TOKEN"] do
      previous = System.get_env(name)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    System.put_env("TEMPER_TEST_PUSH_TOKEN", "  tok  ")
    :ok
  end

  test "posts the batch with the protocol headers and reads the answer" do
    expect(HTTPClientMock, :post, fn url, headers, body ->
      assert url == "https://example.com/ingest"
      assert body == "gzip"
      assert {"authorization", "Bearer tok"} in headers
      assert {"content-encoding", "gzip"} in headers
      assert {"content-type", "application/x-ndjson"} in headers

      {:ok, 200, ~s({"accepted_run_ids":["a","b",3],"runs_new":1,"note":"x","Bad Key":2})}
    end)

    # Only ids of this batch are recorded; only plain counter names shown.
    assert HTTP.push(@batch, @config) == {:ok, ["a"], %{"runs_new" => 1}}
  end

  test "plain http only to the local machine, unless allowed" do
    expect(HTTPClientMock, :post, 2, fn _url, _headers, _body ->
      {:ok, 200, ~s({"accepted_run_ids":[]})}
    end)

    assert {:ok, [], %{}} =
             HTTP.push(@batch, Keyword.put(@config, :url, "http://localhost:4000/i"))

    assert {:error, "Refusing to send the token over plain http to ci.example.com." <> _} =
             HTTP.push(@batch, Keyword.put(@config, :url, "http://ci.example.com/i"))

    config = Keyword.merge(@config, url: "http://ci.example.com/i", allow_http: true)
    assert {:ok, [], %{}} = HTTP.push(@batch, config)

    assert {:error, "The push url must be https" <> _} =
             HTTP.push(@batch, Keyword.put(@config, :url, "ftp://ci.example.com/i"))
  end

  test "server text is made safe for the CI log" do
    expect(HTTPClientMock, :post, fn _url, _headers, _body ->
      {:ok, 400,
       Jason.encode!(%{error: "bad\n::stop-commands::x\e[2K" <> String.duplicate("y", 500)})}
    end)

    assert {:error, "The upload was refused (400): " <> text} = HTTP.push(@batch, @config)
    refute text =~ "\n"
    refute text =~ "\e"
    assert String.length(text) == 300
  end

  test "credentials in the url never reach the log" do
    expect(HTTPClientMock, :post, fn _url, _headers, _body -> {:error, :timeout} end)
    config = Keyword.put(@config, :url, "https://user:pass@example.com/ingest")

    assert HTTP.push(@batch, config) ==
             {:error, "Could not reach https://example.com/ingest: :timeout"}
  end

  test "the destination key is the url and a digest of the token" do
    {url, digest} = HTTP.destination_key(@config)

    assert url == "https://example.com/ingest"
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    refute digest =~ "tok"

    System.put_env("TEMPER_TEST_PUSH_TOKEN", "another")
    refute HTTP.destination_key(@config) == {url, digest}

    System.delete_env("TEMPER_TEST_PUSH_TOKEN")
    assert HTTP.destination_key(@config) == {url, nil}
  end

  test "the token variable defaults to TEMPER_PUSH_TOKEN" do
    config = Keyword.delete(@config, :token_env)
    System.delete_env("TEMPER_PUSH_TOKEN")

    assert HTTP.push(@batch, config) ==
             {:error, "TEMPER_PUSH_TOKEN is not set, so nothing was pushed."}
  end

  test "a missing or blank token sends nothing" do
    System.put_env("TEMPER_TEST_PUSH_TOKEN", "  ")
    assert {:error, "TEMPER_TEST_PUSH_TOKEN is empty" <> _} = HTTP.push(@batch, @config)

    System.delete_env("TEMPER_TEST_PUSH_TOKEN")
    assert {:error, "TEMPER_TEST_PUSH_TOKEN is not set" <> _} = HTTP.push(@batch, @config)
  end

  test "without a url it says so" do
    assert {:error, "The HTTP push adapter needs a url" <> _} =
             HTTP.push(@batch, Keyword.delete(@config, :url))
  end

  test "a refusal carries the server's error, or the start of the body" do
    expect(HTTPClientMock, :post, fn _url, _headers, _body ->
      {:ok, 401, ~s({"error":"The upload token is not valid."})}
    end)

    assert HTTP.push(@batch, @config) ==
             {:error, "The upload was refused (401): The upload token is not valid."}

    expect(HTTPClientMock, :post, fn _url, _headers, _body ->
      {:ok, 502, "<html>Bad gateway</html>"}
    end)

    assert HTTP.push(@batch, @config) ==
             {:error, "The upload was refused (502): <html>Bad gateway</html>"}

    expect(HTTPClientMock, :post, fn _url, _headers, _body -> {:ok, 503, ""} end)
    assert HTTP.push(@batch, @config) == {:error, "The upload was refused (503): no details"}
  end

  test "a 2xx without accepted_run_ids is an error, so nothing is recorded" do
    expect(HTTPClientMock, :post, fn _url, _headers, _body -> {:ok, 200, "ok"} end)

    assert HTTP.push(@batch, @config) ==
             {:error, "The server answered 200 without accepted_run_ids."}
  end

  test "a transport failure names the url" do
    expect(HTTPClientMock, :post, fn _url, _headers, _body -> {:error, :econnrefused} end)

    assert HTTP.push(@batch, @config) ==
             {:error, "Could not reach https://example.com/ingest: :econnrefused"}
  end
end
