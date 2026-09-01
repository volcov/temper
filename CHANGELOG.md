# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `mix temper.doctor` dates a partial SHA gap: the `recorded commit
  SHAs` warning now reports the newest null-SHA record's timestamp and
  whether the gap is still occurring or every record since carries a
  SHA — legacy noise and an active recording-blind path are
  distinguishable at a glance.

## [0.2.1] - 2026-08-25

### Added

- `{partition}` placeholder in `history_path`: the formatter expands
  it with the `MIX_TEST_PARTITION` value (`"0"` when unset) and
  `mix temper.report` / `mix temper.clean` widen it to `*` — custom
  paths are partition-safe by construction instead of by recipe.
- README FAQ answering the first real-world questions: whether Temper
  re-runs tests, cross-commit failures, what "Suspects" means, and
  why a first run reports nothing.
- `mix temper.doctor` — setup preflight diagnosing the silent failure
  modes: formatter not registered for the test env, `history_path`
  invisible outside the test env, umbrella child apps whose app-dir
  runs record nothing, empty history, and records without a usable
  commit SHA. Exits non-zero on problems so CI can gate setup on it.

## [0.2.0] - 2026-08-23

### Added

- `TEMPER_SHA`, `TEMPER_DIRTY` and `TEMPER_BRANCH` environment
  variables override git context detection — for containers and other
  environments where git cannot answer. A non-empty `TEMPER_SHA`
  activates manual mode and takes priority over CI variables and
  local git.
- `mix temper.report --by-app` groups findings by umbrella child app
  (derived from file paths), with per-app counts and involved files.
  JSON findings always carry the derived `"app"` field.

### Changed

- Recommended dependency line is now
  `only: [:dev, :test], runtime: false`, keeping `mix temper.report`
  available in the default env.
- Documented umbrella setup: root-only dependency, formatter
  registration via `config :ex_unit`, and a partition-safe shared
  history path — verified end-to-end on Elixir 1.15 through 1.20.

## [0.1.0] - 2026-08-22

### Added

- `Temper.Formatter` — ExUnit formatter recording every test outcome to
  `.temper/history-{partition}.jsonl`, with run context (git SHA, dirty
  flag, CI provider, seed, partition) and failure signatures.
  Crash-safe: on any internal error it warns once and goes inert.
- `mix temper.report` — flaky tests (divergent outcomes on the same
  clean git SHA) sorted by flake rate, plus lower-confidence suspects
  from dirty-tree runs. Options: `--json`, `--min-runs`, `--history`.
- `mix temper.clean` — deletes recorded history.
- History schema v1: append-only JSONL, one denormalized line per test
  outcome, partition-safe for parallel CI jobs.
