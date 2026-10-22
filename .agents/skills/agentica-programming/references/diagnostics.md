# Diagnostics

A failure prints to stderr and exits 1; the run stops at the first error:

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The prefix is the stage: `LEX-`, `PARSE-`, `CHECK-` (before running), `RUNTIME-`
(while running), `PKG-` (manifest, lock, package cache). `QUERY-` is a bad
question to `outline`, `type-at`, `symbol` or `refs`. With `--json`, the
diagnostic that ends the run is the last stderr line, after the program's own
stderr. Expected process failures return error Results. Codes without an entry
below: `CHECK-VOID-TYPE` and `CHECK-VOID-VALUE` (`language.md`) and
`RUNTIME-PROCESS-CLOSE` (a failed explicit process cleanup, at the call span).

A runtime error in a task with more than one frame, or not `main`, also prints
the call stack of the failed task, innermost first, in the plain, `--ai` (under
`  stack:`) and `--json` formats:

```text
nested.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]
index 5 is outside a list of length 3

2 |   return xs[i] + 1
  |             ^
  = stack, innermost first:
    pick at nested.agc:2:13
    load at nested.agc:6:10
    main at nested.agc:11:8
```

Each line is a function and the place it runs (the error for the first, the
call it waits on for the others); a block is `block`, and a builtin that runs
one (`xs.map`) has no line. `(after a tail call)` marks a frame whose callers a
tail call removed; `walk at tree.agc:9:12 (9998 times)` is one line for a
recursion. The 15 innermost and 5 outermost lines show, with `... 312 frames
not shown ...` between. A task ends with `task spawned at file:line:column`.
Runtime traces name files as you can open them from the working directory (a
standard module as `std/NAME.agc`); compile-time errors show the first file as
typed and imports by absolute path. `--json` adds `stack` (objects with
`column`, `file`, `function`, `line`, and `repeat` or `tail`), `stack_omitted`
and, for a task, `spawned_at`; `RUNTIME-STEP-LIMIT`, `RUNTIME-STACK-OVERFLOW`
and a task's crash line (`"task":true`) carry it too.

- `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`,
  `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`: bad character, string or
  bracket. A `;`, a `'` or backtick, a `}` with no `{`, or an unclosed `{` gets
  a help naming the Agentica form (newline, double quotes, `end`).
- `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`, `LEX-HEREDOC-ONE-LINE`: a
  heredoc with no end line (the span is the opener), a tab in the leading
  whitespace of a body or end line (the span is the tab), or fewer than two text
  lines. A malformed opener (`<<NAME`, `<<-NAME`, `<<~'NAME'`, `<<~name`) is
  `LEX-UNEXPECTED-CHAR`; `xs << x` is `PARSE-UNEXPECTED-TOKEN`.
- `LEX-INVALID-UTF8`: a source file (the one you run or an import) holds bytes
  that are not UTF-8; the span is the first bad byte.
- `LEX-INVALID-NUMBER`: a `_` in a number that is not between two digits (`1_`,
  `1__0`, `1_.5`, `1._5`).
- `PARSE-UNEXPECTED-TOKEN`: the parser expected something else. A `{` after
  `def ... -> T`, `if`, `elsif`, `else`, `while`, `for`, `case` or `do |x|` says
  blocks have no braces; `//` or `/*` says comments start with `#`;
  `value.with()` and `value.with(31)` say to name each field.
- `PARSE-UNCLOSED-BLOCK`: missing `end`.
- `PARSE-MISSING-BLANK-LINE`: no blank line between the `end` of a declaration
  and the next one (a `##` doc block belongs to the next declaration: the blank
  line goes before it).
- `PARSE-DETACHED-DOC`: a `##` block not directly above a `def`, `struct`,
  `enum`, field or variant (a blank line, a `#` comment, an `import` or the end
  of the file follows it, or it stands in a function body or inside brackets).
- `PARSE-TOP-LEVEL-STATEMENT`: a statement outside a function, or an extra `end`
  (a stray `else` or `elsif` has no `if`).
- `PARSE-CHAINED-COMPARISON`: `a < b < c`.
- `PARSE-TOO-DEEP`: more than 1,000 levels of nesting (parentheses, brackets,
  blocks, statements, prefix operators, type arguments); chains of operators or
  `.` suffixes count as levels too.
- `PARSE-INVALID-ASSIGNMENT-TARGET`: assignment to an index or field, or to a
  constant inside a function.
- `PARSE-CONSTANT-NAME`: a top-level `Name = ...` whose name is not capitals,
  digits and `_` of two or more characters.
- `PARSE-PIPE-TARGET`: the right side of `|>` is not a call written with
  parentheses (a bare name, field, index, `f(1).g`, `(U.f)`, `U.f do ... end`).
  The call may follow `try` and take a trailing block; `a + 1 |> f()` is
  `f(a + 1)`.
- `CHECK-TYPE-MISMATCH`: a value, operand, condition, argument or return has the
  wrong type; also printing or interpolating a function, task or handle. Int
  with Float needs `n.to_f` or `x.to_i!`; String with a number `s.to_i!` or
  `n.to_s`; `<` orders only numbers.
- `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD`: a name,
  type or field that does not exist (`continue` says `next`, `Map.new` says to
  annotate `{}`); also a field `value.with(...)` names but the struct lacks.
- `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING`:
  duplicate declaration, shadowing, an annotation on an existing name; an `Fn`
  field named `with` (`value.with(...)` is the struct update).
- `CHECK-ARITY`: wrong number of arguments (with defaults, `expects 1 to 2
  arguments`).
- `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`: a parameter without a default
  after one with a default (only a last `Fn` parameter may); a default that is
  not a constant (a literal, `true`, `false`, `nil`, `[]`, `{}` or a
  payload-less enum variant).
- `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD`: struct construction fields.
- `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`: an empty `[]` or `{}` with no
  expected type.
- `CHECK-RESULT-TYPE`: an `error(...)` without an expected Result type.
- `CHECK-EXPECTED-TYPE`: `Channel.new(n)` with no expected type.
- `CHECK-TRY-CONTEXT`: `try` in a function or block not returning a Result (a
  `Lazy` method block accepts any `try`: its failure ends the pipeline).
- `CHECK-MISSING-RETURN`: a path without `return` in a non-`Void` function.
- `CHECK-MAIN`: no `main` (for a run or `compile`; `check` needs none), or a
  `main` with parameters or a result other than `Void`.
- `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST`: an index on a non-list/map (a
  String uses `s.at(i)` or `s.slice(start, length)`); `for` over something that
  is not a list, set or range.
- `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`,
  `CHECK-ENUM-TYPE-INFERENCE`: unknown enum variant; named arguments to a
  variant; a generic enum type not known from payloads or context.
- `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`,
  `CHECK-UNREACHABLE-CASE-ARM`: a pattern that does not fit the value; a `case`
  missing variants or `_`; an arm already covered.
- `CHECK-MAP-KEY-TYPE`: a map key that is not `Int` or `String`.
- `CHECK-SET-ELEMENT-TYPE`, `CHECK-EMPTY-SET-TYPE`: a `Set` element type that is
  not `Int` or `String`; `Set.new([])` with no expected type.
- `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`,
  `CHECK-IMPORT-NAME`: a missing or unreadable import; an invalid path (with
  `.agc` or another extension too); a cycle; an unknown or private imported
  name. A private struct cannot be built or updated with `.with` from another
  module. `Mod.NAME` on a constant is also `CHECK-IMPORT-NAME` (`modules.md`).
- `CHECK-IMPORT-PACKAGE`: a package declared in `agentica.toml` is not in the
  package cache, or a package file imports a `pkg/` name its own `agentica.toml`
  does not declare.
- `PKG-MANIFEST-INVALID`, `PKG-LOCK-INVALID`, `PKG-LOCK-MISSING`,
  `PKG-LOCK-STALE`, `PKG-SOURCE-CONFLICT`: `agentica.toml` or `agentica.lock` is
  bad, missing, or disagrees with the other (stale); one name has two sources in
  the project and its packages (conflict). The report names the file and a key
  path such as `dependencies.sqlite.git` (`key_path` in `--json`), or a line and
  column for a TOML syntax error; a missing or unreadable file has only its
  name. The manifests of all locked packages in the cache are checked before any
  file loads, imported or not.
- `QUERY-USAGE`: a wrong question to `outline`, `type-at`, `symbol` or `refs`: a
  missing or extra argument, an unknown option, `--stdin` without a file, a bad
  `FILE:LINE:COL`, an unreadable path, or a folder with no `*.agc` file. The
  file is `<arguments>` at line 1, column 1; exit 2.
- `QUERY-NOT-FOUND`: `symbol` or `refs` NAME is declared in no linked module and
  no builtin. The help has the closest name and the skipped files. Exit 2.
- `QUERY-AMBIGUOUS-NAME`: `refs` NAME is declared by more than one module; the
  help lists each candidate as `FILE:LINE:COL` to ask again with. Exit 2.
- `QUERY-NO-EXPRESSION`: `type-at` or `refs` was given a position on no
  expression or name: a blank between tokens, a comment, a keyword, past the end
  of a line or file, or (for `refs`) a module alias or path in an import line.
  The span is the position; exit 2.
- `PKG-HASH-MISMATCH`, `PKG-SYMLINK`: the `.agc` files of a package in
  `agc_libs/<name>/` or the cache (or just fetched by `install`) are not the
  ones the lock hashes (edited, added or missing), or one is a symbolic link or
  submodule, or the package's `agentica.toml` is not a regular file. Run
  `agentica vendor` again for a vendored copy; remove the folder and run
  `agentica install` for the cache. `agc_libs/` itself as a link is
  `PKG-SYMLINK` for `vendor`.
- `PKG-FETCH`, `PKG-TAG-MOVED`, `PKG-PATH-COLLISION`, `PKG-MANIFEST-MISSING`:
  `agentica install` failed: git did not start or failed, the tag or commit does
  not exist, a copied path is unsafe, a file is over 1 MiB (16 MiB in all) or
  the cache cannot be written (`PKG-FETCH`, git's message in the help); the tag
  now points to another commit than `agentica.lock` (the lock is not changed);
  two package paths differ only in case; no `agentica.toml` was found. The
  report names the file and the key path of the entry, such as `package[0].tag`.
- `PKG-DEPENDENCY-EXISTS`, `PKG-DEPENDENCY-UNKNOWN`, `PKG-MANIFEST-EDIT`,
  `PKG-WRITE`: `agentica add` or `update` stopped before it wrote anything
  (except `PKG-WRITE`): the name is a dependency already (change its pin in
  `agentica.toml`, then `update NAME`); `update NAME` names no dependency of the
  manifest; the manifest has a layout the one-line edit cannot handle (write the
  line by hand); or `agentica.lock` or `agentica.toml` cannot be written. Fetch
  errors of a new pin are the codes of `install`, at `dependencies.<name>.git`
  (or `.tag`, `.ref`). `agentica vendor` gives `PKG-WRITE` too, at the
  `agc_libs/` file it cannot write.
- `CHECK-IMPORT-RENAME`: `import {A as b}` where the new name breaks the case
  rule of what it renames (struct or enum capitalized, function lowercase,
  constant a constant name).
- `CHECK-CONSTANT-EXPRESSION`: a constant uses a call of your own function,
  `&f`, a block outside a builtin call, `while`, or a builtin with effects.
- `CHECK-CONSTANT-TYPE`: a constant expression whose type is not data
  (`Channel`, `Task`, `Fn`, handles, `Void`).
- `CHECK-CONSTANT-CYCLE`: constants that read each other in a loop.
- `CHECK-DECL-ORDER`: a declaration out of the file order (imports, constants,
  `struct`/`enum`/aliases, `export def`, `def`).
- `CHECK-MODULE-CONTEXT`: raw import/export declarations need module resolution
  before checking.
- `CHECK-NOT-DECODABLE`: a `JSON.decode`/`schema` target that is not a struct or
  has unsupported field types.
- `CHECK-NOT-ENCODABLE`: `JSON.encode` of a type with unsupported nested values
  or Int-keyed maps.
- `CHECK-IMMUTABLE-ASSIGNMENT`: assignment to a `for` variable.
- `CHECK-INT-RANGE`: an integer literal that does not fit in `Int`.
- `CHECK-PIPE-METHOD`: `x |> String.trim()`: a builtin with a method form for
  the left value is written with `.` (`x.trim`).
- `CHECK-UNKNOWN-METHOD`: a method not defined for the receiver's type, a method
  call on a struct, or `.with(...)` on a non-struct. Common foreign names get
  the real one (`s.chars` says `s.split("")`, `to_string` says `to_s`).
- `CHECK-LAZY-NO-STEP`: `File.foreach(...).each do ... end` with no step between
  them (use `File.each_line`).
- `CHECK-UNUSED-VALUE`: the result of a builtin without effects is ignored
  (`xs.push(1)` alone), or of a struct update (`user.with(age: 31)` alone).
- `CHECK-BLOCK-TYPE`: a block parameter has no type from the call (`do |x:
  Int|`).
- `CHECK-BLOCK-TARGET`: a block passed to a function whose last parameter is not
  a `Fn`.
- `CHECK-LOOP-CONTROL`: `break` or `next` outside a `while`/`for` body, or
  inside a block.
- `CHECK-CAPTURED-ASSIGNMENT`: a block assigns to an outer variable (use a `for`
  loop or `reduce`; for `xs.each do |w|` the help shows the loop).
- `CHECK-NOT-A-HANDLE`: `Task.spawn_owning` with an argument that is not a
  `FileHandle`, `Socket`, `Listener`, `Process`, `HttpServer` or `Channel[T]`.
- `CHECK-TYPE-ALIAS-CYCLE`: a type alias that expands to itself.
- `CHECK-TOO-DEEP`: more than 1,000 levels of expressions and statements, or
  more than 1,000 type references in an expanded alias.
- `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`: arithmetic failure.
- `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND`: a list index or map key
  not present.
- `RUNTIME-INVALID-COUNT`: `List.repeat` count outside 0..1048576, or a negative
  `List.take`/`drop` count; `Channel.new` capacity outside 1..1048576; a
  `Task.map` `limit` outside 1..1024; a negative
  `Int.shift_left`/`shift_right`/`shift_right_unsigned` count.
- `RUNTIME-INVALID-NUMBER`: `String.to_int!`/`to_float!` on bad text,
  `Float.to_int!` on NaN or infinity, `Float.from_bits32` outside 0..4294967295,
  a `Crypto.sha256` item outside 0..255.
- `RUNTIME-INVALID-RANGE`: `Random.int` with `min > max`.
- `RUNTIME-INVALID-CHARACTER`: `String.code` without exactly one character, or
  `String.from_code` outside Unicode scalar values.
- `RUNTIME-END-OF-INPUT`: `IO.gets!` with no input left.
- `RUNTIME-UNWRAP-ERROR`: `Result.unwrap!` on an error.
- `RUNTIME-JSON-ENCODE`: `JSON.encode` of a non-finite Float.
- `RUNTIME-STEP-LIMIT`: the execution step budget is exhausted; the stack shows
  where the loop runs.
- `RUNTIME-STACK-OVERFLOW`: recursion deeper than 10000; the stack shows the
  repeating function once, with its count. Only `return f(...)` tail calls are
  free.
- `RUNTIME-INVALID-DURATION`: a negative `Task.sleep` duration, a negative
  `Channel.send`/`recv` timeout, a `Task.await(task, timeout_ms)` or `Task.map`
  `timeout_ms` of 0 or less.
- `RUNTIME-TASK-CANCELLED`: `Task.await` on a task the VM cancelled, when `R` is
  not a `Result`, at the await. A task can hold a cancelled child's handle by
  receiving it over a channel (for example from a `Task.map` item that timed
  out).
- `RUNTIME-TASK-AWAIT-CYCLE`: `Task.await` of a task that is waiting for the
  caller, directly or through other awaits, at the await.
- `RUNTIME-HANDLE-NOT-OWNED`: `Task.spawn_owning` of a handle the calling task
  does not own, one already handed over, or a closed one (a closed channel too),
  at the handle argument.
- `RUNTIME-TASK-CRASHED`: `Task.await` on a crashed task when `R` is not a
  `Result`, at the await; the message is the crash text. Also a BDD step or test
  whose task crashed unawaited.
- `RUNTIME-TEST-ASSERTION`: a failed `Test.eq`, `Test.ok?`, `Test.error?` or
  `Test.assert` in a test, at the assertion.
- `RUNTIME-TEST-ERROR`: a test block returned `error(message)`, at the
  `Test.test` call.
- `RUNTIME-TEST-NAME`: an empty or repeated test name, at that `Test.test` call.
- `RUNTIME-TEST-RUN`: `Test.run` called in a task other than `main`'s own (a
  test, or a task you spawned). Also a call with the `agentica test` arguments
  but no parent channel, and, under `agentica test`, a test file whose `main`
  returns without calling `Test.run` (a `*_test.agc` helper: rename it).
- `RUNTIME-TEST-PENDING-TASKS`: a test returned while tasks it spawned were
  still running.
- `RUNTIME-TEST-TIMEOUT`: under `agentica test`, a test ran longer than 30
  seconds; the rest of its file is not executed.
- `PARSE-EXTERN-TYPE`, `PARSE-EXTERN-NAME`, `PARSE-EXTERN-DEFAULT`,
  `PARSE-EXTERN-ARITY`, `PARSE-EXTERN-LIBRARY`: an `extern` signature with a
  non-C type (the span is the type), a name with `?` or `!`, a parameter with a
  default, more than 64 parameters, or a library that is not a name without `/`
  or an absolute path (`native.md`).
- `RUNTIME-NATIVE-LOAD`, `RUNTIME-NATIVE-DENIED`, `RUNTIME-NATIVE-UNSUPPORTED`:
  the library or function of an extern call was not found (at the extern
  function); or, at load with exit 2, `--deny-native` refused a program with an
  extern function or a `Native.wait_*` call, or the system has no native calls.
- `LOWER-UNSUPPORTED`: the VM cannot run this form (exit 1 before anything
  runs); an interpreter bug to report.

BDD runs (`agentica test`) have their own `PARSE-GHERKIN-*`, `CHECK-BDD-*` and
`RUNTIME-BDD-*` codes: `bdd.md`.
