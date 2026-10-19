---
name: agentica-dev-workflow
description: Run the Agentica pull-request loop from branch to merge with this repository's rules - worktrees, make targets, the CI and Platforms checks, the vm-c-critic review for VM code, the review-fix loop with its third-pass stop, merge commits and cleanup. Use when developing, reviewing, fixing or merging an Agentica PR (or a stack), or when coordinating agents that do. It does not review code itself (use pr-reviewer-new or vm-c-critic) and does not answer human review comments.
---

# Agentica development workflow

One loop per change: **build → PR → review → fix → CI → merge**. Report each
step to the owner in a line or two, in the owner's language. Code rules
live in `AGENTS.md` and `agentica-development`; this skill is the loop.

## 1. Build

- One branch and one PR per step, each in its own worktree:
  `git -C <repo> worktree add -b <branch> ../agentica-<topic> origin/master`,
  then `git submodule update --init`. Never touch the main checkout (it may be
  on another branch) or other agents' worktrees.
- A PR holds its own contracts: tests, docs, the site page and skill for a
  language change, a `CHANGELOG.md` entry for a user-visible change. Never
  defer them to a later PR in a stack.
- Wrap every build, test or program in a memory cap:
  `systemd-run --user --scope -q -p MemoryMax=<2G..8G> -p MemorySwapMax=0 --
  <cmd>` (6G-8G for VM builds and sanitizers). Repeat this in agent prompts.
- Run locally only what the change touches: `make`, `make vm-test`,
  `make vm-layers`, `make vm-lint`, `make dup-check`, `make fixed-point`,
  `make test TESTS="tests/test_<area>.py ..."`, `make site` for site changes.
  Never `make test` without `TESTS`, the slow tier, sanitizer sweeps, fuzz or
  gc-stress (CI runs them); `KIND=files` only through Docker.
- The pre-commit hook runs `make dup-check` when `vm/` or `tests/` is staged
  and blocks new clones: refactor them.
- Commits: a summary line, then short bullets; no attribution lines. Never
  rebase or force-push; merge `origin/master` into the branch.
- Plans never go into `docs/` (`AGENTS.md`). A local, untracked plan file is
  where progress gets ticked; evidence goes in the PR body.

## 2. Review

Start a fresh agent per review with only this prompt; pick its model in the
agent call (a small model for docs-only, a stronger one for code):

```text
Invoke the `pr-reviewer-new` skill (via the Skill tool) and follow it to review GitHub pull request #N in the repository at /home/sonic182/apps/agentica (sonic182/agentica). Do not modify local files, switch branches, commit, push, run tests or programs, or post comments on GitHub. Return the full review report as your final answer.
```

- **Trivial** (metadata only): no review.
- **Docs-only or small:** one review.
- **VM C code, concurrency, the loader, I/O or anything security-sensitive:**
  first two critics in parallel, each in its own scratch worktree, never
  editing the branch:
  - security and correctness critic: invokes the `vm-c-critic` skill
    (memory safety, the park/wake protocol, ownership, untrusted input,
    `docs/vm/14-core-invariants.md`);
  - speed and simplicity critic: interleaved A/B against master with medians
    (`benchmarks/`, remember code layout alone moves a binary by 20-35 %),
    KISS, duplication, the "Platform code" rule of
    `agentica-development/references/vm-c.md`, test gaps, docs that
    overclaim.
  Send all agreed fixes to the author in one batch, then run the normal
  review on the fixed head.
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

- Code PRs need **CI** (`ci.yml`), **Platforms** (`platforms.yml`: Windows,
  macOS Intel and ARM) and **Site examples** green on the head commit.
  Docs-only PRs skip `ci.yml`, but Platforms still runs, and GitHub refuses
  the merge as "not mergeable" while checks are pending: wait, then merge.
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
