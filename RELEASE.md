# Release checklist

Steps for publishing a Temper release to hex.pm.

## Before publishing

- [ ] CI green on `main` (all matrix pairs)
- [ ] `mix test` green locally, including the integration test
- [ ] CHANGELOG: move `[Unreleased]` entries under a new `## [X.Y.Z] - YYYY-MM-DD` heading
- [ ] `@version` bumped in `mix.exs` (SemVer)
- [ ] README quickstart matches the version being released; remove the
      "not yet published" warning on the first release
- [ ] `mix docs` builds without warnings; skim `doc/index.html`
- [ ] `mix hex.build` succeeds; inspect the file list it prints —
      nothing unexpected in, nothing needed out

## Publish

- [ ] `git tag vX.Y.Z && git push --tags`
- [ ] `mix hex.publish` (builds docs and publishes both package and
      hexdocs; review the summary carefully before confirming)
- [ ] Verify https://hex.pm/packages/temper and https://hexdocs.pm/temper
      render correctly

## After publishing

- [ ] Install from hex in a scratch project and run the quickstart
- [ ] GitHub release with the CHANGELOG section as notes
