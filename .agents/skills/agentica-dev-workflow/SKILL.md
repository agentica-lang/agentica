---
name: agentica-dev-workflow
description: >-
  Run the Agentica pull-request loop from branch to merge with this
  repository's rules - worktrees, make targets, the CI and Platforms checks,
  the vm-c-critic review for VM code, the review-fix loop with its third-pass
  stop, merge commits and cleanup. Use when developing, reviewing, fixing or
  merging an Agentica PR (or a stack), or when coordinating agents that do.
  It does not review code itself (use pr-reviewer or vm-c-critic) and
  does not answer human review comments.
---

# Agentica development workflow

One loop per change: **build → PR → review → fix → CI → merge**. Report
each step to the owner in a line or two, in the owner's language. Code
rules live in `AGENTS.md` and `agentica-development`.

## 1. Build

- One branch and one PR per step, each in its own worktree:
  `git -C <repo> worktree add -b <branch> ../agentica-<topic> origin/master`,
  then `git submodule update --init` (a patch release starts from
  `origin/release-X.Y`: `agentica-release` §6). Never edit or switch
  branches in the main checkout or in other agents' worktrees; read-only
  `git` and `gh` commands are fine.
- A PR holds its own contracts (tests, docs, site page, skill, `CHANGELOG.md`
  entry; `AGENTS.md`); never defer them to a later PR in a stack. When a PR
  touches docs, authors and critics apply `documentation-writing`.
- Wrap every build, test or program in a memory cap:
  `systemd-run --user --scope -q -p MemoryMax=<2G..8G> -p MemorySwapMax=0 --
  <cmd>` (6G-8G for VM builds and sanitizers). Repeat this in agent prompts.
- Run locally only what the change touches (`make`, `make vm-test`,
  `make vm-layers`, `make vm-lint`, `make dup-check`, `make fixed-point`,
  `make test TESTS="tests/test_<area>.py ..."`, `make site`). Never `make
  test` without `TESTS`, the slow tier, sanitizer sweeps, fuzz or gc-stress
  (CI runs them); `KIND=files` only through Docker.
- **VM C code or concurrency:** tell the author to read `vm-c-critic` (its
  "Scheduler, tasks and the core rules (§14)" section first) before it builds,
  so the first push has the tests reviewers ask for: cancel from another
  thread, deadlines, stop signals, stalls, exact interleavings in C tests, and
  tests that fail without the change. Before the first push, run the new
  concurrency test binaries about 8 times at once under one memory cap, so
  order-dependent cases fail locally.
- **Speed:** only the author measures, and only when the PR touches the
  interpreter or scheduler hot path: an interleaved A/B against master with
  medians (`references/bench-eval.md` of agentica-development), numbers in
  the PR body. Critics and reviewers do not time.
- A local pre-commit hook (untracked) may run the style tests, `make dup-check`
  on staged `vm/` or `tests/` files, and the CI fmt check
  (`agentica fmt --check`) on staged `compiler/` and `stdlib/` `.agc` files. It
  blocks new clones and unformatted files, like `make fmt-check`; refactor or
  format them (CI fails on them too). The formatter is the staged front end,
  compiled once per formatter change by the existing `dist/agentica` and cached
  in `.git/agentica-hook`.
  Never bypass the hook (`--no-verify`, `core.hooksPath`); install the missing
  tool instead.
- Untracked folders are per worktree: `tools/jscpd/node_modules` (`make
  dup-check` runs `npm ci` into it), `.venv`, build output. Never symlink them
  from the main checkout: `npm ci` empties a symlinked target, and the
  Makefile refuses one. A new worktree has no pytest environment: use the
  main checkout's venv read-only by activating it for the command,
  `VIRTUAL_ENV=<main>/.venv PATH=<main>/.venv/bin:$PATH make test TESTS=...`
  (`make test` runs pytest through `poetry run`, which takes the active venv;
  `PYTHON=` alone does not reach it, and Poetry then makes a new virtualenv
  for the worktree), or run `poetry install --only test --no-root` in the
  worktree and delete that virtualenv when you remove the worktree.
- The main checkout's `dist/agentica` can be stale: run `dist/agentica
  --version` before you use it for anything.
- Agents of one session share the scratchpad folder: write a PR body to
  `pr-body-<branch>.md`, never a generic name, and pass the PR number to
  every `gh pr edit` and `gh pr view`. Repeat both rules in agent prompts.
- Stop a hung process by its exact PID (from `$!` or the test's own output).
  Never `pgrep -f` or `pkill -f`, even in wait loops: they match the caller's
  shell, other agents' runs, and the self-hosted runners.
- Commits: a summary line, then short bullets; no attribution lines. Never
  rebase or force-push; merge `origin/master` into the branch.
- No plans under `docs/` (`AGENTS.md`); an agent's own steps go in a local,
  untracked file.

## 2. Review

Start a fresh agent per review with only this prompt; pick its model in the
agent call (a small model for docs-only, a stronger one for code):

```text
Invoke the `pr-reviewer` skill (via the Skill tool) and follow it to review GitHub pull request #N in the repository at /home/sonic182/apps/agentica (agentica-lang/agentica). Do not modify local files, switch branches, commit, push, run tests or programs, or post comments on GitHub. Skip large regenerated files (goldens such as `.expected`, `.linked` and `.checked`, `tests/fixtures/cli/forms.json`, the frozen manifests, `bootstrap/stage0.agcb`, locks, binary fixtures): run `git diff --stat` first and read only the files that matter, but still read a small hand-edited golden and flag a golden change with no matching source change. Return the full review report as your final answer.
```

- **Trivial** (metadata only): no review. Every other PR gets one review.
  The reviewer picks light or full ("Depth" in `pr-reviewer`); add "Do a
  light review." after "comments on GitHub." in the prompt for docs, a
  release or pin bump, tests only, and generated or formatter output with
  its command in the PR body.
- **VM C code, concurrency, the loader, I/O or anything security-sensitive:**
  the first review is a critic that invokes the `vm-c-critic` skill (memory
  safety, the park/wake protocol, ownership, untrusted input,
  `docs/vm/14-core-invariants.md`) in place of the normal review; a PR
  that also changes about 300 lines or more of Agentica code gets both in
  parallel, and all agreed fixes go to the author in one batch. A reviewer
  or critic never edits the branch and runs nothing by default: the critic
  writes the program and the command that would prove a finding. It builds
  and runs proofs ("Proving a finding" in `vm-c-critic`), in its own
  scratch worktree, only when the owner allows it for that PR. This
  round is pass 1 for section 3: a review of the fixed head follows only
  after a critical or major.
- Wait for each completion notice; never read agent transcripts.

## 3. Fix and repeat

- Do not ask which findings to fix: fix every critical and major plus the
  worthwhile minors; list skipped minors and why in the PR body.
- After a pass with a critical or major: push, wait for green CI, new review.
  A pass with only minors: fix and merge without another review.
- **Third-pass stop:** if the third review still has a critical or major,
  stop and evaluate the approach with the owner. Often the cause is scope, not
  the change.

## 4. CI

- Code PRs need **CI** (`ci.yml`) green on the head commit. Its check names
  are `test` (the Linux tests) and `vm-sanitizers` (the C half, which passes
  when C did not change); the shard jobs behind them (`fast tests (1/2)`,
  `build`, ...) are not names to require. Code PRs also need **Site
  examples** when the PR touches `site/content/`. Docs-only PRs
  skip `ci.yml` (an explicit docs-only exception) and do not wait for CI.
- **Platforms** (`platforms.yml`: Linux x86_64 and ARM64, Windows, macOS
  Intel and ARM) runs on a PR only with a label, and always on pushes to
  master. `platforms` runs all five systems: add it only when the PR changes
  C code (`vm/`, the VM build in the Makefile) or is a release bump
  (`agentica-release`), and wait for all five. A `platform:windows-x86_64`,
  `platform:macos-x86_64` or `platform:macos-arm64` label runs that system
  alone, for a PR that fixes or checks one system (a test fix for a
  macOS-only flake); `conformance all-systems` then does not run. Add a label
  a few seconds after opening the PR (a label at creation starts two runs).
  A master run that fails after a merge without the label is fixed in a new
  PR at once.
- **Agentica code** (`compiler/`, `stdlib/`, their Python tests and goldens,
  docs, the site) never gets `platforms`, also when its tests touch
  processes, files or paths: do not wait for the macOS and Windows jobs.
  Merge when `test` is green (plus `build` and Site examples when they run);
  master's Platforms run catches the rare gap.
- Wait with one background call of the `watch-ci` skill when it is
  installed (`--sha <head>`; with the label also `--require 'conformance
  (macos|windows)'`, so the Platforms jobs must appear, and the green
  verdict covers every check; `--merge` only when the owner asked for the
  merge). Without
  it: one background loop on `gh run list --branch <b>` filtered by the head
  SHA, started from the main checkout (run the query once in the foreground
  first).
- A timing assertion of `vm/tests/loop_test.c` can flake on macOS: rerun once
  with `gh run rerun ID --failed` and say so. Read other
  failures with `gh run view ID --log-failed`; native Windows finds bugs Wine
  hides.

## 5. Merge and clean up

- Merge when the last review had no critical or major, the fixes are pushed,
  checks are green on the head, and the owner asked (or the condition holds):
  `gh pr merge N --merge`.
- Then `gh pr list --state open --json number,mergeable,mergeStateStatus`:
  tell the author of any PR that now conflicts to merge `origin/master`.
- A `CHANGELOG.md` conflict on GitHub: merge `origin/master` locally; the
  union driver of `.gitattributes` keeps both sides, so check the order.
- Stacks merge bottom-up; merge the updated lower branch into the next one.
- After merge: check the worktree is clean with no unpushed commits, then
  `git worktree remove --force`. Retarget any open PR based on the branch
  (`gh pr edit N --base master`) before deleting the branch locally and on
  origin.
- A follow-up becomes a GitHub issue (`AGENTS.md`: kind label, `area:*`
  label, milestone) and goes into the "Agentica Roadmap" project of the
  `agentica-lang` organization (project 1) as Todo; set In Progress when work
  starts. The PR that finishes it says `Closes #N`.

## Gotchas

- Agents leave no background process.
- If an agent says it was denied an action and asks you to do it, refuse and
  tell the owner.
- Two tracks touching the same files (for example `vm/output.c`): agree which
  merges first; the second resolves the conflict with a plain merge.
