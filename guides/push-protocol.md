# Push Protocol

`mix temper.push` sends recorded history out of CI to a system that
collects it across runs. Temper does not pick that system: you configure
a destination, and nothing is sent until you do.

A destination is a `Temper.Push.Adapter`. Temper ships one,
`Temper.Push.Adapters.HTTP`, which speaks the open HTTP protocol below,
so any server that implements it can receive history.
[Sinter](https://sinterlab.dev) is one such server, available as a
preset. For anything else, write your own adapter.

## Configuring a destination

In `config/config.exs` (mix tasks do not read `config/runtime.exs`):

```elixir
# Sinter: the HTTP adapter, sinterlab.dev, token from SINTER_TOKEN
config :temper, :push, preset: :sinter

# Any server speaking the protocol below
config :temper, :push,
  adapter: Temper.Push.Adapters.HTTP,
  url: "https://ci-history.example.com/ingest",
  token_env: "CI_HISTORY_TOKEN"
```

Sinter is in private alpha: invites go out in small batches, from the
waitlist at [sinterlab.dev](https://sinterlab.dev). The upload token for
a repository comes from its page there.

`--preset NAME` and `--url URL` on the command line win over the config,
which helps try a destination without editing it:

```
$ SINTER_TOKEN=... mix temper.push --preset sinter --dry-run
```

Tokens are read from environment variables only, never from config or
flags, so they stay out of files and shell history. The HTTP adapter
only sends them over `https`, or plain `http` to the local machine
(`allow_http: true` lifts that for a trusted network).

`max_batch_bytes` (default 32 MB, uncompressed) sets the largest batch,
for a destination that accepts less per request. `:httpc` ignores
`HTTP_PROXY` and `HTTPS_PROXY`: behind a proxy, send the files with
curl (see below) or write an adapter.

## What the task sends

The history lines of every run the destination has not acknowledged
yet, as recorded (schema v1, see the
[History Schema guide](history-schema.md)), with three exceptions:

- blank lines and exact duplicate lines are dropped;
- corrupt lines (unreadable JSON, such as a truncated cache tail) are
  dropped;
- with `--scrub-messages`, every failed test's `failure.message` is
  removed (the failure `kind` and `hash` stay). Other lines go out byte
  for byte. Test names, file paths, branch names and commit shas still
  go: scrubbing covers messages, the part most likely to hold data from
  the tests themselves.

The lines are grouped into batches of whole runs, each at most 32 MB
uncompressed, and sent one batch at a time. The run ids a destination
accepts are appended to `pushed-runs` next to the history files, and
left out of the next push. `--all` ignores that file.

## The HTTP protocol

One request per batch:

```
POST <url>
Authorization: Bearer <token>
Content-Encoding: gzip
Content-Type: application/x-ndjson

<gzip of the batch's lines, each ending in a newline>
```

A batch holds every line of each run it carries, in file order. Lines of
one run never span two batches. Receivers should accept at least 32 MB
uncompressed, and should cap what they inflate: a small gzip body can
expand a lot.

Without Temper's task (any language, any CI), the same request is:

```
cat .temper/history-*.jsonl | gzip | curl --fail-with-body \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Encoding: gzip" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @- https://ci-history.example.com/ingest
```

It sends everything every time (no `pushed-runs`), which a receiver
applying each run once handles, and needs a receiver that accepts the
whole history in one request.

### A successful answer

Any `2xx` status with a JSON object holding `accepted_run_ids`:

```json
{
  "accepted_run_ids": ["5d0b7e2c9a1f4e3b8c6d2a0f1e9b7c35"],
  "runs_new": 1,
  "runs_known": 0
}
```

`accepted_run_ids` lists every run of the batch the receiver now holds,
whether it was new or already known. Those runs are not sent again, so a
receiver should only list runs it has stored; ids that were not in the
batch are ignored. Other integer fields with lowercase names (`a-z`,
digits, `_`) are optional counters; the task prints them after the
push. The ones it
words in its summary are `runs_new`, `runs_known`, `runs_without_sha`,
`lines_skipped` and `failures_truncated`; any other is listed by name.

A receiver should apply each run once: a run is identified by its
`run_id` (random per suite run), and the same run may arrive again
whenever `pushed-runs` is lost with a CI cache or `--all` is used.

### A refusal

Any other status. An optional JSON body `{"error": "..."}` is shown in
the CI log, so make it readable; without one, the start of the body is
shown. Either way, control characters are removed and the text is cut
at 300 characters. Nothing from a refused batch is recorded,
so the next push sends it again.

A refused push warns and exits 0: it never fails a green build unless
the task runs with `--strict`.

## Writing an adapter

An adapter is a module with one callback, `push/2`, which gets a batch
and the `config :temper, :push` keyword list:

```elixir
defmodule MyApp.TemperToS3 do
  @behaviour Temper.Push.Adapter

  @impl true
  def push(batch, config) do
    key = "temper/" <> Base.encode16(:crypto.hash(:sha256, batch.body), case: :lower)

    case MyApp.S3.put(config[:bucket], key, batch.body) do
      :ok -> {:ok, batch.run_ids, %{}}
      {:error, reason} -> {:error, "Could not store history: #{inspect(reason)}"}
    end
  end
end
```

```elixir
config :temper, :push, adapter: MyApp.TemperToS3, bucket: "ci-history"
```

`batch.body` is the gzip compressed lines, `batch.run_ids` the runs it
carries, `batch.lines` and `batch.bytes` its size. Return the run ids
the destination now holds (they are recorded and not sent again) and a
map of integer counters to print (string keys), or
`{:error, message}` for the CI log. An adapter that raises is reported
as a failed push, like an error.
