# Temper

> Flaky tests are brittle tests. Temper finds them.

Temper records every ExUnit test outcome to a local history file and
reports tests with divergent outcomes on the same git SHA — the ones
that pass *and* fail without the code changing. No retries, no magic:
just evidence you can act on.

A test that fails intermittently is telling you something — about a race
condition, a shared state leak, a timing assumption. Retrying it into
silence hides the message. ([Here are eight common causes.][appsignal])
Temper's job is to make the message visible: which tests flake, how
often, and under which seeds, so you can fix the brittleness instead of
ignoring it.

## Requirements

Elixir 1.15+ on OTP 25+ (CI covers 1.15 through 1.20). No runtime
dependencies beyond [Jason](https://hex.pm/packages/jason).

## Quickstart

> ⚠️ Temper is under active development and not yet published to hex.
> The instructions below describe the upcoming v0.1 release.

```elixir
# mix.exs
def deps do
  [
    {:temper, "~> 0.1", only: :test}
  ]
end
```

```elixir
# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
```

Run your tests as usual — Temper appends each outcome to
`.temper/history-*.jsonl`. Then ask for the report:

```
$ mix temper.report
Flaky tests (divergent outcomes on same git SHA):

  MyApp.UserTest test creates user with valid attrs
    test/my_app/user_test.exs:42  async: true
    12 runs on a1b2c3d: 10 passed / 2 failed (16.7% flake rate)
    failing seeds: 493821, 110394
```

## What v0.1 does — and doesn't

- **Does:** record outcomes, detect same-SHA divergence, report with
  run counts, flake rates and failing seeds.
- **Doesn't:** retry, quarantine, or block CI. Detection first; trust
  before automation.

## License

Temper is released under the [MIT License](LICENSE).

[appsignal]: https://blog.appsignal.com/2021/12/21/eight-common-causes-of-flaky-tests-in-elixir.html
