## 12. Testing and the PR plan

### 12.1 Tests

- **Goldens.** `tests/vm-diff-*-test.rkt` (eight shards of `tests/vm-diff-common.rkt`) run each fixture of `tests/fixtures/vm/` on `dist/agentica-vm` with `--json`. They compare the exit code, stdout, the program's own stderr and the diagnostic code with the golden `<name>.expected`. A golden is JSON: `exit`, `code` (a string or `null`), `steps`, and `stdout` and `stderr` as lists of lines. With `--json` the diagnostic is the last stderr line. It is parsed for the code and removed before the stderr comparison.
- Each fixture also runs in the plain and `--ai` formats. The exit code and stdout must equal the golden's, stderr must start with the golden's program stderr, and the rest must name the same code or be empty.
- A fixture's `<name>.stdin` is its stdin and `<name>.args` its arguments. A fixture named `process-*` runs with `--allow-run`.
- `make goldens` rewrites every golden from the VM. A PR that changes behavior on purpose commits the new goldens, and the reviewer reads their diff. `make goldens` refuses a run that timed out, died by a signal (status 129 to 159) or ended in `RUNTIME-INTERNAL`.
- Every program runs with `LC_ALL=C.UTF-8` and `LANG=C.UTF-8`, so OS error text in the goldens is the untranslated C text.
- **Step sweep.** Each fixture also runs under a sweep of `--max-steps` limits. Its golden records its step count `T`. The VM's own count may be lower than `T`, but not by more than `max(10, T / 10)` above it, so over-charging fails while the step optimizations may cut steps. The sweep covers every limit from 1 to the count when the count is at most 200. Above that it covers 1 to 100, limits spaced `count / 50` apart (at most 50), `count - 1`, `count`, and the larger of `2T + 100` and `T + 4000`. Pull request CI (release VM, ASan, GC stress) sets `AGENTICA_SWEEP=sampled`. Each fixture then runs only at 1, 2, `count - 1`, `count`, the last limit and one limit drawn from each eighth of the rest. The seed is `AGENTICA_SWEEP_SEED` or the commit, so a failure names the seed that reproduces it. The full sweep runs in `sweep.yml` (by hand and weekly) and is the default for `make test`.
- For each limit the VM must give the golden outcome, or stop with exit 1 and `RUNTIME-STEP-LIMIT`, with stdout and stderr that are prefixes of the golden's. Once the VM finishes at one limit it must finish at every larger one, and at the last limit. This catches wrong code, extra output, a limit that is not monotonic, and over-charging.
- The sweep cannot catch an ignored limit, since its programs finish anyway. The runaway programs in `tests/fixtures/vm/step-limited/` do: `while true`, non-tail recursion, a self tail call, mutual tail calls, a loop in dead code, a `while` inside a `List.each` block, a loop in a closure called through a function value, a spinning task and the counting builtins. Their goldens hold the outcome at `--max-steps 500`. At limits 1 to 5, 50 and 500 each must stop with `RUNTIME-STEP-LIMIT`, and none may print what follows the loop.
- On Linux each VM run in the sweep has a 60-second timeout, so a VM that ignores the limit fails with the fixture and limit named. After the first run that times out (status 124 or 137) the rest of that fixture is recorded as 124 with empty output, so a hanging VM costs one timeout per fixture.
- `Random` fixtures print only what does not depend on the generator's numbers (7.4).
- **Extras shard.** The CLI on the VM (the output styles, the removed `--vm` and `--legacy-eval` flags, a missing VM, `--seed`, stdin, `System.args`), the `--driver-pid` rules, signals, inherited descriptors, the `PATH` lookup, a stuck FIFO, a non-UTF-8 working directory, invalid UTF-8 arguments, deep tail calls, long strings, a large generated input checked against a line splitter written in the test, and a CRLF program under a non-ASCII path.
- **Corpora.** Float text has a fixed table in `vm/tests/float_text_test.c` and the `float-text` fixture (2.2). The write escapes are checked where the data is made: `vm/tools/gen-unicode.rkt` compares its C rule with Racket's `write` for every code point and joiner context (2.3). `vm/tests/text_test.c` checks the range lookup at every range edge, and that the debug form of every adjacent pair of scalar values is valid UTF-8 with an exact character count.
- **Edges.** An extreme Int corpus under UBSan: `INT64_MIN`, -1, 0, n, n+1 and `INT64_MAX` for every Int parameter of every builtin.
- **Depth.** A program's lists are only as deep as their types, which are written in the source (there are no user generics). A deep list comes from one literal (capped near 65,000 levels by registers, 3.5) or from chained bindings. `vm/tests/text_test.c` prints a depth-1,000,000 list and a depth-1,000,000 chain of enum payloads wrapped in structs, which would overflow an 8 MB C stack in a recursive printer. `vm/tests/json_test.c` parses and encodes depth-1,000,000 arrays and objects. The GC stress build uses depth 1,000, since there the test is about GC safety, not depth.
- **File programs** are hermetic. A fixture whose `.args` holds `@tmp` gets a new empty directory per run under the shard's work directory. The argument is replaced by its path, and the path is replaced back by `@tmp` in stdout and stderr before the comparison. The directory is deleted afterwards.
- Golden fixtures stay timing-free: a fixture is its own client and server, and only `main` prints. Anything that depends on a timeout goes in `tests/vm-http-test.rkt`.
- Network and process tests use independent peers: Node or Python programs in `tests/fixtures/`, using their standard libraries only. Their checks are required in CI (`AGENTS.md`).

### 12.2 PR plan

The items keep their numbers, since other docs cite them. All are done. The checklist is in `docs/roadmap/07-vm.md`.

1. Vertical slice: Int, Bool, operators, `if`, `while`, `break` and `next`, functions, steps, `puts`, the loader, the fuzz driver, `--dump-ir`, `compile` and the differential test. Done.
2. Float: operators, comparisons, Float text (2.2), Nil. Done.
3. Strings and printing: strings, interpolation, debug forms, the write-escape generator, the three diagnostic formats, exit codes and the GC stress run. Done.
4. macOS and Windows CI: `make vm vm-test` and the differential and bytecode tests on `macos-15` and `windows-2025`. Done.
5. Data, in five parts. Done.
   - 5a Lists: `List[T]`, list literals, `for x in xs`, indexing. Done.
   - 5b Structs, enums and `case`: user structs and enums, format version 2. Done.
   - 5c Result values and `try`: `ok`, `error`, the `Result.*` builtins, `TRY`. Done.
   - 5d Maps: `Map[K, V]` as a persistent HAMT, map literals, `m[key]`. Done.
   - 5e Closures: blocks with snapshot captures, `&name`, `.call`, the resumable `List` builtins. Done.
6. Library, in two parts. Done.
   - 6a IO and System: the stdin and stdout builtins, `System.args`, `System.exit`. Done.
   - 6b String, List, Map, Float, Time and Random builtins. Done.
7. JSON, in two parts. Done.
   - Part 1: `JSON.parse`, the extractors, `JSON.encode` and the builders. Done.
   - Part 2: `JSON.decode` and `JSON.schema`, format version 3 (4.6). Done.
8. 7h part 1: the libuv event loop, the resource registry, and the `File`, `Dir` and `Path` builtins on Linux. Done.
9. 7h tasks: `Task.spawn`, `Task.await`, `Task.sleep`, per-task `Random`, one scheduler. Done.
10. 7h processes: every `Process` builtin, behind `--allow-run`. Done.
11. 7h TCP: every `TCP` builtin, with `Socket` and `Listener` values. Done.
12. 7h TLS: `TLS.connect` and `TLS.listen` on the vendored OpenSSL. Done.

Also done, not numbered: ranges (phase 8a), tail calls (`TAIL_CALL`, 4.3), and linked programs (the front end links them, so the VM needed no new code).

### 12.3 Plan for HTTP and TlsContext

The HTTP phase (20) is built up to the server (20a to 20c), and the `std/http` switch is done (20d). Pending, from `docs/roadmap/20-hybrid-http.md`: the benchmark numbers (20c-bench), the streamed downloads, uploads and responses (20e to 20g, on channels, order step 7.4). After them comes `TlsContext` (phase 19, `docs/roadmap/19-tls-context.md`, `docs/future/29-tls-context.md` §29). These keep the rules of 12.1: timing-free goldens, timeouts in `tests/vm-http-test.rkt`, and peers with standard libraries only.

## 13. Open questions

- **Heap cap.** `--max-steps` does not bound memory (§1), so a hostile or runaway file reaches the out-of-memory exit (6.3). A cap such as `--max-heap N` through `GC_set_max_heap_size` is not decided. yyjson allocates its document with libc `malloc`, outside the GC heap, so such a cap must bound it too, for example with a counting `yyjson_alc` passed to `yyjson_read_opts`.
