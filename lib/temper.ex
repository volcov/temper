defmodule Temper do
  @moduledoc """
  Flaky-test detection for ExUnit.

  Temper records every test outcome to a local history file and
  reports tests with divergent outcomes on the same git SHA — tests
  that passed *and* failed without the code changing.

  ## Setup

  Add the formatter next to the default one:

      # test/test_helper.exs
      ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])

  Run your suite as usual, then ask for the verdict:

      $ mix temper.report

  ## How it fits together

  Recording — every `mix test` run:

    * `Temper.Formatter` — ExUnit formatter, the entry point
    * `Temper.Env` → `Temper.RunContext` — where and how the suite ran
      (git SHA, dirty flag, CI provider, seed, partition)
    * `Temper.Record` — one test outcome, with a failure signature
    * `Temper.History.Codec` / `Temper.History.Writer` — JSONL
      persistence to `.temper/history-{partition}.jsonl`

  Reporting — `mix temper.report`:

    * `Temper.History.Reader` — reads all partitions, tolerates
      corruption
    * `Temper.Analysis` — classifies same-SHA divergence into flaky
      tests and lower-confidence suspects
    * `Temper.Report` — renders for humans or as JSON

  Temper never breaks a test run: on any internal error the formatter
  warns once and goes inert for the rest of the run.
  """
end
