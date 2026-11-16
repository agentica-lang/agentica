# Patch releases

A patch `X.Y.Z` (Z > 0) holds bug fixes only: no feature and no breaking
change, unless the owner approves a small compatible one. A fix for a flaky
test is not patch material, since it does not change the binary.

- **Milestones (owner's policy):** when `X.Y.0` is published, create the
  milestone `X.Y.1`. A bug that users see, or a regression of `X.Y`, gets the
  `bug` label and that milestone. Cut the patch at once for a serious bug or
  a regression; otherwise when about 3 to 5 fixes have merged.
- Each fix merges on master first, with a normal PR.
- **The branch (patch from a release branch):** the patch is built from the
  last tag of its line, not from master, which has unreleased features.
  Pushing a branch is outward-facing, as a tag is. The base branch holds the
  tag alone; the PR branch holds the fixes and the bump.

  ```bash
  git fetch origin --tags
  git worktree add ../agentica-wt-XYZ -b release/X.Y.x X.Y.<Z-1>
  git push origin release/X.Y.x          # the base of the PR, nothing else
  git -C ../agentica-wt-XYZ checkout -b release/X.Y.Z
  git -C ../agentica-wt-XYZ -c protocol.file.allow=always \
    submodule update --init
  ```

- **The fixes:** in merge order, cherry-pick the PR's own commits
  (`gh pr view N --json commits`) with `git cherry-pick -x <sha>`, and skip
  the merges of master into its branch. On a conflict with code that exists
  only after the tag, keep the tag's code and drop the lines of the newer
  feature; a reference file that the tag does not have yet takes the edit in
  its older home. On a CHANGELOG conflict, keep only that fix's line, under
  `### Fixed`. Anything more than that: stop and ask the owner. Regenerate the
  goldens and the frozen manifests on the branch (`make goldens`,
  `python3 tools/refreeze.py`); never copy master's. Never merge master into
  this branch: in SKILL.md §1 and in `agentica-dev-workflow`, read
  `origin/release/X.Y.x` wherever they say `origin/master`.
- **The PR:** `release/X.Y.Z` is the version bump PR, with base `release/X.Y.x`.
  SKILL.md §1 applies, with two changes. Rename `[Unreleased]` (which holds
  only the fix lines) to the new version, and the compare link is
  `X.Y.<Z-1>...X.Y.Z`. The stage0 refresh builds from the stage0 of the tag;
  check it with `make stage0-check BASE_STAGE0=<that stage0>`. CI and Platforms
  run on the PR as usual (their `pull_request` trigger has no branch filter).
  Run the tests of the touched areas, `make vm-test`, and `make vm-tsan` for
  shared-state C. Its body lists each fix with its master PR and what the
  conflicts dropped. Tag its merge commit into `release/X.Y.x` (SKILL.md §2:
  `release.yml` runs on any tag `X.Y.Z`, whatever its branch), then write the
  notes (SKILL.md §3). If a job fails before `publish`, the fix goes onto
  `release/X.Y.x` through a PR, then the tag is pushed again with the owner's
  approval.
- **Latest:** `release.yml` creates the release with no `--latest` flag. In
  `gh release list`, Latest must be the highest version; if not, run
  `gh release edit <highest> --latest`.
- **Master:** forward-port in a small PR. Add `## [X.Y.Z] - <date>` in
  version order and its compare link. Move the entries of the fixes out of
  `[Unreleased]`, unless a release already lists them. When X.Y.Z is the
  highest version, also set `VERSION` to it, so the site's Install section
  shows it once `pages.yml` runs (SKILL.md §4), and make `[unreleased]` compare
  `X.Y.Z...HEAD`. Leave stage0 alone: the next master release refreshes it.
  For a patch of an older line, `VERSION` and `[unreleased]` stay.
- **Pages and checks:** after the master PR, follow SKILL.md §4 and §5. For a
  patch of an older line, the Install section keeps the newest release; check
  only that the version selector lists `X.Y.Z` and that its release page has the
  archives.
- After SKILL.md §5 passes, delete `release/X.Y.Z` and `release/X.Y.x` (the
  next patch makes `release/X.Y.x` again from the last tag), and create the
  milestone `X.Y.<Z+1>`.
