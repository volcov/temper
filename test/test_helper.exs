# Dogfooding: Temper records its own suite to .temper/history-*.jsonl.
ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])

# mix temper.push talks to other systems only through these behaviours.
Mox.defmock(Temper.Push.AdapterMock, for: Temper.Push.Adapter)
Mox.defmock(Temper.Push.HTTPClientMock, for: Temper.Push.HTTPClient)
Application.put_env(:temper, :push_http_client, Temper.Push.HTTPClientMock)
