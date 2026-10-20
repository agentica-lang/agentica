---
name: agentica-release
description: Cut an Agentica release end to end. Covers the version bump PR (VERSION, CHANGELOG, compare links, stage0 refresh), the annotated tag, the release workflow that publishes the four native archives, the hand-written GitHub release notes, the GitHub Pages rebuild, and the post-release checks. Use when asked to make, tag, publish or announce a release or beta (for example "release 0.5.0-beta.1"). Not for building or testing packages locally without releasing (see the release targets in references/ci.md of agentica-development).
---

# Agentica release

A release is one version bump PR, one annotated tag on its merge commit, one
GitHub release made by `.github/workflows/release.yml`, hand-written notes,
and a Pages rebuild. Do the steps in order. A pushed tag publishes, so stop
and report if any check before it fails.

## 0. Pick the version

- The version is SemVer with no `v`: `0.5.0`, or `0.5.0-beta.1` for a
  pre-release.
- **Beta policy (owner, 2026-10-20):** every release is a beta
  (`X.Y.Z-beta.N`) while Windows lacks a feature that Linux and macOS have
  (`site/content/vm.md` lists what Windows runs). The first release without a
  suffix comes when Windows matches them. Ask the owner if unsure.
- A tag containing `-` is published as a GitHub pre-release
  (`--prerelease` in the `publish` job).
- The previous version is in `VERSION`, and `git tag --sort=-creatordate`
  lists the tags.

## 1. Version bump PR

Make a worktree from `origin/master` (never switch the main checkout), on a
branch such as `release/<version>`. Change only:

1. `VERSION`: the new version, one line.
2. `CHANGELOG.md`:
   - rename `## [Unreleased]` to `## [<version>] - <YYYY-MM-DD>`, and trim
     its entries to one short line each, like the older sections;
   - put an empty `## [Unreleased]` above it;
   - fix the compare links at the bottom: `[unreleased]` compares
     `<version>...HEAD`, and add a line for the new version:

     ```text
     [<version>]: https://github.com/sonic182/agentica/compare/<previous>...<version>
     ```

   - Read the entries once: they must say what users see. Mark a breaking
     change `**Breaking:**`.
3. `bootstrap/stage0.agcb`: refresh it before every release. Run
   `make fixed-point stage0`, check that the diff is only that one binary
   file, run `make` again (it must build from the new stage0), and commit it.
   If the old stage0 cannot compile `compiler/`, follow "Refreshing stage0" in
   `.agents/skills/agentica-development/references/ci.md`.

Wrap every build in
`systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 -- <cmd>`.

- The commit message is `release version <version>`.
- The PR title is the same. Its body lists the version, the date and the
  stage0 refresh.
- Label it `platforms` (Platforms runs on a PR only with that label), and
  take it to merge with `.agents/skills/agentica-dev-workflow/`. CI and
  Platforms must be green on its head.

## 2. Tag and publish

Right away after the PR merges, tag its merge commit. You do not need a
checkout of master:

```bash
git fetch origin
sha=$(gh pr view <N> --json mergeCommit -q .mergeCommit.oid)
git show "$sha:VERSION"   # must print <version>
git tag -a <version> -m "release version <version>" "$sha"
git push origin <version>
```

- The tag push starts `release.yml`: it checks the tag against `VERSION`,
  builds, checks and smoke-tests the four archives, writes `SHA256SUMS`, and
  `publish` creates the release with empty notes. The job chain is described
  under "Release" in `.agents/skills/agentica-development/references/ci.md`.
- Watch the run with one background loop:
  `gh run list --workflow release.yml -L 3`, then `gh run watch <id>`.
- If a job fails before `publish`, nothing is public yet. Read the log, fix it
  on master with a normal PR, then ask the owner before you delete and re-push
  the tag. Deleting a tag is outward-facing.
- `publish` creates a draft, then makes it public. If it fails in between, a
  draft release stays next to the pushed tag: check `gh release list`, and ask
  the owner before you edit or delete it.

## 3. Release notes

`publish` leaves the notes empty. Write them by hand. Keep them short:

- the key user-visible points;
- the breaking changes;
- for a beta, what is missing on Windows;
- a link to the CHANGELOG section for the details.

Do not list PRs. The details stay in `CHANGELOG.md`.

```bash
gh release edit <version> --notes-file <file>
```

## 4. GitHub Pages

The site reads the version from `VERSION` (`make site` sets
`site.Params.version`; the `release` shortcode links to the tag). But
`pages.yml` runs only on pushes that touch `site/**`, the grammar docs, the
workflow or the `Makefile`, and not `VERSION`. So after the release is
published, rebuild the site by hand:

```bash
gh workflow run pages.yml --ref master
```

Then check that the Install section of the site shows the new version, and
that its release link opens the release.

## 5. Post-release checks

- The release page has the four archives (`linux-x86_64.tar.gz`,
  `macos-x86_64.tar.gz`, `macos-arm64.tar.gz`, `windows-x86_64.zip`, each
  `agentica-<version>-…`) and `SHA256SUMS`. A beta is marked Pre-release; a
  final release is Latest.
- Download one archive, check it against `SHA256SUMS`, and run
  `bin/agentica --version`: it prints `<version>`.
- CI and Pages on master are green.
- Report to the owner: the release URL, the archive list, the notes, and
  anything skipped.

## Gotchas

- Signing and notarization (Apple Developer ID, Windows Authenticode) are not
  set up. Never claim them in the notes.
- A manual run of `release.yml` (`gh workflow run release.yml --ref <branch>`)
  only uploads artifacts. Use it to try a release change before tagging.
- The tag message and the bump commit use the same text,
  `release version <version>`.
- Never tag a commit whose `VERSION` differs from the tag: the `version` job
  fails, and the tag must be removed (ask the owner first).
