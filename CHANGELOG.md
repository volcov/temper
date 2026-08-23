# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
