# History Schema (v1)

Temper records test outcomes as [JSON Lines](https://jsonlines.org):
one self-contained JSON object per line, UTF-8 encoded, LF-terminated,
appended to `.temper/history-{partition}.jsonl` (see the README for
path configuration). This page documents line schema version 1 as a
public contract, so that anything reading or writing these files
(your own scripts, CI tooling, an aggregation service) can rely on
it without reverse-engineering Temper's codec.

The contract is versioned rather than frozen: within schema 1 the
format only ever changes additively, and any breaking change arrives
as a new `schema` number, which version-1 consumers already know to
skip. The "Versioning" section at the end spells out the rules.

## The envelope

Every line carries two envelope fields, and consumers dispatch on
both:

| Field    | Type    | Meaning                                        |
| -------- | ------- | ---------------------------------------------- |
| `schema` | integer | line format version; this document describes 1 |
| `kind`   | string  | what the line records: `"test"` or `"suite"`   |

## Test lines (`kind: "test"`)

One line per finished test. The run context is denormalized into
every line, so a single line answers where, when, and on what code a
test produced its outcome, with no joins:

```json
{"schema":1,"kind":"test","run_id":"a490cc5edf1e9800b2ca76f59439dba6",
 "at":"2026-08-22T22:54:58Z","sha":"fe892caba20e2ee0a22e2b13d64c17504f91db61",
 "dirty":true,"branch":"feature/formatter-writer","ci":null,"seed":944754,
 "partition":null,"elixir":"1.20.2","otp":"27",
 "module":"Temper.RunContextTest",
 "name":"test new/1 with a full map keeps every gathered value",
 "file":"/home/dev/app/test/temper/run_context_test.exs","line":16,
 "async":true,"test_type":"test","status":"passed","time_us":4,
 "failure":null}
```

(Line broken here for readability; on disk it is a single line.)

Required fields are always present and never null. Optional fields
are written as explicit `null` when unknown, but consumers should
treat an absent key and a `null` value the same way.

### Run context (identical on every line of one run)

| Field       | Type            | Required | Meaning                                                                                       |
| ----------- | --------------- | -------- | --------------------------------------------------------------------------------------------- |
| `run_id`    | string          | yes      | 32 lowercase hex characters, random per suite run; groups every line written by one run       |
| `at`        | string          | yes      | when the run started: ISO 8601 UTC, second precision, `Z` suffix (`2026-08-22T22:54:58Z`)     |
| `sha`       | string \| null  | no       | commit under test; `null` when git cannot answer and no `TEMPER_SHA` was provided             |
| `dirty`     | boolean         | no       | whether the working tree had uncommitted changes; a missing value reads as `false`            |
| `branch`    | string \| null  | no       | git branch, when known                                                                        |
| `ci`        | object \| null  | no       | `{"provider": string, "run_id": string \| null}`; `null` outside CI                           |
| `seed`      | integer \| null | no       | the ExUnit seed for this run (non-negative)                                                   |
| `partition` | string \| null  | no       | `MIX_TEST_PARTITION` value; `null` when unset                                                 |
| `elixir`    | string          | yes      | Elixir version the suite ran on                                                               |
| `otp`       | string          | yes      | OTP major version the suite ran on                                                            |

### Test outcome

| Field       | Type            | Required | Meaning                                                                           |
| ----------- | --------------- | -------- | --------------------------------------------------------------------------------- |
| `module`    | string          | yes      | test module, as printed by Elixir (`MyApp.UserTest`)                              |
| `name`      | string          | yes      | full test name, including the `test ` prefix ExUnit generates                     |
| `status`    | string          | yes      | one of `passed`, `failed`, `skipped`, `excluded`, `invalid`                       |
| `file`      | string \| null  | no       | source file of the test                                                           |
| `line`      | integer \| null | no       | line of the test (positive)                                                       |
| `async`     | boolean \| null | no       | whether the test module ran async                                                 |
| `test_type` | string \| null  | no       | ExUnit's test type (`test`, `doctest`, ...)                                       |
| `time_us`   | integer \| null | no       | measured runtime in microseconds; `null` for tests that never ran (e.g. excluded) |
| `failure`   | object \| null  | no       | failure signature, present only when `status` is `failed` (see below)             |

The pair `(module, name)` identifies a test across runs; everything
else about a test may change from run to run.

### The failure signature

For failed tests, `failure` is:

| Field     | Type   | Meaning                                                                                 |
| --------- | ------ | --------------------------------------------------------------------------------------- |
| `kind`    | string | the exception module (`ExUnit.AssertionError`), or the raw kind for non-error exits     |
| `message` | string | the failure message, truncated to 500 characters                                        |
| `hash`    | string | lowercase hex of the first 4 bytes of the SHA-256 of the full, untruncated message      |

The hash exists so equal failures group together even when
truncation hides the differing tail: group by `(kind, hash)` to
separate distinct failure modes of one flaky test.

## Suite lines (`kind: "suite"`)

One line at the end of each recorded run:

```json
{"schema":1,"kind":"suite","run_id":"a490cc5edf1e9800b2ca76f59439dba6",
 "at":"2026-08-22T22:54:58Z","tests":66,
 "times_us":{"async":60478,"run":434307,"load":null}}
```

| Field      | Type            | Meaning                                                                                 |
| ---------- | --------------- | --------------------------------------------------------------------------------------- |
| `run_id`   | string          | same value as the run's test lines                                                      |
| `at`       | string          | same value as the run's test lines                                                      |
| `tests`    | integer         | how many test lines the run recorded                                                    |
| `times_us` | object \| null  | ExUnit's suite timing (`run`, `async`, `load` in microseconds; each member may be null) |

A run's suite line is the signal that the run completed; test lines
without one may come from an interrupted run.

## Rules for consumers

- Never fail a whole file over one line. Skip what you cannot
  decode, and count skips if you report.
- Dispatch on `schema` and `kind`; silently skip unknown values of
  either. New kinds may appear within schema 1.
- Ignore unknown keys on known kinds: schema 1 grows additively.
- Parse timestamps instead of comparing them as strings. Temper
  emits second-truncated UTC `Z` timestamps, but other producers may
  legally emit fractional seconds or numeric offsets, which misorder
  under string comparison.
- A tool that rewrites files must never drop a line merely because
  it cannot interpret it; only positively corrupt lines (unreadable
  JSON) may always be dropped. Compaction (`mix temper.merge`)
  preserves every non-corrupt line verbatim. Retention
  (`mix temper.clean --older-than` / `--keep-shas`) reads `at` and
  `sha` generically from every line, unknown schemas and kinds
  included, and drops exactly the lines it can positively match
  against the requested window: an old suite summary or
  future-format line ages out like any other, while a line whose
  relevant field cannot be read survives.
- Byte-identical lines describe the same recorded event (they can
  only arise from copying, such as overlapping CI cache restores)
  and are safe to deduplicate. `mix temper.merge` does exactly that.

## Rules for producers

- One JSON object per line, UTF-8, LF-terminated, appended only.
- Stamp `schema` and `kind` on every line.
- Make every line self-contained: full run context, no references to
  other lines except `run_id` grouping.
- Generate `run_id` as 32 lowercase hex characters, fresh per run;
  never reuse one across runs.
- Emit `at` as second-truncated UTC with a `Z` suffix.
- Write required fields always; write optional fields as explicit
  `null` rather than inventing placeholder values.

## Versioning

- `schema` increments only on breaking changes: a removed or
  retyped field, or changed field semantics.
- Adding optional fields or new `kind` values is not a version bump;
  the consumer rules above already absorb both.
- Version-1 consumers skip lines with any other `schema` value, so
  mixed-version files degrade gracefully: each consumer reads the
  lines it understands.
