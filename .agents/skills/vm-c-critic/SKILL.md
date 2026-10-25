---
name: vm-c-critic
description: >-
  Review a PR or diff changing the Agentica C VM (vm/*.c, vm/*.h, vm/tests,
  the loader or interpreter) for memory safety, UB, hostile-bytecode safety,
  GC rules, scheduler semantics, hot-path efficiency, and a small layered
  core. Investigates with gmem code tools, then proves suspicions with small
  programs. Use for critic, security or safety reviews of VM/C PRs. Not for
  writing code, front-end-only changes, programs, or docs-only PRs.
compatibility: >-
  Agentica repository checkout or worktree with git, gh, rg, ast-grep and make;
  gmem MCP code tools when listed.
---

# VM C critic

You review a C change to the Agentica VM and report defects with evidence;
you never edit the code, commit or push. The VM runs untrusted `.agcb` files,
so a memory bug is a security bug. The core must stay small enough for one
person to hold in their head (`docs/vm/14-core-invariants.md`).

## Inputs

- A PR number, or a branch and its worktree path. Use the PR's own base
  (`gh pr view N --json baseRefName,headRefOid`), then `git fetch origin` and
  compare against `origin/<base>`.
- Optional focus areas from the requester. Review them first, but still run
  the whole checklist.

If the worktree's `HEAD` is not the PR head, or the touched files have local
edits, say so and review the PR head through a scratch worktree instead.

## Tool ladder (stop at the first that answers)

- What changed, by symbol: gmem `code_diff` (`base: origin/<base>`,
  `root: <worktree>`); else `git diff --stat` with
  `git diff origin/<base>...HEAD`.
- Exact hunks: `git diff origin/<base>...HEAD -- <path>`.
- Shape of a file: gmem `code_outline`; else `rg -n '^[a-z].*\(' <file>`.
- Where X is defined: gmem `find_symbol` (`query`, `root`); else
  `rg -nw X vm/`.
- What a file includes: gmem `code_imports`; else `rg -n '^#include' <file>`.
- Who calls X, every `memcpy` or cast:
  `ast-grep run --lang c -p 'memcpy($D, $S, $N)' vm/`; else `rg -nw X vm/`.
- A symbol's body: read its exact line range (the whole file only if small).
- A deleted symbol: `git show origin/<base>:<path>` and the line range, or the
  diff hunk.

The gmem tools index definitions and includes, never uses. An empty result is
not proof of absence: confirm with `rg`. Pass the worktree as `root`, or the
line ranges will not match the diff.

## Workflow

1. **Recall once.** Call gmem `recall` (limit 3–5) naming the component
   ("vm list trie builder", "vm task cancel timer"). Treat weak results as
   nothing known.
2. **Load the rules.** Read `AGENTS.md`. From
   `.agents/skills/agentica-development/references/`, read `vm.md` ("Trust
   model") and `vm-c.md` (C style, failure and exit, Boehm GC), plus the
   `vm-*.md` file the "Read next" table of `vm.md` names for the touched
   area. Read the touched sections of `docs/vm/14-core-invariants.md`
   (§14.1–§14.6) and `docs/vm/15-layers.md`, plus the area design doc.
3. **Map the change** with `code_diff`, then cross-check with `git diff --stat`
   so no file is missed. Note new files, new `agc_*` exports, new opcodes,
   builtin table rows, new resource kinds and new fields in `agc_vm`,
   `agc_task` or `agc_runtime`.
4. **Read every changed symbol**, then `find_symbol` each callee it relies on,
   and search the callers of every changed signature or table.
5. **Run the checklist** below. For each suspicion, write the smallest program
   or C test that shows it (see "Proving a finding").
6. **Write the report** in the format at the end.

## Checklist

### Memory safety and undefined behavior

- Bounds: every index read from a value, a register or bytecode is checked
  before use. Look for off-by-one at the boundaries of the data structure
  (31/32/33 in a 32-wide node, a list at its cap).
- Fixed-width copies: `memcpy`, loops or struct copies of `N` items whose
  source may hold fewer. Release builds can hide this; ASan finds it.
- Size arithmetic goes through `agc_size_add` / `agc_size_mul`. Signed
  overflow, shifts by ≥ 64 or by a negative count, and narrowing casts are UB
  or silent bugs: compute on `uint64_t`.
- Strings: an `agc_string` is not NUL-terminated for libc unless the code made
  it so; embedded NUL bytes must be rejected before libc calls.
- `malloc` memory: freed on every path, including a `longjmp` from `agc_fail`
  that skips the cleanup, a cancelled task, a detached job and the end of the
  run. libuv requests get `uv_*_req_cleanup`.
- Type punning goes through `memcpy`. Only `value.c` and the inline
  constructors and accessors of `value.h` read the value union.

### Hostile bytecode (trust model)

A `.agcb` may contain anything. The VM must not crash, read out of bounds or
loop past `--max-steps`.

- Values reach builtins and opcodes through checked accessors (`agc_as_*`),
  never by a raw tag assumption.
- Indexes into function, span, enum, variant and type tables come from
  loader-validated data, or are clamped at the use. Check the new loader
  validation for every new section, field or opcode operand.
- New opcodes keep the loader's termination rules, and new counts respect the
  existing caps (16-bit operands, `AGC_MAX_LIST_COUNT`, and the list, map and
  string bounds that `docs/vm/08-loader-and-cli.md` names).

### Boehm GC

Apply the rules of `vm-c.md` ("Boehm GC"): which allocator holds which data,
no GC pointer outside the heap, no tagged pointers, pool threads on `malloc`
only. The critic also checks:

- `agc_alloc_atomic` holding a pointer is a use-after-free waiting to happen.
- No packed struct that holds a pointer (the GC scans only 8-byte aligned
  words).
- Pool-thread work touches only its op's `malloc` data. The GC values are
  built in the `done` half on the loop thread.

### Scheduler, tasks and the core rules (§14)

For each new wait, job or handle, answer the five questions of §14: how it
waits (§14.1), how it times out (§14.2), how it is cancelled (§14.3), how it
ends (§14.4), and who owns its handles (§14.5). A second way for any of them is
a finding.

- Cancel while parked, crash in another task, `main` returning, `System.exit`,
  the step limit and SIGTERM, all while the new job or wait is in flight: no
  hang, no leak report, the right exit code.
- Waiters: woken once, removed from every list on cancel (`unlink_task`), never
  left in a list after the task ends. The stall check (`every task is waiting`)
  must still be right.
- Costs: `--max-steps` counts `STEP` instructions only; turn cost (`agc_charge`,
  `AGC_COST_SIZE`) is separate. Work that grows with input must charge turn
  cost. Report any path that does unbounded work for a constant charge, and any
  long CPU builtin that blocks other tasks well past one turn.
- Diagnostics: one code with a span. Diagnostic output changes (new JSON
  keys, new lines) must not break their readers: `stdlib/test/child.agc`
  (`vm_shape?`), `compiler/bdd/bdd_runner.agc`, the tests parsing `--json`.

### Efficiency

- Hot paths are `agc_run_turn` in `vm/interp.c`, `CALL` and `TAIL_CALL`,
  `LIST_GET` and the arithmetic opcodes. Look for new branches, calls, frame
  growth or allocation on them. Keep hot-path flags plain `bool`s, not
  bit-fields.
- Look for allocation per item where a bulk path exists, and for O(n) work
  where the design promises O(1) or O(log n). Check builders, slices and copies.
- Speed claims need numbers. Only when a PR claims one, compare it with
  `origin/<base>` built in a scratch worktree: interleaved runs, medians
  (`references/bench-eval.md` of agentica-development); code layout alone moves
  a binary by 20–35 %. Peak RSS (`/usr/bin/time -v`) when memory is the claim.

### Simplicity and architecture

- §14.6 entry rule: no new `vm/` subsystem without a program that needs it
  (`std/` code first, then a separate process); a new core concept must replace
  something.
- §15 layers: core, then services, then adapters, in one direction only.
  `make vm-layers` must pass (Linux only), and only the listed files may include
  `uv.h`, OpenSSL or private headers such as `list_impl.h`. An exemption added
  to `vm/tools/check-layers.sh` needs a reason, and an exact path, not a bare
  basename glob.
- Platform code: a new `#ifdef` inside a shared function, two copies of one
  function under `#ifdef`, or one-system flags in a shared struct is a finding
  (flag what the diff adds, not older code). Fix with a platform adapter
  (`references/vm-c.md` of agentica-development, "Platform code").
- C style and comments: apply `references/vm-c.md` of agentica-development
  ("C style"). Its *checked* rules run in `make vm-lint` and
  `tests/test_vm_style.py`; judge the rest by reading. Flag a comment that
  narrates obvious code, or commented-out code, as a Nit. Ask for a short
  `/* */` comment as a Nit where complex code gives no reason (an invariant, a
  GC or ownership rule, a protocol quirk, a hostile-input check). Do not flag a
  useful comment.
- Duplication: flag the clones you see and suggest a shared helper; CI runs
  `make dup-check`. Never fix a clone by adding it to the baseline.
- Builtin tables: a C test may index a table by position, for example
  `vm/tests/system_test.c` calls `agc_system_builtins[0]`. Add new rows at the
  end.

### Tests and docs

- Each new behavior has a golden (`tests/fixtures/vm/`), a C test for an
  invariant that goldens cannot reach, or an independent Node or Python peer for
  network and OS behavior. Note when a test can only catch the bug under ASan.
- No `.expected` file changes unless the PR says why. The step counts in goldens
  must not move for a refactor.
- Docs claims (CHANGELOG, `docs/vm/`, the skills, the site) must match what you
  ran: report overclaims ("constant time" for an O(log n) path) and doc
  changes that were not needed (`documentation-writing`).

## Proving a finding

Run only what the finding needs. Wrap every command in `timeout -k 10 300
<cmd>`, with a memory limit when the system has one (600 seconds for builds).
Exit 124 means a timeout: retry once, then report it.

- Build the PR binary with `make -j8`. Run a program with
  `dist/agentica prog.agc`, plus `--json` or `--max-steps N` when they matter.
- Run one C test with `make build/vm/release/<name>-test`, then the binary. Run
  one golden with `make vm-golden-check FIXTURES="<name>"`.
- A single C test under ASan (`make build/vm/sanitize/<name>-test SANITIZE=1`)
  or under gc-stress (`make build/vm/gcstress/<name>-test GC_STRESS=1`) only to
  prove a concrete bug. Never `make SANITIZE=1` or `GC_STRESS=1`, or the
  `vm-sanitize-*` and `vm-gc-stress` targets.
- Never run the full `make test`, full golden or vm-diff sweeps,
  `make vm-sanitize-test`, fuzzing or `make smoke`. Run localized tests, for
  example `make test TESTS="tests/test_vm_stdout.py"`. CI covers the rest.
- Scratch worktrees and programs live outside the repo (the job's tmp
  directory); remove them at the end. Never `pkill -f`; leave no background
  process.
- Never print secrets or the real environment; use `env -i` or explicit
  variables in tests.

## Report

```text
VERDICT: merge | fix first   (head <sha>)

Blocker / Major / Minor / Nit
- <file>:<line> — <defect in one sentence>
  Repro: <program or command, and what it printed>
  Fix: <concrete change>

What I verified
- <claim> — <evidence: run, output, numbers, or the code read>

Not run
- <checks skipped and why>
```

- A blocker is a memory error, UB, a crash or hang reachable from a valid
  program or a hostile `.agcb`, a broken core rule (§14), or a CI-breaking
  defect. Line numbers come from the tools or the diff; never invent them.
- Prefer one real defect with a repro over a list of guesses. An unproven
  suspicion goes under Minor as "suspected", with what would confirm it.
- Write the report in the language of the request.
