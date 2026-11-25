---
name: agentica-release
description: >-
  Cut an Agentica release end to end: the version bump PR, the tag, the
  release workflow, the notes, the Pages rebuild and the post-release checks.
  Use when asked to make, tag, publish or announce a release, a beta or a
  patch release (for example "release 0.5.0-beta.1"). Not for building or
  testing packages outside a release (release targets: references/ci.md of
  agentica-development).
---

# Agentica release

A release is one version bump PR, one annotated tag on its merge commit, one
GitHub release made by `.github/workflows/release.yml`, hand-written notes,
and a Pages rebuild, in order. A pushed tag publishes: stop and report if any
check before it fails.

## 0. Pick the version

- The version is SemVer with no `v` (`0.5.0`; `0.5.0-beta.1` for a
  pre-release).
- **Beta policy:** a release is a beta (`X.Y.Z-beta.N`) while a system lacks
  a feature that the others have (new VM features land on Linux first). Ask
  the owner if unsure.
- A tag containing `-` is published as a GitHub pre-release
  (`--prerelease` in the `publish` job).
- A patch (`X.Y.Z`, Z > 0) is built from the last tag of its line: §6.

## 1. Version bump PR

First, with the agentica lines frozen, run a docs pruning pass (the user-level
`documentation-pruning` skill over `docs/`, `site/content/`, `.agents/skills/`
and the root docs) and merge its PR: the site is built once per release tag from
that tag's tree (the theme's `tools/site_versions.py`), so a later pruning
shows only in `dev`.

Then make a worktree from `origin/master` (a patch: §6; never switch the main
checkout) on a branch such as `release/<version>`. Change only:

1. `VERSION`: the new version, one line.
2. `CHANGELOG.md`:
   - rename `## [Unreleased]` to `## [<version>] - <YYYY-MM-DD>`, and trim
     its entries to one short line each, like the older sections;
   - put an empty `## [Unreleased]` above it;
   - fix the compare links at the bottom: `[unreleased]` compares
     `<version>...HEAD`, and add a line for the new version:

     ```text
     [<version>]: https://github.com/agentica-lang/agentica/compare/<previous>...<version>
     ```

   - Read the entries once: they must say what users see.
   - Leave each released section as its tag has it
     (`git show <tag>:CHANGELOG.md`).
3. `bootstrap/stage0.agcb`: refresh it before every release ("Refreshing
   stage0" (a) in `.agents/skills/agentica-development/references/ci.md`). CI
   rebuilds it from the base stage0 (`make stage0-check`) and must match.

Wrap every build in a memory cap (`agentica-dev-workflow` §1).

- The commit message, the PR title and the tag message are all
  `release version <version>`. The PR body lists the version, the date and the
  stage0 refresh.
- Take it to merge with `.agents/skills/agentica-dev-workflow/`. CI and
  Platforms (it runs by itself: the PR changes `VERSION` and stage0) must be
  green on its head. Also run `gh workflow run release.yml --ref
  release/<version>` on it and wait for green: only that run builds and smokes
  the five archives before the tag.

## 2. Tag and publish

Right after the PR merges, check the merge commit with `make release-package
release-smoke` (in a worktree of it, under a memory cap; two of the steps
`release.yml` runs on each system), then tag it (no master checkout needed):

```bash
git fetch origin
sha=$(gh pr view <N> --json mergeCommit -q .mergeCommit.oid)
git show "$sha:VERSION"   # must print <version>
git tag -a <version> -m "release version <version>" "$sha"
git push origin <version>
```

- The tag push starts `release.yml` (the job chain: "Release" in
  `.agents/skills/agentica-development/references/ci.md`); `publish` creates the
  release with empty notes.
- Watch it with `gh run list --workflow release.yml -L 3`, then
  `gh run watch <id>` in one background loop.
- If a job fails before `publish`, nothing is public yet. Read the log, fix it
  on master with a normal PR, then ask the owner before deleting and
  re-pushing the tag. Deleting a tag is outward-facing.
- `publish` creates a draft, then makes it public. If it fails in between, a
  draft release stays next to the pushed tag: check `gh release list`, and ask
  the owner before you edit or delete it.

## 3. Release notes

`publish` leaves the notes empty. Write them by hand, short: the key
user-visible points, the breaking changes, for a beta what is missing on which
system, and a link to the CHANGELOG section. Do not list PRs; details stay in
`CHANGELOG.md`.

```bash
gh release edit <version> --notes-file <file>
```

## 4. GitHub Pages

The site reads the version from `VERSION` (`make site` sets
`site.Params.version`; the `release` shortcode links to the tag). A change of
`VERSION` alone does not start `pages.yml` ("Deploy" in
`agentica-development/references/site.md`), so after publishing, rebuild the
site by hand:

```bash
gh workflow run pages.yml --ref master
```

This run also adds the new release to the version selector (it builds every
tag). Then check that the selector lists it, that the Install section shows the
new version and its release link opens the release.

## 5. Post-release checks

- The release page has the five archives (`agentica-<version>-<platform>`) and
  `SHA256SUMS`. A beta is Pre-release; a final release is Latest.
- Download one archive, check it against `SHA256SUMS`, and run
  `bin/agentica --version`: it prints `<version>`.
- CI and Pages on master are green.
- The Nix flake on `site/content/getting-started.md` and its Spanish page has
  the new `version` and its four `hash` values; if not, a docs PR. A `hash` is
  `sha256-` and the base64 of the archive's SHA-256 bytes: without `nix`,
  `echo HEX | xxd -r -p | base64` with HEX from `SHA256SUMS`.
- Report the release URL, the archives, the notes and anything skipped.

## 6. Patch releases

A patch (`X.Y.Z`, Z > 0): read `references/patch.md` (bug fixes only, a
`release/X.Y.x` branch from the last tag, cherry-picks, the forward-port).

## Gotchas

- Signing and notarization (Apple Developer ID, Windows Authenticode) are
  not set up; never claim them in the notes.
- A manual run of `release.yml` (`gh workflow run release.yml --ref <branch>`)
  only uploads artifacts. Use it to try a release change before tagging.
- Never tag a commit whose `VERSION` differs from the tag: the `version` job
  fails, and the tag must be removed (ask the owner first).
