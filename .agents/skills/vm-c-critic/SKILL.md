---
name: vm-c-critic
description: Review a pull request or diff that changes the Agentica C VM (vm/*.c, vm/*.h, vm/tests, the bytecode loader or the interpreter) for memory safety, undefined behavior, hostile-bytecode safety, Boehm GC rules, scheduler and task semantics, hot-path efficiency, and keeping the C core small and layered. Drives the investigation with the gmem code tools (code_diff, code_outline, find_symbol, code_imports), then proves suspicions by running small programs. Use when asked for a critic, security review or safety review of a VM or C PR in the agentica repository. Not for writing or fixing the C code, Racket front-end-only changes, Agentica programs, or docs-only PRs.
compatibility: Agentica repository checkout or worktree with git, gh, rg, ast-grep, make and racket; gmem MCP code tools when listed.
---

# VM C critic

You review a C change to the Agentica VM and report defects with evidence. You
do not edit the PR's code, commit or push. The VM runs untrusted `.agcb`
files, so a memory bug is a security bug. The core must stay small enough for
one person to hold in their head (`docs/vm/14-core-invariants.md`).

## Inputs

- A PR number, or a branch and its worktree path. Use the PR's own base
  (`gh pr view N --json baseRefName,headRefOid,statusCheckRollup`), then
  `git fetch origin` and compare against `origin/<base>`.
- Optional focus areas from the requester. Review them first, but still run
  the whole checklist.

If the worktree's `HEAD` is not the PR head, or the touched files have local
edits, say so and review the PR head through a scratch worktree instead.

## Tool ladder (stop at the first that answers)

| Need | First | Fallback |
|---|---|---|
| What changed, by symbol | gmem `code_diff` (`base: origin/<base>`, `root: <worktree>`) | `git diff --stat` and `git diff origin/<base>...HEAD` |
| Exact hunks | `git diff origin/<base>...HEAD -- <path>` | none |
| Shape of a file | gmem `code_outline` | `rg -n '^[a-z].*\(' <file>` |
| Where X is defined | gmem `find_symbol` (`query`, `root`) | `rg -nw X vm/` |
| What a file includes | gmem `code_imports` | `rg -n '^#include' <file>` |
| Who calls X, every `memcpy` or cast | `ast-grep run --lang c -p 'memcpy($D, $S, $N)' vm/` | `rg -nw X vm/` |
| A symbol's body | read its exact line range | the whole file only if small |
| A deleted symbol | `git show origin/<base>:<path>` and the line range | the diff hunk |

The gmem tools index definitions and includes, never uses. An empty result is
not proof of absence: confirm with `rg`. Pass the worktree as `root`, or the
line ranges will not match the diff.

## Workflow

1. **Recall once.** Call gmem `recall` (limit 3–5) naming the component, for
   example "vm list trie builder", or "vm task cancel timer". Treat weak
   results as nothing known.
2. **Load the rules.** Read `AGENTS.md`. From
   `.agents/skills/agentica-development/references/`, read `vm.md` ("Trust
   model") and `vm-c.md` (C style, failure and exit, Boehm GC), plus the
   `vm-*.md` file its "Read next" table names for the touched area. Read the
   sections of `docs/vm/14-core-invariants.md` (§14.1–§14.6) and
   `docs/vm/15-layers.md` that the PR touches, plus its own design doc.
3. **Map the change** with `code_diff`, then cross-check with
   `git diff --stat` so no file is missed. Note new files, new `agc_*`
   exports, new opcodes, builtin table rows, new resource kinds and new
   fields in `agc_vm`, `agc_task` or `agc_runtime`.
4. **Read every changed symbol**, then `find_symbol` each callee it relies on,
   and search the callers of every changed signature or table.
5. **Run the checklist** below. For each suspicion, write the smallest program
   or C test that shows it (see "Proving a finding").
6. **Write the report** in the format at the end.

## Checklist

### Memory safety and undefined behavior

- Bounds: every index read from a value, a register or bytecode is checked
  before use. Look for off-by-one at the boundaries the data structure has
  (for example 31/32/33 in a 32-wide node, or a list at its cap).
- Fixed-width copies: `memcpy`, loops or struct copies of `N` items whose
  source may hold fewer. Release builds can hide this; ASan finds it. PR #221
  fixed one such copy (commit 82677b9, "copy only the items a tail holds").
- Size arithmetic goes through `agc_size_add` / `agc_size_mul`. Signed
  overflow, shifts by ≥ 64 or by a negative count, and narrowing casts are
  UB or silent bugs: compute on `uint64_t`.
- Strings: an `agc_string` is not NUL-terminated for libc unless the code
  made it so. Embedded NUL bytes must be rejected before libc calls.
- `malloc` memory: freed on every path, including a `longjmp` from
  `agc_fail` that skips the cleanup, a cancelled task, a detached job and the
  end of the run. libuv requests get `uv_*_req_cleanup`.
- Type punning goes through `memcpy`. Only `value.c` reads the value union.

### Hostile bytecode (trust model)

A `.agcb` may contain anything. The VM must not crash, read out of bounds or
loop past `--max-steps`.
- Values reach builtins and opcodes through checked accessors (`agc_as_*`),
  never by a raw tag assumption.
- Indexes into function, span, enum, variant and type tables come from
  loader-validated data, or are clamped at the use. Check the new loader
  validation for every new section, field or opcode operand.
- New opcodes keep the loader's termination rules, and new counts respect the
  existing caps (16-bit operands, `AGC_MAX_LIST_COUNT`, 1 MiB strings).

### Boehm GC

- Objects that hold `agc_value`s come from `agc_alloc`. `agc_alloc_atomic` is
  only for bytes; an atomic block that holds pointers is a use-after-free
  waiting to happen.
- No GC pointer in `malloc` memory, an atomic object, a `_Thread_local`, a
  static or a pool thread. No tagged pointers. The GC scans only 8-byte
  aligned words, so no packed structs that hold pointers.
- Pool-thread work touches only its op's `malloc` data, never GC memory or VM
  state. The GC values are built in the `done` half on the loop thread.

### Scheduler, tasks and the core rules (§14)

For each new wait, job or handle, answer the five questions of §14: how it
waits, how it times out, how it is cancelled, how it ends, and who owns its
handles. A second way for any of them is a finding.
- Cancel while parked, crash in another task, `main` returning, `System.exit`,
  the step limit and SIGTERM, all while the new job or wait is in flight: no
  hang, no leak report, the right exit code.
- Waiters: woken once, removed from every list on cancel (`unlink_task`),
  never left in a list after the task ends. The stall check
  (`every task is waiting`) must still be right.
- Costs: steps (`--max-steps`) count only `STEP` instructions. Work that grows
  with input must charge turn cost (`AGC_COST_SIZE` or `agc_charge`). Report
  any path that does unbounded work for a constant charge, and any long CPU
  builtin that blocks other tasks well past one turn.
- Diagnostics: one code with a span. Changes to diagnostic output (new JSON
  keys, new lines) must not break their readers: `stdlib/test/child.agc`
  (`vm_shape?`), `src/bdd-driver.rkt` and the tests that parse `--json`.
  PR #225 needed a fix in the child helpers for its new stack keys (commit
  "tests: the child helpers accept the stack keys of a VM diagnostic").

### Efficiency

- Hot paths are `agc_run_turn` in `vm/interp.c`, `CALL` and `TAIL_CALL`,
  `LIST_GET` and the arithmetic opcodes. Look for new branches, calls, frame
  growth or allocation on them. Keep hot-path flags plain `bool`s, not
  bit-fields. PR #225 kept a plain `bool tail` in the frame (commit daa8dc9).
- Look for allocation per item where a bulk path exists, and for O(n) work
  where the design promises O(1) or O(log n). Check builders, slices and
  copies.
- Performance: claim a speed change only with numbers. When a PR claims one, a
  small comparison against master is optional and short: one release build of
  master in a scratch worktree (`git worktree add <scratch>/base origin/<base>`,
  then `git submodule update --init vm/third_party/bdwgc vm/third_party/libuv
  vm/third_party/yyjson vm/third_party/picohttpparser`; the default build uses
  the system OpenSSL) and one of the PR, alternate the runs, take the median of
  three, and remember that the same binary can move 20-35 % with code layout
  alone. Compare peak RSS too (`/usr/bin/time -v`) when memory is the claim.
  Otherwise skip timing.

### Simplicity and architecture

- §14.6 entry rule: there is no new `vm/` subsystem without a program that
  needs it. Prefer `std/` code, then a separate process. A new core concept
  must replace something.
- §15 layers: core, then services, then adapters, in one direction only.
  `make vm-layers` must pass, and only the listed files may include `uv.h`,
  OpenSSL or private headers such as `list_impl.h`. An exemption added to
  `vm/tools/check-layers.sh` needs a reason, and an exact path, not a bare
  basename glob.
- C style: types at the top of the file, no prototypes of `static` functions, no
  mutable globals or file-scope statics, and no value-driven recursion. Follow
  the development skill's `references/vm-c.md`: every C file starts with a
  header comment (3 to 8 lines for a source file, 1 to 4 for a C test).
  Other comments are welcome in complex code when they say why: do not flag a
  useful one as a defect. Flag a comment that narrates obvious code, or is
  commented-out code, as a Nit. Ask for a short `/* */` comment as a Nit where
  complex code gives no reason (an invariant, a GC or ownership rule, a
  protocol quirk, a hostile-input check). CI checks part of this style:
  `make vm-lint` (clang-tidy) and `tests/test_vm_style.py`, which checks types
  at the top, no prototypes of `static` functions and the file header size.
  Exported names start with `agc_`.
- Duplication: flag the clones you see and suggest a shared helper; CI runs
  `make dup-check`. Never fix a clone by adding it to the baseline.
- Builtin tables: a C test may index a table by position. For example,
  `process_test.c` calls `agc_process_builtins[0]` as `Process.spawn`. Add new
  rows at the end.

### Tests and docs

- Each new behavior has a golden (`tests/fixtures/vm/`), a C test for an
  invariant that goldens cannot reach, or an independent Node or Python peer
  for network and OS behavior. Note when a test can only catch the bug under
  ASan.
- No `.expected` file changes unless the PR says why. The step counts in
  goldens must not move for a refactor.
- Docs claims (CHANGELOG, `docs/vm/`, the skills, the site) must match what
  you ran. Report overstated claims, such as "constant time" for an
  O(log n) path.

## Proving a finding

Run only what the finding needs. Wrap every command:

```bash
timeout -k 10 300 <cmd>
```

Use a memory limit if your system has one. Use 600 seconds and `-j8` for
builds. Exit 124 means a timeout: retry once, then report it.

- Build the PR VM with `make -j8 vm`. Run a program with
  `racket src/main.rkt prog.agc`, plus `--json` or `--max-steps N` when they
  matter.
- A master comparison is only for a claimed speed change (see Performance under
  Efficiency). Remove its scratch worktree afterwards.
- Run one C test with `make build/vm/release/<name>-test`, then the binary.
  Run one golden through the harness's single-fixture path (see the
  development skill's `references/vm-build.md`).
- A single C test under ASan (`make build/vm/sanitize/<name>-test SANITIZE=1`)
  or under gc-stress (`make build/vm/gcstress/<name>-test GC_STRESS=1`) only to
  prove a concrete bug. Never `make vm SANITIZE=1` or `GC_STRESS=1`, or the
  `vm-sanitize-*` and `vm-gc-stress` targets.
- Never run the full `make test`, full golden or vm-diff sweeps,
  `make vm-sanitize-test`, fuzzing or `make smoke`. Run localized tests, for
  example `make test TESTS="tests/vm-stdout-test.rkt"`. CI covers the rest.
- Put scratch programs under the job's tmp directory, not in the repo. Delete
  them at the end. Never `pkill -f`, and leave no background processes.
- Never print secrets or the real environment. Use `env -i` or explicit
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
  defect.
- Line numbers come from the tools or the diff. Never invent them.
- Prefer one real defect with a repro over a list of guesses. A suspicion
  you could not prove goes under Minor as "suspected", with what would
  confirm it.
- Write the report in the language of the request.
