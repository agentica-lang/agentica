# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **OS builtins for the BDD driver port** (§35.5, step 7a), all VM only. `File.lstat(path, timeout_ms)` is `File.stat` without following a final symbolic link (`kind` is `"link"`). `File.open(path, "create_private", timeout_ms)` creates a new write-only file with mode 0600 and fails when the path exists, a dangling link included. `File.try_lock(handle, timeout_ms)` takes an exclusive `flock` on an open file without waiting, `ok(true)` or `ok(false)` when another handle or process holds it; the lock ends when the handle closes, its task ends or the process ends, and no child process keeps it. `Dir.mkdir_private(path, timeout_ms)` creates one directory with mode 0700 and fails when it exists. `Path.remove(path, timeout_ms)` deletes a file, a symbolic link itself, or a directory with everything in it, never following a link (`vm/tree.c`, `openat` with `O_NOFOLLOW` and `unlinkat`); a missing path is `ok()`, `/`, `.` and `..` are refused, and a tree deeper than 128 levels is an error. `System.pid()` returns the process id. (#288)
- **Module constants.** A top-level `NAME = expr` (or `export NAME: Type = expr`) names a value that is fixed for the whole run: `PRICES = {"tea": 3}`, `KEYWORDS = Set.new(["if", "end"])`, `SECONDS = 24 * 60 * 60`. The name is capitals, digits and `_`, at least two characters (`PARSE-CONSTANT-NAME`). Constants come right after the imports (`CHECK-DECL-ORDER` has a new group), follow each other with no blank line, and may read each other in any order (a loop is `CHECK-CONSTANT-CYCLE`). A constant is read as `NAME` (`NAME.size`, `NAME.get(k, 0)`, `NAME[i]`, `NAME.with(field: x)`, `"#{NAME}"`), and `import {NAME} from "path"` brings an exported one into another file (renamed only to another constant name, `CHECK-IMPORT-RENAME`); `Mod.NAME` is `CHECK-IMPORT-NAME`. The value is built from literals, collections, struct and enum values, operators, other constants and builtins without effects; a call of your own function, `&f`, `while` or a builtin with effects is `CHECK-CONSTANT-EXPRESSION`, and a value that is not data (a channel, a task, a function) is `CHECK-CONSTANT-TYPE`. Assigning to a constant in a function is `PARSE-INVALID-ASSIGNMENT-TARGET`, and a constant is not a case pattern. An unknown name in capitals (`LIMT`) is now `CHECK-UNKNOWN-NAME` with a `did you mean` over the constants the file can read, where it was `CHECK-TYPE-MISMATCH`. The messages of `PARSE-TOP-LEVEL-STATEMENT` and of `export` followed by something else now mention constants. Both front ends and both checkers change together (roadmap row 7.2.8, 44a2). A scalar literal is inlined in the bytecode; any other value is built once by the VM before `main`, in dependency order, and only if `main` can reach a function that reads it, so a constant that nothing reads never runs. An error in an initializer stops the program before `main` prints anything, with the constant in the stack trace (#270, #271).
- **`std/toml`** reads and writes TOML 1.0, written in Agentica (`import Toml from "std/toml"`): `Toml.parse(text)` returns `Result[Toml.Value]`, where `Value` is a recursive enum (`Str`, `Int`, `Float`, `Bool`, `DateTime`, `Array`, `Table`) and a `DateTime` keeps the text as written. It covers the whole specification: all key and string forms and escapes, integers in four bases with 64-bit bounds, floats with `inf` and `nan`, the four date-time forms, arrays, inline tables, standard tables, arrays of tables, and the redefinition rules. An error reads `line 3, column 7: expected '=' after key`; no input halts, and arrays, inline tables and keys nest at most 256 levels. `Toml.encode(value)` writes a table as deterministic TOML (plain entries, then `[sub]` sections, then `[[array]]` sections) and `parse(encode(v))` gives the same values back (key order may be regrouped); the writer and `to_json` return an error, never a halt, for values nested deeper than the reader accepts. A float above the largest float reads as `inf`. `Toml.to_json(value)` bridges to `JSON.decode(JSON.encode(json), T)`, and `Toml.get(value, "a.b")` reads a dotted path. It is the format of the planned `agentica.toml` and `agentica.lock` (45-0) (#275).
- **Named imports and `import Mod from "path"`.** `import Util from "util"` gives a file the alias `Util`. `import {area, Square as Sq} from "shapes"` brings exported functions, structs and enums into the file, to be used bare: `area(s)`, `&area`, `Square(side: 3)`, the type `Square`, and for an enum `Color` the values `Color.Red` and `Color.Green(1)`, and `Color.Red` in a pattern. An entry may rename (`Square as Sq`), and the new name keeps the case rule of what it names (`CHECK-IMPORT-RENAME`). Both forms can be used in one file and two lines may share a path, but one line does one thing. An imported name cannot be a declaration, an alias, another imported name, a builtin function or a reserved type (`CHECK-REDEFINED-NAME`), and a name the module does not export is `CHECK-IMPORT-NAME` with a `did you mean` help over its exports. A module imported by names counts as imported for `value.with(...)`. `from` and `as` are not reserved words. The Racket front end and `compiler/` change together (roadmap row 7.2.8, 44a0-1) (#262).
- **Struct update `value.with(field: x)`** returns a copy of a struct with the named fields changed, and the original stays as it was: `older = ana.with(age: 31)`. Name at least one field, each once, with a value of the field's type; every value is computed from the struct as it was before the update, so `p.with(a: p.b, b: p.a)` swaps two fields. Updates chain and nest (`a.with(address: a.address.with(city: "Lima"))`), and `step(s.with(pos: s.pos + 1))` is a tail call. `ana.with()` and `ana.with(31)` are `PARSE-UNEXPECTED-TOKEN` with the form in the help; a value that is not a struct is `CHECK-UNKNOWN-METHOD`; a bare update whose result is dropped is `CHECK-UNUSED-VALUE`; a struct that another module keeps private cannot be updated by an importer (`CHECK-IMPORT-NAME`). It is one new instruction, `STRUCT_WITH`, 15% to 34% faster than a constructor call for structs of 4 to 16 fields (#253).
- **`Set[T]`** is an immutable set of distinct `Int` or `String` values that keeps first-insertion order: `Set.new(items)` (repeated items dropped, the first keeps its place; `Set.new([])` needs an expected type, like `[]`), `add`, `delete`, `include?`, `size`, `empty?`, `to_a`, `union`, `intersection`, `difference` and `subset?`, all also methods (`s.add(x)`). `for x in set` visits the elements in order, and a set prints as `Set[1, 2]`. There is no `==` on sets, no index and no JSON encoding (`CHECK-TYPE-MISMATCH`, `CHECK-NOT-INDEXABLE`, `CHECK-NOT-ENCODABLE`); `Test.eq` compares two sets in any order. A `Set[T]` with another element type is `CHECK-SET-ELEMENT-TYPE`, and `Set.new([])` without an expected type is `CHECK-EMPTY-SET-TYPE`. The VM keeps a set as a map with nil values, so `add` and `include?` cost the same as `Map.put` and `Map.has_key?` (#250).
- **`Time.monotonic_ns()`** returns nanoseconds from the clock of `Time.monotonic_ms` (same origin, never goes backward), for durations too short for milliseconds. Both builtins share one clock read, so they cannot disagree (#248).
- **`Task.await(task, timeout_ms)`** waits for a task for at most `timeout_ms` milliseconds and returns the new builtin enum `Await[T]`: `Await.Done(value)` or `Await.TimedOut`. The checker requires both variants, like a user enum. A timeout does not cancel the task, a task that has ended never times out, and `timeout_ms` of 0 or less is `RUNTIME-INVALID-DURATION` (#217).
- **`Task.spawn_owning(&f, channel)`** makes the new task the owner of a `Channel`. When that task ends in any way (return, crash, cancel) the channel is closed as by `Channel.close`: a reader gets the values already sent, then the closed error at once, instead of waiting for its timeouts. A channel that is never handed over stays unowned and is closed only by `Channel.close`, which any task may still call. Plain `Task.spawn` gives no ownership, and a channel owned by another task is `RUNTIME-HANDLE-NOT-OWNED` for a caller that tries to hand it over (#219).
- **`System.env(name)`** reads an environment variable and returns `Result[String]`: `ok(value)`, `ok("")` for an empty value, and an error for an unset variable or a name that is empty or has `=` or NUL. A value that is not valid UTF-8 has each bad byte replaced by U+FFFD. It needs no flag. The VM hides `AGENTICA_CHANNEL` and a `UV_USE_IO_URING` it set itself, as it does for child processes (#222).
- **`Path.real(path)`** returns the absolute canonical path with every symbolic link resolved (POSIX `realpath`) as `Result[String]`. The path must exist; a relative path starts at the current directory. It runs in the file thread pool and has no timeout argument (#222).
- **Bit builtins for `Int` and `Float`.** `Int.bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left` (wraps), `shift_right` (arithmetic) and `shift_right_unsigned` (logical) work on the 64-bit two's complement form; a negative shift count is `RUNTIME-INVALID-COUNT`, and a count of 64 or more shifts every bit out. `Float.to_bits` and `Float.from_bits` read and write the binary64 bits, `Float.to_bits32` and `Float.from_bits32` the binary32 bits (`from_bits32` outside `0 .. 4294967295` is `RUNTIME-INVALID-NUMBER`); every NaN gives the canonical bits. They are also methods (`flags.bit_and(4)`, `x.to_bits`) (#220).
- **`std/binary`** reads and writes binary numbers in a `List[Int]` of bytes, written in Agentica on the bit builtins: `Binary.read_u8` to `read_i64_*`, `read_f32_*` and `read_f64_*` (a `Result`, never a halt) and the matching `write_*` in big-endian (`_be`) and little-endian (`_le`), `Binary.concat`, and the 4-byte length framing `Binary.frame` and `Binary.read_frame_length`. A `u64` above the largest `Int` is an error; use the `i64` readers and writers for all 64 bits (#223).
- **`std/logger`** is an Elixir-style logger written in Agentica (`import Logger from "std/logger"`): four levels (`debug`, `info`, `warning` and `err`, each with a `_meta` form that takes fields), `log` and `log_meta`, a global level, named handlers with their own level (`attach`, `detach`, `handlers`), `enabled?`, the built-in handlers `stderr_text` and `stderr_json`, the formatters `format_text` and `format_json`, and `time_text`. The first call attaches a `console` handler that writes text lines to stderr at `info`. Handlers run synchronously in the task that logs. The handlers and the level are held by the VM runtime (`vm/logger.c`, the std-only `LogRegistry` builtins), the language's only global state. A disabled call, or one that no handler accepts, costs one function call, one builtin call and one comparison (#246).
- **Stack traces on runtime errors.** A runtime diagnostic of a running task now shows the call stack of the task that failed, innermost frame first, in the plain, `--ai` and `--json` formats, with no flag: each frame is a function name and `file:line:column`, a frame left after a tail call ends with `(after a tail call)`, a run of the same call is one line with a count (`(9998 times)`), at most 20 lines show (`... 312 frames not shown ...`), and a task ends with `task spawned at file:line:column`. `--json` adds `stack`, `stack_omitted` and `spawned_at`. It is shown when the failing task has more than one frame or is not `main`, for `RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` too, and in a task's crash line. A failure directly in `main` looks as before (#225).

### Changed

- **Breaking:** invalid UTF-8 in a source file is now an error. The front end reports `LEX-INVALID-UTF8` at the first byte of the first sequence that does not decode (overlong forms, surrogates, code points above U+10FFFF and truncated sequences count), in the root file or in an imported file. The Racket front end used to replace such bytes with U+FFFD and go on. A source file has no size limit in either front end, so a file over 1 MiB compiles.
- **`FileInfo` has three more fields**, after `modified_seconds`: `mode` (the permission bits with setuid, setgid and sticky, so `rw-------` is 384), `user_id` and `group_id`. `File.stat` fills them, and `IO.inspect` of a `FileInfo` shows them. The error for a bad `File.open` mode now lists `create_private`. (#288)
- **Child processes no longer get `AGENTICA_VM_METRICS` or `AGENTICA_VM_METRICS_FILE`.** Every `Process.spawn*` drops both names from the environment it passes on (§28.5, done early so that the BDD driver port keeps the runner clear of them); `System.env` still shows them to the program. (#288)
- **Source paths in the bytecode are relative to the project root.** An `.agcb` stores each source file as its path from the folder of the entry file (`main.agc`, `lib/util.agc`, `../shared/x.agc`, `std/NAME.agc`), not an absolute path, so the bytes no longer depend on where the program was built (roadmap row 7.2.7, §35.4 "Source paths"; the Racket front end and `compiler/` change together). Runtime errors and stack traces read the file from the bytecode: `agentica` passes the new `agentica-vm --source-root DIR` option, so the entry file prints as before (`examples/hello.agc:3:5`) and an imported file prints relative to the working directory (`examples/lib/util.agc`) where it printed an absolute path. Compile-time errors print as before. `agentica-vm x.agcb` alone prints the stored names.
- **Breaking:** the import syntax. `import Models from "models"` replaces `import "models" as Models`; the path-first form is now `PARSE-UNEXPECTED-TOKEN` at the string, with the help `write import Alias from "path"`. Only the alias form changes; paths, `std/` and `pkg/`, and the `CHECK-IMPORT-*` codes are as before. Move every import of your programs and of `pkg/` libraries: the regular expression `import\s+("[^"]*")\s+as\s+(\w+)` with the replacement `import $2 from $1` rewrites a file. The help texts that showed the old form (an unknown alias, an unknown `BDD.` or `HTTP.` function, a bad import path) show the new one. The repository's own `.agc` files, goldens, docs and skills are migrated. (#268)
- **Breaking:** `value.with(...)` is always the struct update. A struct field of function type (`Fn[...]`) named `with` is `CHECK-REDEFINED-NAME`, since `user.with(...)` could no longer call it; `with` stays an ordinary name everywhere else (not reserved), so a field of another type named `with`, `value.with` without parentheses and `Alias.with(...)` do not change (#253).
- **Breaking:** the bytecode format is version 4 (the new Updates section and the `STRUCT_WITH` instruction). The loader rejects `.agcb` files written by earlier builds; compile the program again with the matching front end (#253).
- **Breaking:** the bytecode format is version 5 (the new Globals section, a slot count that is 0 in every program for now, and the `GLOBAL` and `GLOBAL_SET` instructions, which nothing emits yet; they are the VM part of module constants, §44). The loader rejects `.agcb` files written by earlier builds; compile the program again with the matching front end.
- **Breaking:** `Set` is a reserved name. A user struct, enum, type parameter or import alias with that name is `CHECK-REDEFINED-NAME` (#250).
- **Breaking:** declaration order. Every `.agc` file keeps one order: the module doc and imports, then `struct` and `enum` declarations (exported or not, in any order), then `export def` functions, then private `def` functions. The first declaration out of place is the new `CHECK-DECL-ORDER`, located at that declaration, with help that says where it goes. This is a style rule only (a function may still call a later one), and it covers the root program, imported files, `std/` modules and BDD test files. Move declarations to fit; the repository's own `compiler/`, `stdlib/`, fixtures and docs examples are already reordered.
- **Breaking:** the new `CHECK-TOO-DEEP` limits the depth of the tree the checker walks: more than 1,000 levels of expressions and statements (each counts one level) stops at the node that passes the limit, with help to split the code. The parser limit does not bound it, since the right operand of the first operator of a chain hangs below the whole chain, so a legal program could be deeper than the self-hosted checker can walk within the VM call limit of 10,000. A single chain of 1,000 operators already fails in the parser (`PARSE-TOO-DEEP`) and 998 still passes; what newly fails is nested chains and other deep mixes of expressions and statements that the parser accepted (#263).
- **Breaking:** nesting limit. The parser stops at 1,000 levels of nesting with the new `PARSE-TOO-DEEP` (statements, expressions, prefix operators, type arguments, and each operator or `.` suffix of a chain, chains included in the count). It was unlimited, so code nested deeper than 1,000 levels, or with a chain of more than about 1,000 operators, parsed before and now fails. The self-hosted parser must stay inside the VM call limit of 10,000.
- **"Did you mean" help for `CHECK-IMPORT-NAME`.** When `M.name` is not an export of the imported module `M`, the help now suggests the closest export (`did you mean "warning"?` for `Logger.warnin`). Only exports are candidates, so a private name is never suggested; the `std/http` and `Logger.error` helps still win, and with no close export the help is empty as before. Message text only: same code and span (D9) (#247).
- **Stack traces in `agentica test`.** A test whose task crashes with a runtime error now shows the call stack under its diagnostic in the text report (`  stack, innermost first:`, or ` | stack ...` with `--ai`) and has `stack`, `stack_omitted` and `spawned_at` in its `--json` error, as a halt outside a test already had. The same stack lines show for a BDD scenario whose step crashed (#235).
- Function names and file paths in a stack line are cut to 256 bytes (at a character boundary, ending with `...`) in the plain, `--ai` and `--json` formats, so a hostile `.agcb` with a huge name cannot make the stack print it 20 times (#235).
- **Breaking:** `LogEvent` and `LogLevel` (new builtin types of `std/logger`) and `LogRegistry` (its internal module) are reserved names. A user struct, enum or alias with one of these names is `CHECK-REDEFINED-NAME` (#246).
- **Breaking:** `Await` is a reserved name. A user struct, enum, type parameter or import alias with that name is `CHECK-REDEFINED-NAME` (#217).
- **Faster lists:** `push` and `set` on lists are now near constant time, and building a list with n pushes is O(n); a loop of 160,000 pushes took about a minute and now takes 0.1 s. Indexing costs at most 4 loads up to a million items instead of one. `List.repeat` shares one block of items, so a million items cost almost nothing. Output, diagnostics and `--max-steps` counts do not change. `push`, `set` and a `concat` with 32 items or fewer no longer cost turn units, so a task that loops on them yields later, and the order of output between tasks that run at the same time may shift (#221).
- **Faster list bulk operations:** on a million items, `sort` takes 17 ms for a list in order or strictly descending and 100 ms for a scattered one (190 and 320 ms before), because it reads the keys once and compares them as numbers; `String.split(text, "")` takes 9 ms (85 ms before) because one-character ASCII pieces are shared Strings; `take`, `drop` from a multiple of 32 and `concat` reuse the leaves of the source list instead of copying every item; and `join`, `map` and `Range.to_a` read and write a list without a call per item. Results and diagnostics are unchanged.
- **Numeric lists use half the memory:** a list whose items are all `Int`, or all `Float`, keeps 8 bytes per item and no tag, so a million items take 8 MB instead of 16 MB, and the collector does not scan them. `sort` of such a list is about 30% faster (a million scattered `Int`s: 100 ms before, 71 ms now), `take`, `drop` and `concat` about 3 times faster, and building and pushing a little faster. Lists of other types, output, diagnostics, `--max-steps` counts and the bytecode format do not change (#238).

### Fixed

- **A generic enum where another generic enum is expected** (`Wrap.Holder(Other.Item(1))` when the payload is `Box[T]`) crashed the checker with a Racket exception. It is `CHECK-TYPE-MISMATCH` now (#263).
- When the `agentica test` runner itself crashes, the `RUNTIME-BDD-INFRA` message names the error (its code and message) instead of the last stack frame (#235).
- The `RUNTIME-BDD-INFRA` message for a crashed runner names its final diagnostic, even when an earlier task crash was printed first (#243).
- The `agentica test` report says `... 1 frame not shown ...` for one omitted frame, as the VM does (#243).

## [0.2.0] - 2026-10-14

Every program now runs on a new C bytecode VM, the Racket evaluator is gone, and the language gained a Ruby-style surface, tasks that isolate crashes, channels, a unit test framework, and TCP, TLS and HTTP on the VM.

### Added

- **Ruby-style forms.** `!`, `&&` and `||` as `not`, `and` and `or`; compound assignment `+=`, `-=`, `*=`, `/=`, `%=` (#25).
- **String interpolation:** `"total: #{n + 1}"`, with `\#` for a literal `#` (#27).
- **Methods on builtin values** (`s.strip.size`, `xs.push(1)`, `r.ok?`), resolved by type, with Ruby aliases such as `to_i`, `to_s`, `size`, `include?` and `join`; unknown names are `CHECK-UNKNOWN-METHOD` (#26).
- **Blocks and closures:** `xs.map do |x| x * 2 end`, `&name` function values and `f.call(...)`, usable anywhere a `Fn` is (#28, #74). New `List.each`, `List.any?` and `List.all?`.
- **`break` and `next`** in `while` and `for` loops; outside a loop they are `CHECK-LOOP-CONTROL` (#34).
- **Printing and text of any value:** `puts`, `print`, `IO.puts`, `IO.print` and `IO.warn` take any value with `to_s`, and every data value has `x.to_s` and `x.inspect` (#36, #37).
- **Accepted spellings from agent runs:** `Result.Ok(x)` and `Result.Err(m)` as values and `ok(v)`/`error(m)` as `case` patterns, nullary enum variants without parentheses (`Command.Show`), top-level `print`, `gets` and `gets!`, an optional `do` after `case`, `while` and `for` headers, and one-line `case` arms (#33, #35).
- **Ranges:** `a..b` and `a...b`, `for x in range` without building a list, `Range` methods, and `Int.times`, `Int.upto` and `Int.downto` with a block (#76).
- **Pipe operator:** `x |> f(a, b)` means `f(x, a, b)`; new `PARSE-PIPE-TARGET` and `CHECK-PIPE-METHOD` (#182).
- **Digit separators:** `1_000` and `1_000.000_5`; a bad `_` is the new `LEX-INVALID-NUMBER` (#203).
- **Doc comments:** a line that starts with `##` documents the next `def`, `struct`, `enum`, field or variant, or the module when it comes first; a block that documents nothing is `PARSE-DETACHED-DOC`. Every `std/` module now has a module doc and a doc on each export (#208).
- **Everyday library:** `List.sort` and `List.sort_by`, `String.index_of`, `at`, `reverse`, `code` and `from_code`, `Float.from_int`, `Float.to_int` and `to_int!`, `Time.now_ms`, `Time.monotonic_ms`, `Random.int` and `Random.float`, and `--seed N` for repeatable runs (#22).
- **Modules:** the embedded standard library with `std/queue`, and `pkg/` imports from project-local, `AGENTICA_PATH`, user-data and system roots (#19).
- **`Channel[T]`:** bounded channels between tasks with `Channel.new`, `send`, `recv`, `close` and `closed?`, with timeouts; `Task.await` cycles are `RUNTIME-TASK-AWAIT-CYCLE` (#179).
- **Tasks:** `Task.pending_count()` (#129), `Task.unobserved_crash()` (#139), and `Task.spawn_owning` to hand a handle to a task (#197).
- **Unit tests:** the builtin `Test` module (`Test.test`, `Test.run`, `Test.eq`, `Test.ok?`, `Test.error?`, `Test.assert`), and `agentica test` now also runs `*_test.agc` files, with `--only TEXT`, a default `test/` folder and one report with the BDD features (#147, #151, #155, #158).
- **BDD in Agentica:** `import "std/bdd"` provides the step API, and `Process.spawn_captured` and `Process.output` support it; Gherkin parsing, step matching and the report are written in Agentica (#128, #129, #130, #131, #132, #133, #134).
- **Process channel:** `Process.spawn_channel` and the child-side `Process.parent_read_line` and `Process.parent_send` open a private line channel to a child on fd 3, with `channel_read_line`, `channel_send`, `channel_close` and `read_available` on the parent side (#193).
- **`File.each_line(path, buffer_bytes, timeout_ms) do |line| ... end`** reads a big file one line at a time (#190).
- **Networking on the VM:** TCP (#106), TLS on OpenSSL 3 (#117), and `std/http` with an HTTP/1.1 client with pooled keep-alive connections (#118) and a server with `listen` and `listen_tls` (#165, #166). `examples/http_server.agc` shows the server.
- **VM options:** `--flush-timeout MS` and `AGENTICA_FLUSH_TIMEOUT_MS` bound the wait for file data and buffered output at the end of a run (default 30000) (#177); `AGENTICA_VM_TRACE=sched,io,proc,loader,gc,tls` (or `all`) traces VM internals, and `AGENTICA_VM` names the VM binary (#102, #103).
- **`agentica compile file.agc -o file.agcb`** and `--dump-ir` for the bytecode, and the VM tail-calls `return f(...)` of a user function, so tail recursion runs at any depth (#40, #54).
- **Better help for agents:** `agentica --help` and `agentica help` list the subcommands and five core rules (#198), and many diagnostics got concrete `help` text for habits from other languages, semicolons and braces, comments, `s[0]`, Int/Float mixing and captured assignment (#30, #195, #200, #201). `CHECK-UNUSED-VALUE` flags an ignored builtin result (#26).
- **Documentation site** built with Hugo: getting started, a language tour, one page per library module with runnable examples that CI checks, search, a "Copy page" button, `llms.txt`, and pages on the VM and on design decisions. It shows the current version and links to its GitHub release (#50, #56, #141, #152, #153, #186, #188, #206).
- **Release archive** ships `agentica-vm` next to `agentica`, built against glibc 2.28, with the licenses of the bundled libraries (#103, #117).

### Changed

- **Breaking:** the Racket evaluator is deleted and every program runs on the C bytecode VM (`agentica-vm`, found next to `agentica`, in `dist/`, or from `AGENTICA_VM`; a missing VM exits 2). The fallbacks for `TCP`, `TLS`, `HTTP` and `BDD` and the interim `--vm` and `--legacy-eval` flags are gone with it. Seeded `Random` values differ from 0.1.0 for the same seed, and each task has its own generator (#55, #103, #137).
- **Breaking:** the builtin `HTTP` module is removed. Use `import "std/http" as HTTP` (`HTTP` is now a free alias, no longer reserved). The API changed: a handler returns `ok(HttpResponse(...))`, and the streaming calls (`request_stream`, `read`, `text`, `close_body`, `trailers`, `begin`, `write`, `write_bytes`, `finish`, `respond`) are gone; the checker hints at the replacement (#137, #118, #165, #166).
- **Breaking:** the `BDD.*` builtins are removed. Step programs `import "std/bdd" as BDD` and use its context API (`BDD.step(pattern, handler)` with `Fn[Context, List[String], Context]`, `BDD.run`); `--steps` takes one program, not several. `docs/bdd.md` lists the differences (#133).
- **Breaking:** a runtime error in a task other than `main` now ends only that task. `Task.await` of it gives `error("task crashed: ...")` for a `Result` and otherwise halts with `RUNTIME-TASK-CRASHED`; if `main` returns and no await saw a crash, the run exits 1 with one summary line (#139).
- **Breaking:** a handle (file, TCP/TLS socket, listener, process, HTTP server) belongs to the task that opened it and is closed when that task ends, also on return. A handle opened in a helper and returned through `Task.await` is closed; hand it over with `Task.spawn_owning(&f, handle)`, which fails with `RUNTIME-HANDLE-NOT-OWNED` when the caller does not own it, and `CHECK-NOT-A-HANDLE` when the argument is not a handle. Plain `Task.spawn(&f, handle)` moves nothing (#197).
- **Breaking:** the line protocol of `agentica test` and BDD between the runner and its child moved from stdin and stdout to a private pipe on fd 3 (`AGENTICA_CHANNEL=3`). A test's stdin and stdout are its own again, the run token and record marker are gone, a second `Test.run` is `RUNTIME-TEST-RUN`, and a child process sees only stdin, stdout and stderr (plus the channel when it asks for one) (#193).
- **Breaking:** reserved names. New: `Range` (#76), `Channel` (#179), `Time` and `Random` (#22), `Test` and `TestCase` (#147), `HttpWire` and `HttpResponse` (#118), and `ProcessOutput` (#128). A user struct, enum, function or import alias with one of these names is `CHECK-REDEFINED-NAME`. `print`, `gets` and `gets!` can no longer be declared as functions, variables, parameters or loop variables (#33). `BDD` is free again.
- **Breaking:** imports name the module without `.agc`: `import "models" as Models`. A path ending in `.agc`, an empty path, a trailing `/` or a dot in the last part is `CHECK-IMPORT-PATH` (#116).
- **Breaking:** each `def`, `struct` or `enum` must be followed by a blank line before the next declaration (`PARSE-MISSING-BLANK-LINE`) (#29).
- **Breaking:** a line that starts with `##` is now a doc comment; one inside a function body or not followed by a declaration is `PARSE-DETACHED-DOC`. `##` after code and inside strings stays plain text (#208).
- **Breaking:** `#{` inside a string starts an interpolation; write `\#{` for the old text (#27).
- **Breaking:** `String.split` keeps every empty part, so `"a\n".split("\n")` is `["a", ""]` (#57).
- **Breaking:** field access on a non-struct value is a method call and unknown names are `CHECK-UNKNOWN-METHOD` (replaces `CHECK-NOT-A-STRUCT`); `IO.puts`, `IO.print` and `IO.warn` take any value, not only `String`; interpolating a `Json` value inserts its JSON text; functions, tasks and resource handles have no `to_s` and are `CHECK-TYPE-MISMATCH` (#26, #36).
- **Breaking:** a named CA file that is missing or empty is now an error at connect (the evaluator ignored it) (#117).
- **Breaking:** `Process.spawn` looks a bare command name up in `PATH` only and never adds the current directory; a name with `/` is a path from the working directory (#98).
- **Breaking:** TCP, TLS, `Process`, `Channel` waits and the other loop-based I/O run on Linux only; other systems have no such builtins in the VM, and the evaluator that ran them there is gone (#98, #106, #117, #179).
- Runtime messages for file calls say `filesystem:` instead of `network:` for a bad timeout (#190).
- The programming skill is split into `SKILL.md` and on-demand references, with its token cost cut (#32, #204).
- License: Apache-2.0 with LLVM exception (#97).
- A default build links the system OpenSSL 3 and libgc 8.2 or newer (`AGENTICA_OPENSSL` and `AGENTICA_GC` choose `vendored`); the release archive is built with both vendored (#146, #185).
- Internal: CI, the golden test harness, the C style and layer checks, fuzzing, sanitizers, benchmarks, the evaluation harness, the plan documents and the roadmap restructure changed with no effect on programs.

### Fixed

- A stop signal (`SIGINT`, `SIGTERM`, `SIGHUP`) ends the VM through one bounded exit path that kills children and flushes output; reading `/proc/self/fd/N` of the VM's own pipe no longer hangs it at exit (#162).
- Pipes, FIFOs, terminals and stdin are read on the event loop, so a silent FIFO no longer holds a thread or the exit (#164).
- `puts`, `print`, `IO.inspect` and `IO.warn` no longer block the whole VM on a full stdout or stderr pipe; only the printing tasks wait (#187).
- `Process.close` no longer blocks the VM while it waits for the child (#176).
- Imported structs and enums print by their declared names (`Point(x: 2)`), and checker messages name imported types and functions the same way, instead of the linker's `@2::Point` (#73).

## [0.1.0] - 2026-10-04

First tagged release of the Agentica interpreter: a small statically typed
language, written in Racket, designed so an AI agent can write, run, and repair
programs from stable diagnostics.

### Added

- **Pipeline and CLI.** Lexer, parser, checker, and evaluator as separate
  modules, driven by `agentica`. Run a program, `check` it without running,
  `--dump` the checked tree, and query a builtin with
  `agentica help NAME --json`. Exit codes: `0` ran, `1` a diagnostic, `2` bad
  usage or an unreadable file.
- **Language core.** `Int`, `Float`, `Bool`, `String`, `Void`, and `Nil`;
  `List[T]`, `Map[K, V]`, `Result[T]`, and `Json`; structs with named fields;
  functions with `Fn[A, ..., R]` values; `if`/`elsif`/`else`, `while`, and
  `for`; full operator precedence; block scopes with a no-shadowing rule; and
  return analysis that requires every reachable path to return.
- **Builtin modules.** `String`, `List`, `Map`, `Result`, `IO`, `System`,
  `File`, `Dir`, `Path`, `JSON`, `TCP`, `TLS`, `HTTP`, `Process`, `Task`, and
  `BDD`, documented from one shared catalog that also types and executes them.
- **Typed JSON.** Decode JSON into declared structs and type expressions,
  encode structs, maps, and lists, extract values with located-path `Result`
  errors, build dynamic documents, and generate JSON schemas.
- **Result and propagation.** `ok`/`error`, the `Result` module, and `try`,
  which unwraps a success or returns the error from the enclosing
  `Result`-returning function.
- **File modules and imports.** Relative `.agc` imports with uppercase aliases,
  explicit `export`, private unexported names, canonical-path deduplication,
  and cycle rejection. Imported declarations share one evaluation, budget, and
  resource ownership.
- **Diagnostics for agents.** Stable stage-prefixed codes (`LEX-`, `PARSE-`,
  `CHECK-`, `RUNTIME-`), file/line/column, a source excerpt with a caret,
  secondary labels, and grounded `= help:` suggestions. `--ai` and `--json`
  print the same diagnostic as compact text or one JSON object.
- **Execution budget.** `--max-steps N` bounds expression and statement
  entries, including loop conditions; exhaustion is `RUNTIME-STEP-LIMIT`.
- **Concurrency.** Lightweight `Task.spawn`/`Task.await`/`Task.sleep` with
  supervision, cached results, cancellation, and a shared step budget.
- **Networking.** TCP, TLS, and a streaming HTTP/1.1 client and server, with
  bounded framing, connection pooling, trailers, and no transparent retries.
- **Processes.** `Process.spawn` and streamed stdin/stdout/stderr behind
  `--allow-run`, with timeouts, 1 MiB per-call bounds, and cleanup on every
  evaluation outcome.
- **BDD.** Gherkin `.feature` specs with typed Agentica step handlers, JSON
  scenario state, and supervised programs under test.
- **Files and paths.** Streamed and whole-file text/byte I/O, metadata,
  recursive `Dir.mkdir`, sorted `Dir.list`, and lexical `Path` helpers.
- **Examples.** `hello`, `classify`, `tasks`, `inventory`, `strings`, `echo`,
  `result`, `json`, `json-config`, `json-expenses`, `json-lines`,
  `knight-tour`, `traveling-salesman`, `maze-bfs`, `dispatch`, `concurrency`,
  `http_get`, `http_server`, `tcp_echo`, `process-tool`, and `json-modules`.
- **Agent tooling.** The `agentica-programming` skill (self-contained language
  reference for writing `.agc` programs), the `agentica-development` skill for
  changing the interpreter, and a Docker/Firejail evaluation harness under
  `tests/eval/`.
- **Release tooling.** `agentica --version`, a `make version` target, and a
  release workflow that builds a distributed executable and publishes a GitHub
  Release when a version tag is pushed.

### Changed

- Diagnostics name the operator token for unary and binary errors, and report
  internal checker states as `CHECK-INTERNAL`.
- `main()` returns `Void`; `nil` remains data and JSON null.
- Maps keep insertion order with immutable hashes; `Map.get/2` returns a
  `Result` and `Map.get/3` an eagerly evaluated default.

[unreleased]: https://github.com/sonic182/agentica/compare/0.2.0...HEAD
[0.2.0]: https://github.com/sonic182/agentica/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
