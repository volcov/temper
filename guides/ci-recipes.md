# CI Recipes

The README covers the GitHub Actions cache recipe. This guide
collects the rest of the CI story: persistence recipes for GitLab CI
and CircleCI, the artifact flow for getting history onto your
machine, and keeping a cached history bounded.

The shape is the same everywhere: each CI job starts fresh, so
persist `.temper/` across runs to accumulate history. What differs
per provider is cache semantics: GitHub Actions and CircleCI cache
entries are immutable (save under an always-fresh key, restore by
prefix), while GitLab updates a mutable key in place.

## GitLab CI

A per-branch key is enough, since the job updates the same cache
entry when it ends. `fallback_keys` seeds new branches from the
default branch's history:

```yaml
test:
  script:
    - mix test
  cache:
    key: temper-$CI_COMMIT_REF_SLUG
    fallback_keys:
      - temper-$CI_DEFAULT_BRANCH
    paths:
      - .temper/
```

For `parallel:` jobs, give each node its own cache lineage and its
own history partition:

```yaml
  parallel: 3
  variables:
    MIX_TEST_PARTITION: $CI_NODE_INDEX
  cache:
    key: temper-$CI_COMMIT_REF_SLUG-$CI_NODE_INDEX
    fallback_keys:
      - temper-$CI_DEFAULT_BRANCH-$CI_NODE_INDEX
    paths:
      - .temper/
```

Depending on runner configuration, GitLab caches can be runner-local:
when runners do not share cache storage, history accumulates per
runner and flakes take longer to surface. The artifact flow below
does not have this problem.

## CircleCI

Cache entries are immutable, like GitHub's: save under an
always-fresh key (`epoch` keeps it unique), restore the most recent
one by prefix:

```yaml
- restore_cache:
    keys:
      - temper-{{ .Branch }}-
      - temper-
- run: mix test
- save_cache:
    key: temper-{{ .Branch }}-{{ epoch }}
    paths:
      - .temper
```

With `parallelism`, add `{{ .Environment.CIRCLE_NODE_INDEX }}` to
both keys and set `MIX_TEST_PARTITION` from `CIRCLE_NODE_INDEX`, so
each node keeps its own cache lineage and history partition.

## Getting the history into your hands

Caches keep history between runs, but they are best-effort (entries
expire, a miss silently resets history) and you cannot browse them.
For a history that is durable and inspectable, also upload `.temper/`
as a build artifact — GitHub Actions:

```yaml
- name: Upload test history
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: temper-${{ matrix.partition }}
    path: .temper/
```

On GitLab, add `.temper/` under `artifacts:paths`; on CircleCI, use
`store_artifacts`.

Download the artifacts (from one run or several), then merge them
into one deduplicated file and report on it:

```
$ mix temper.merge --output .temper/history-0.jsonl "artifacts/**/history-*.jsonl"
$ mix temper.report
```

Overlapping cache restores and re-downloaded artifacts duplicate
lines; `mix temper.merge` writes each recorded event once. The file
format itself is a documented contract (see the
[History Schema guide](history-schema.md)), so the merged file is
also plain material for your own
scripts: it is JSON Lines, one test outcome per line.

## Keeping cached history bounded

A cached `.temper/` grows on every run. Prune it in CI before the
cache is saved, or occasionally from your machine:

```
$ mix temper.clean --older-than 90
$ mix temper.clean --keep-shas 50
```

`--older-than` keeps the last N days of records, `--keep-shas` the
records of the N most recently recorded commits; given together, a
record must satisfy both to survive. Pruning rewrites files in
place, so the cache saved afterwards carries the trimmed history
forward.
