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

```elixir
# mix.exs
def deps do
  [
    {:temper, "~> 0.3", only: [:dev, :test], runtime: false}
  ]
end
```

(`only: [:dev, :test]` — not just `:test` — keeps `mix temper.report`
available in your default env; `runtime: false` keeps Temper out of
releases and never starts it as an application.)

```elixir
# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, Temper.Formatter])
```

Add `.temper/` to your `.gitignore`. Run your tests as usual — Temper
appends each outcome to `.temper/history-*.jsonl`, one self-contained
JSON object per line (the format is a documented contract: see the
[History Schema guide](guides/history-schema.md)). Once history
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

## FAQ

**Does Temper re-run my tests?** No. Temper is a passive formatter —
it adds zero test time. Every normal `mix test` run is one
observation, and evidence accumulates across the runs you were
already doing. (`--min-runs` is an evidence filter applied at report
time, not a runner setting.)

**Does it catch a test that passes on one commit and fails on the
next?** No, by design: across commits there is no way to tell a flake
from a change that broke — or fixed — the test. Detection is
same-SHA-only, each commit building its own evidence bucket, trading
some recall for zero false positives (see
[How detection works](#how-detection-works)). A planned opt-in retry
mode will close the recall gap.

**Why is my finding under "Suspects"?** Its divergence involves runs
from a dirty working tree — uncommitted changes could explain the
differing outcomes, so confidence is lower. Divergence on clean,
committed SHAs reports as flaky with full confidence.

**Why does the report say nothing after one run?** One observation
per test can never diverge — the earliest a flake can surface is the
second run on the same SHA. Keep running your tests; the evidence
builds itself. Still nothing after several runs? `mix temper.doctor`
checks the setup for the failure modes that stay silent.

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
while restoring the most recent previous one.

**Parallel test jobs** need one cache lineage per partition — cache
keys are immutable, so parallel jobs saving the same key would keep
only the first job's history. Add the partition to the key:

```yaml
    key: temper-${{ github.ref_name }}-${{ matrix.partition }}-${{ github.run_id }}
    restore-keys: |
      temper-${{ github.ref_name }}-${{ matrix.partition }}-
```

Partitioned suites (`MIX_TEST_PARTITION`) write one history file per
partition, so the files never collide — to report across all
partitions, restore each partition's cache into `.temper/` (one
`actions/cache` step per partition, or download the partitions as
artifacts and `mix temper.merge` them) and run `mix temper.report`;
it reads every `history-*.jsonl` it finds.

Recipes for GitLab CI and CircleCI, the artifact
download-and-merge flow for inspecting history locally, and keeping
a cached history bounded with `mix temper.clean` are collected in
the [CI Recipes guide](guides/ci-recipes.md).

`mix temper.report` always exits 0 — it informs, it does not gate CI.

## Umbrella projects

Three lines cover the whole umbrella — no per-app edits:

```elixir
# mix.exs (umbrella root)
{:temper, "~> 0.3", only: [:dev, :test], runtime: false}

# config/test.exs — registers the formatter for every child app;
# ExUnit.start/1 reads persisted :ex_unit config, so test_helper.exs
# files stay untouched (an explicit formatters: option passed to
# ExUnit.start in a child app would override this)
config :ex_unit, formatters: [ExUnit.CLIFormatter, Temper.Formatter]

# config/config.exs — NOT test.exs: mix temper.report runs in the dev
# env and must resolve the same path the test-env formatter writes to.
# Child apps run tests with their own directory as cwd, so pin the
# history at the umbrella root. {partition} keeps one file per
# partition, since concurrent partitioned jobs must never share a file.
config :temper,
  history_path: Path.expand("../.temper/history-{partition}.jsonl", __DIR__)
```

The root-only dependency works because umbrella apps share one
`_build`, keeping the formatter loadable during every child's test run
(verified on Elixir 1.15 through 1.20). If a future Elixir prunes
child load paths harder, the always-correct fallback is declaring the
dependency in each child app instead — everything else stays the same.

Within one `mix test` invocation the child suites run sequentially in
a single VM, so sharing a partition's file is safe. Partitioned jobs
each write their own file, exactly like the default layout — and
`mix temper.report` widens `{partition}` to `*`, reading every
partition's file with no extra flags.

**Run tests from the umbrella root.** With the root-only dependency,
a suite started from *inside* a child directory (`cd apps/foo &&
mix test`) cannot load the formatter — the run succeeds but records
**nothing, silently** (`mix temper.doctor` warns about exactly this).
Running from the root always records, including targeted runs:
`mix test apps/foo/test` works. If your team habitually
runs tests from child directories, use the per-app fallback
(declare the dependency in each child's `mix.exs`) instead.

## Containers and environments without git

Detection needs a commit SHA on every record — without one, runs can
never be classified. If your tests run where git can't answer (a
container without the `.git` directory, a sandboxed build), pass the
context in from outside with the `TEMPER_*` variables:

```
docker run \
  -e TEMPER_SHA="$(git rev-parse HEAD)" \
  -e TEMPER_DIRTY="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
  -e TEMPER_BRANCH="$(git branch --show-current)" \
  ... mix test
```

A non-empty `TEMPER_SHA` switches git context to manual mode: it takes
priority over CI variables and local git. `TEMPER_DIRTY` accepts
`true`/`1`/`yes` (default `false` — only claim clean when the tree
really is); `TEMPER_BRANCH` is optional. You can spot the problem in a
report footer that never flags anything: check a history line for
`"sha":null`.

## Troubleshooting: mix temper.doctor

When the report stays empty and you suspect the setup rather than
your tests, run the preflight:

```
$ mix temper.doctor
  ✓ formatter registration — registered via config :ex_unit for the test env
  ✓ history_path — using the default .temper/history-{partition}.jsonl in every env
  ✓ recorded history — 132 test records in 2 files, last recorded at 2026-08-24T13:59:01Z
  ✓ recorded commit SHAs — all 132 records carry a commit SHA

All 4 checks passed.
```

It diagnoses the failure modes that are otherwise silent: a formatter
that never registered, a `history_path` set only for the test env
(invisible to the dev-env report task), umbrella child apps whose
app-dir runs cannot load the formatter, suites that recorded nothing,
and records without a usable commit SHA. The task exits non-zero when
a check finds a problem — warnings don't fail — so CI can gate setup
on it.

## Configuration

| Setting | Default | Purpose |
|---|---|---|
| `config :temper, history_path: "..."` | `.temper/history-{partition}.jsonl` | where history is written and read — set it in `config/config.exs`, not `test.exs`, so the dev-env `mix temper.report` sees it too. A literal `{partition}` expands to `MIX_TEST_PARTITION` when writing (`"0"` when unset) and widens to `*` when reading, keeping custom paths partition-safe |
| `--history GLOB` (report/clean/doctor) | the setting above | one-off override |
| `--min-runs N` (report) | `2` | evidence threshold per SHA |
| `--json` (report) | off | machine-readable output |

## What Temper does — and doesn't

- **Does:** record outcomes, detect same-SHA divergence, report with
  run counts, flake rates and failing seeds.
- **Doesn't:** retry, quarantine, or block CI. Detection first; trust
  before automation.

If Temper itself ever hits an error, it warns once and goes inert for
the rest of the run — it will never break your test suite.

## Status & feedback

Temper is young (pre-1.0) and the history schema, report format and
flags may still change before 1.0. It is in real use, but if anything
surprises you — a test wrongly flagged, one that should have been, a
crash, a confusing report — please
[open an issue](https://github.com/volcov/temper/issues). Early
feedback is what shapes what gets built next.

## License

Temper is released under the [MIT License](LICENSE).

[appsignal]: https://blog.appsignal.com/2021/12/21/eight-common-causes-of-flaky-tests-in-elixir.html
