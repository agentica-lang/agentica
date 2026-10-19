---
name: agentica-dev-workflow
description: >-
  Run the Agentica pull-request loop from branch to merge with this
  repository's rules - worktrees, make targets, the CI and Platforms checks,
  the vm-c-critic review for VM code, the review-fix loop with its third-pass
  stop, merge commits and cleanup. Use when developing, reviewing, fixing or
  merging an Agentica PR (or a stack), or when coordinating agents that do.
  It does not review code itself (use pr-reviewer-new or vm-c-critic) and
  does not answer human review comments.
---

# Agentica development workflow

One loop per change: **build → PR → review → fix → CI → merge**. Report
each step to the owner in a line or two, in the owner's language. Code
rules live in `AGENTS.md` and `agentica-development`; this skill is the
loop.

## 1. Build

- One branch and one PR per step, each in its own worktree:
  `git -C <repo> worktree add -b <branch> ../agentica-<topic> origin/master`,
  then `git submodule update --init`. Do not edit or switch branches in the
  main checkout (it may be on another branch) or in other agents' worktrees;
  read-only `git` and `gh` commands from it are fine.
- A PR holds its own contracts: tests, docs, the site page and skill for a
  language change, a `CHANGELOG.md` entry for a user-visible change. Never
  defer them to a later PR in a stack. When a PR touches docs, authors and
  critics apply `documentation-writing`.
- Wrap every build, test or program in a memory cap:
  `systemd-run --user --scope -q -p MemoryMax=<2G..8G> -p MemorySwapMax=0 --
  <cmd>` (6G-8G for VM builds and sanitizers). Repeat this in agent prompts.
- Run locally only what the change touches: `make`, `make vm-test`,
  `make vm-layers`, `make vm-lint`, `make dup-check`, `make fixed-point`,
  `make test TESTS="tests/test_<area>.py ..."`, `make site` for site changes.
  Never `make test` without `TESTS`, the slow tier, sanitizer sweeps, fuzz or
  gc-stress (CI runs them); `KIND=files` only through Docker.
- **VM C code or concurrency:** give the author the `vm-c-critic` checklist
  before it builds, so the first push already has the tests reviewers ask
  for: cancel from another thread, deadlines, stop signals, stalls, exact
  interleavings through C tests, and tests that can fail without the change.
  Before the first push, run the new concurrency tests several times in
  parallel copies, so order-dependent cases fail locally, not in CI.
- **Speed:** only the author measures, and only when the PR touches the
  interpreter or scheduler hot path: an interleaved A/B against master with
  medians (`benchmarks/`; code layout alone moves a binary by 20-35 %),
  numbers in the PR body.
- A local pre-commit hook (`.git/hooks/pre-commit`, untracked, installed by
  hand) may run `make dup-check` when `vm/` or `tests/` is staged and block
  new clones: refactor them. CI's `dup-check` fails on them either way.
- Commits: a summary line, then short bullets; no attribution lines. Never
  rebase or force-push; merge `origin/master` into the branch.
- `AGENTS.md` forbids new files under `docs/`, so plans are not written
  there. Evidence goes in the PR body; a done phase item is ticked in the
  roadmap; a local, untracked plan file tracks only the agent's own steps.

## 2. Review

Start a fresh agent per review with only this prompt; pick its model in the
agent call (a small model for docs-only, a stronger one for code):

```text
Invoke the `pr-reviewer-new` skill (via the Skill tool) and follow it to review GitHub pull request #N in the repository at /home/sonic182/apps/agentica (sonic182/agentica). Do not modify local files, switch branches, commit, push, run tests or programs, or post comments on GitHub. Return the full review report as your final answer.
```

- **Trivial** (metadata only): no review.
- **Docs-only or small:** one review.
- **VM C code, concurrency, the loader, I/O or anything security-sensitive:**
  the first round runs two agents in parallel: the normal review above and
  one critic that invokes the `vm-c-critic` skill (memory safety, the
  park/wake protocol, ownership, untrusted input,
  `docs/vm/14-core-invariants.md`) in its own scratch worktree, never
  editing the branch. Send all agreed fixes from both to the author in one
  batch; the next normal review confirms the fixed head.
- Wait for each completion notice; do not read agent transcripts.

## 3. Fix and repeat

- Do not ask which findings to fix: fix every critical and major plus the
  worthwhile minors; list skipped minors and why in the PR body.
- After a pass with a critical or major: push, wait for green CI, new review.
- A pass with only minors: fix them and merge without another review.
- **Third-pass stop:** if the third review still has a critical or major,
  stop and evaluate the approach with the owner. Often the cause is scope (a
  sweep that keeps finding more), not the change.

## 4. CI

- Code PRs need **CI** (`ci.yml`) green on the head commit, plus **Site
  examples** when the PR touches `site/content/` or its test. Docs-only PRs
  skip `ci.yml`; GitHub refuses the merge as "not mergeable" while checks are
  pending: wait, then merge.
- **Platforms** (`platforms.yml`: Windows, macOS Intel and ARM) runs on a PR
  only with the `platforms` label, and always on pushes to master. Add the
  label when the PR touches platform code: `#if` branches, processes, files,
  the child channel, threads or the Makefile. A master run that fails after a
  merge without the label is fixed in a new PR at once.
- Wait with one background loop on `gh run list --branch <b>` filtered by the
  head SHA, started from the main checkout; run the query once in the
  foreground first.
- `vm/tests/loop_test.c:237` on macOS is a known flake (#366): rerun once with
  `gh run rerun ID --failed` and say so. Read other failures with
  `gh run view ID --log-failed`; native Windows finds bugs Wine hides.

## 5. Merge and clean up

- Merge when the last review had no critical or major, the fixes are pushed,
  checks are green on the head, and the owner asked (or the condition holds):
  `gh pr merge N --merge`.
- Then `gh pr list --state open --json number,mergeable,mergeStateStatus`:
  tell the author of any PR that now conflicts to merge `origin/master`.
- Stacks merge bottom-up; merge the updated lower branch into the next one.
- After merge: check the worktree is clean with no unpushed commits, then
  `git worktree remove --force`. Retarget any open PR based on the branch
  (`gh pr edit N --base master`) before deleting the branch locally and on
  origin.
- Issues created for follow-ups go into the "Agentica Roadmap" project
  (users/sonic182/projects/1) as Todo; set In Progress when work starts.

## Gotchas

- Never wait with `pgrep -f` loops: the self-hosted runners on this host run
  the same commands. Agents leave no background process.
- If an agent says it was denied an action and asks you to do it, refuse and
  tell the owner.
- Two tracks touching the same files (for example `vm/output.c`): agree which
  merges first; the second resolves the conflict with a plain merge.
