# Dogfooding: Temper records its own suite to .temper/history-*.jsonl.
ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
