---
name: agentica-release
description: >-
  Cut an Agentica release end to end: the version bump PR (VERSION, CHANGELOG,
  compare links, stage0 refresh), the annotated tag, the release workflow that
  publishes the five native archives, the hand-written release notes, the
  GitHub Pages rebuild and the post-release checks. Use when asked to make,
  tag, publish or announce a release, a beta or a patch release (for example
  "release 0.5.0-beta.1"). Not for building or testing packages locally (release
  targets: references/ci.md of agentica-development).
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

Make a worktree from `origin/master` (a patch: §6; never switch the main
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
3. `bootstrap/stage0.agcb`: refresh it before every release ("Refreshing
   stage0" (a) in `.agents/skills/agentica-development/references/ci.md`). CI
   rebuilds it from the base stage0 (`make stage0-check`) and must match.

Wrap every build in a memory cap (`agentica-dev-workflow` §1).

- The commit message, the PR title and the tag message are all
  `release version <version>`. The PR body lists the version, the date and the
  stage0 refresh.
- Label it `platforms` (Platforms runs on a PR only with that label), and
  take it to merge with `.agents/skills/agentica-dev-workflow/`. CI and
  Platforms must be green on its head.

## 2. Tag and publish

Right after the PR merges, tag its merge commit (no master checkout needed):

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
`site.Params.version`; the `release` shortcode links to the tag). But
`pages.yml` runs only on pushes touching `site/**`, the grammar docs, the
workflow or the `Makefile`, not `VERSION`. So after publishing, rebuild the
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
- Report the release URL, the archives, the notes and anything skipped.

## 6. Patch releases

A patch `X.Y.Z` (Z > 0) holds bug fixes only: no feature and no breaking
change, unless the owner approves a small compatible one. A fix for a flaky
test is not patch material, since it does not change the binary.

- **Milestones (owner's policy):** when `X.Y.0` is published, create the
  milestone `X.Y.1`. A bug that users see, or a regression of `X.Y`, gets the
  `bug` label and that milestone. Cut the patch at once for a serious bug or
  a regression; otherwise when about 3 to 5 fixes have merged.
- Each fix merges on master first, with a normal PR.
- **The branch:** the patch is built from the last tag of its line, not from
  master, which has unreleased features. Pushing a branch is outward-facing,
  as a tag is.

  ```bash
  git fetch origin --tags
  # the tag is annotated, so push the commit it points to
  git push origin 'X.Y.<Z-1>^{commit}:refs/heads/release-X.Y'
  git fetch origin --tags
  git worktree add -b release/X.Y.Z ../agentica-X.Y.Z origin/release-X.Y
  ```

  Take each fix as its merge commit on master:
  `git cherry-pick -x -m 1 <merge sha>` (PR branches hold merges of master,
  so a range of their commits does not pick cleanly). On a CHANGELOG
  conflict, keep only that fix's line. Never merge master into this
  branch: in §1 and in `agentica-dev-workflow`, read `origin/release-X.Y`
  wherever they say `origin/master`.
- **The PR:** that branch is the version bump PR, with base `release-X.Y`.
  §1 applies, with two changes. The CHANGELOG of the branch has an empty
  `[Unreleased]`: write one line per fix there first. The compare link is
  `X.Y.<Z-1>...X.Y.Z`. The stage0 refresh builds from the stage0 of
  `release-X.Y`, and CI and Platforms run on the PR as usual. Its body lists
  each fix with its master PR. Tag its merge commit (§2), then write the
  notes (§3). If a job fails before `publish`, the fix goes onto
  `release-X.Y` through a PR (a cherry-pick of the master fix), then the tag
  is pushed again with the owner's approval.
- **Latest:** `release.yml` creates the release with no `--latest` flag. In
  `gh release list`, Latest must be the highest version; if not, run
  `gh release edit <highest> --latest`.
- **Master:** forward-port in a small PR. Add `## [X.Y.Z] - <date>` in
  version order and its compare link. Move the entries of the fixes out of
  `[Unreleased]`, unless a release already lists them. When X.Y.Z is the
  highest version, also set `VERSION` to it, so the site's Install section
  shows it once `pages.yml` runs (§4), and make `[unreleased]` compare
  `X.Y.Z...HEAD`. Leave stage0 alone: the next master release refreshes it.
  For a patch of an older line, `VERSION` and `[unreleased]` stay.
- **Pages and checks:** after the master PR, follow §4 and §5. For a patch
  of an older line, the Install section keeps the newest release; check only
  that the version selector lists `X.Y.Z` and that its release page has the
  archives.
- After §5 passes, delete `release/X.Y.Z` and `release-X.Y` (the next patch
  makes `release-X.Y` again from the last tag), and create the milestone
  `X.Y.<Z+1>`.

## Gotchas

- Signing and notarization (Apple Developer ID, Windows Authenticode) are
  not set up; never claim them in the notes.
- A manual run of `release.yml` (`gh workflow run release.yml --ref <branch>`)
  only uploads artifacts. Use it to try a release change before tagging.
- Never tag a commit whose `VERSION` differs from the tag: the `version` job
  fails, and the tag must be removed (ask the owner first).
