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

Add `.temper/` to your `.gitignore`. Run your tests as usual — Temper
appends each outcome to `.temper/history-*.jsonl`. Once history
accumulates, ask for the report:

```
$ mix temper.report
Flaky tests (divergent outcomes on same git SHA):

  MyApp.UserTest test creates user with valid attrs
    test/my_app/user_test.exs:42  async: true
    12 runs on a1b2c3d: 10 passed / 2 failed (16.7% flake rate)
    failing seeds: 493821, 110394
```

`mix temper.report --json` emits the same data as a machine-readable
payload; `mix temper.clean` deletes the recorded history (useful after
a refactor that makes old evidence meaningless).

## How detection works

A test is **flaky** when it both passed and failed on the *same clean
git SHA* — the code did not change, the outcome did. Divergence that
only shows up in dirty-working-tree runs is reported separately as a
**suspect**: uncommitted changes could explain it, so confidence is
lower.

What deliberately does *not* count: a test that fails on one commit
and passes on the next (that's a fix, not a flake), runs outside a git
repository, and skipped/excluded tests. Temper optimizes for zero
false positives — a report you can trust over one that cries wolf.

`--min-runs N` (default 2) raises the number of recorded runs a SHA
needs before its divergence counts, trading detection speed for
confidence. The report always shows run counts so you can judge the
evidence yourself.

## Recording in CI

Temper detects CI (GitHub Actions, GitLab CI, CircleCI) and records
the provider, run id, and the commit under test automatically. Since
each CI job starts fresh, persist `.temper/` across runs to accumulate
history — for GitHub Actions:

```yaml
- name: Restore test history
  uses: actions/cache@v4
  with:
    path: .temper
    key: temper-${{ github.ref_name }}-${{ github.run_id }}
    restore-keys: |
      temper-${{ github.ref_name }}-
      temper-
```

The `run_id`-suffixed key makes every run save a fresh cache entry
while restoring the most recent previous one. Partitioned suites
(`MIX_TEST_PARTITION`) write one history file per partition, so
parallel jobs never clobber each other; `mix temper.report` reads them
all.

`mix temper.report` always exits 0 — it informs, it does not gate CI.

## Configuration

| Setting | Default | Purpose |
|---|---|---|
| `config :temper, history_path: "..."` | `.temper/history-{partition}.jsonl` | where history is written and read |
| `--history GLOB` (report/clean) | the setting above | one-off override |
| `--min-runs N` (report) | `2` | evidence threshold per SHA |
| `--json` (report) | off | machine-readable output |

## What v0.1 does — and doesn't

- **Does:** record outcomes, detect same-SHA divergence, report with
  run counts, flake rates and failing seeds.
- **Doesn't:** retry, quarantine, or block CI. Detection first; trust
  before automation.

If Temper itself ever hits an error, it warns once and goes inert for
the rest of the run — it will never break your test suite.

## License

Temper is released under the [MIT License](LICENSE).

[appsignal]: https://blog.appsignal.com/2021/12/21/eight-common-causes-of-flaky-tests-in-elixir.html
