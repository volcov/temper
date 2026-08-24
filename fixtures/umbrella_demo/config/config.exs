import Config

config :ex_unit, formatters: [ExUnit.CLIFormatter, Temper.Formatter]

config :temper,
  history_path:
    Path.expand(
      "../.temper/history-#{System.get_env("MIX_TEST_PARTITION") || "0"}.jsonl",
      __DIR__
    )
