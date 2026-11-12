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
below: `CHECK-VOID-TYPE` and `CHECK-VOID-VALUE` (`language-program-types.md`)
and `RUNTIME-PROCESS-CLOSE` (a failed explicit process cleanup, at the call
span).

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

Each line is a function and its call place (a block is `block`);
`(after a tail call)` marks a frame whose callers a tail call removed, and a
recursion is one line with `(9998 times)`. Only the 15 innermost and 5 outermost
lines show. A task's stack ends with `task spawned at file:line:column`.
`--json` adds `stack`, `stack_omitted` and, for a task, `spawned_at`.

- `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`,
  `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`: bad character, string or
  bracket. A `;`, a `'` or backtick, a `}` with no `{`, or an unclosed `{` gets
  a help naming the Agentica form (newline, double quotes, `end`).
- `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`, `LEX-HEREDOC-ONE-LINE`:
  heredoc rules in `language-statements-expressions.md`. A malformed opener
  (`<<NAME`, `<<-NAME`, `<<~'NAME'`, `<<~name`) is `LEX-UNEXPECTED-CHAR`;
  `xs << x` is `PARSE-UNEXPECTED-TOKEN`.
- `LEX-INVALID-UTF8`: a source file (the one you run or an import) holds bytes
  that are not UTF-8; the span is the first bad byte.
- `LEX-INVALID-NUMBER`: a `_` not between two digits (`1_`, `1__0`, `1._5`), or
  a bad digit in a `0x`, `0b` or `0o` literal.
- `LEX-UNTERMINATED-REGEX`, `LEX-REGEX-INTERPOLATION`, `LEX-REGEX-FLAG`: a regex
  literal with no closing `/` on its line (a `/` inside `[...]` ends it: write
  `\/`), with `#{` in the body, or with a flag other than `i` and `m` or a
  repeated one.
- `PARSE-UNEXPECTED-TOKEN`: the parser expected something else. The help says
  when you wrote braces for a block, `//` or `/*` for a comment, or
  `value.with()` / `value.with(31)` (name each field).
- `PARSE-RESERVED-WORD`: a reserved word (`end`, `in`, `do`, `case`, ...) where
  a name goes; pick another name (`last` for `end`).
- `PARSE-UNCLOSED-BLOCK`: a `def`, `if`, `case`, loop or `do` block with no
  `end` before the end of the file (the span is the end of the file: look for
  the block never closed). A block left open before the next `def` is
  `PARSE-UNEXPECTED-TOKEN` at that `def`.
- `PARSE-MISSING-BLANK-LINE`: no blank line between the `end` of a declaration
  and the next one (a `##` doc block goes after the blank line).
- `PARSE-DETACHED-DOC`: a `##` block not directly above a `def`, `struct`,
  `enum`, field or variant.
- `PARSE-TOP-LEVEL-STATEMENT`: a statement outside a function, or an extra `end`
  (a stray `else` or `elsif` has no `if`).
- `PARSE-TOO-DEEP`: more than 1,000 levels of nesting; each operator of a chain
  or `.` suffix counts a level.
- `PARSE-INVALID-ASSIGNMENT-TARGET`: assignment to an index or field, or to a
  constant inside a function.
- `PARSE-CONSTANT-NAME`: a top-level `Name = ...` whose name is not capitals,
  digits and `_` of two or more characters.
- `PARSE-PIPE-TARGET`: the right side of `|>` is not a call written with
  parentheses (a bare name, field, index, `f(1).g`, `U.f do ... end`).
- `CHECK-TYPE-MISMATCH`: a value, operand, condition, argument or return has the
  wrong type; also printing or interpolating a function, task or handle. Int
  with Float needs `n.to_f` or `x.to_i!`; String with a number `s.to_i!` or
  `n.to_s`; `<` orders only numbers.
- `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD`: a name,
  type or field that does not exist (`continue` says `next`, `Map.new` says to
  annotate `{}`).
- `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING`:
  duplicate declaration, shadowing, an annotation on an existing name; an `Fn`
  field named `with` (`value.with(...)` is the struct update).
- `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`: a parameter without a default
  after one with a default (only a last `Fn` parameter may); a default that is
  not a constant (`language-program-types.md`).
- `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`, `CHECK-EMPTY-SET-TYPE`,
  `CHECK-RESULT-TYPE`, `CHECK-OPTIONAL-TYPE`, `CHECK-EXPECTED-TYPE`: `[]`, `{}`,
  `Set.new([])`, `error(...)`, `none`, `Channel.new(n)` or `ATS.new()` with no
  expected type: annotate the variable.
- `CHECK-TRY-CONTEXT`: `try` in a function or block not returning a Result (a
  `Lazy` method block accepts any `try`: its failure ends the pipeline).
- `CHECK-MAIN`: no `main` (for a run or `compile`; `check` needs none), or a
  `main` with parameters or a result other than `Void`.
- `CHECK-TEST-SIGNATURE`, `CHECK-TEST-NAME`, `CHECK-TEST-MAIN`: `testing.md`.
- `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST`: an index on a non-list/map (a
  String uses `s.at(i)` or `s.slice(start, length)`); `for` over something that
  is not a list, set or range.
- `CHECK-UNKNOWN-VARIANT`, `CHECK-ENUM-POSITIONAL-ARGS`,
  `CHECK-ENUM-TYPE-INFERENCE`: unknown enum variant; named arguments to a
  variant; a generic enum or struct type not known from payloads, field values
  or context.
- `CHECK-CASE-ARM-VALUE`: an arm of a `case` that gives a value ends with a
  statement, or has no body; end it with the expression it gives.
- `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`,
  `CHECK-UNREACHABLE-CASE-ARM`: a pattern that does not fit the value; a `case`
  missing variants or `_`; an arm or a pattern already covered.
- `CHECK-ERROR-KIND`: a kind literal in `error(..., kind: "...")` or
  `e.is_a?("...")` that is not a dotted name of `a-z`, `0-9`, `_`.
  `CHECK-ERROR-CONSTRUCTOR`: `Error(...)`; build one with `error(...)`.
- `CHECK-CASE-ARM-BINDING`: an arm of several patterns (`a, b ->`) binds a
  name; write `_`, or one arm per pattern.
- `CHECK-MAP-KEY-TYPE`, `CHECK-SET-ELEMENT-TYPE`: a `Map` or `ATS` key or a
  `Set` element that is not `Int`, `String` or `Bytes`.
- `CHECK-ATS-VALUE`: an `ATS[K, V]` whose `V` is `Nil`, a type parameter, or
  holds a `Fn`, `Task`, `Channel`, handle or table anywhere inside.
- `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`,
  `CHECK-IMPORT-NAME`, `CHECK-IMPORT-RENAME`, `CHECK-UNUSED-IMPORT`: a missing
  or unreadable import; an invalid path (no `.agc`); a cycle; an unknown or
  private imported name (also an alias with no member, `u: User`); a rename
  that breaks the case rule; an alias never used. See `modules.md`.
- `CHECK-IMPORT-PACKAGE`: a package declared in `agentica.toml` is not in
  `deps/` (run `agentica install`), or a package file imports a `pkg/` name its
  own `agentica.toml` does not declare.
- `PKG-MANIFEST-INVALID`, `PKG-LOCK-INVALID`, `PKG-LOCK-MISSING`,
  `PKG-LOCK-STALE`, `PKG-SOURCE-CONFLICT`: `agentica.toml` or `agentica.lock` is
  bad, missing, or disagrees with the other (stale); one name has two sources in
  the project and its packages (conflict). The report names the file and a key
  path such as `dependencies.sqlite.git` (`key_path` in `--json`), or a line and
  column for a TOML syntax error; a missing or unreadable file has only its
  name.
- `PKG-ROOT-ONLY`: `override = true` or a `path` in the `agentica.toml` of a
  package; only the root project's manifest may say them (the key path is
  `dependencies.<name>.override` or `.path`).
- `PKG-AGENTICA-TOO-OLD`: the `agentica` key of the project's or a package's
  `agentica.toml`, or the workspace root's, for a member, asks for a newer
  Agentica than the one running (key path `agentica`); install that version or
  pin a package version made for this one.
- `QUERY-USAGE`, `QUERY-NOT-FOUND`, `QUERY-AMBIGUOUS-NAME` and
  `QUERY-NO-EXPRESSION`: a bad question to a query command, exit 2
  (`queries.md`).
- `PKG-HASH-MISMATCH`, `PKG-SYMLINK`: the `.agc` files of a package in
  `deps/<name>/` or the cache are not the ones the lock hashes (edited, added or
  missing), or one is a symbolic link or submodule. Run `agentica install` again
  for `deps/`; for the cache, remove the package's folder
  (`~/.cache/agentica/pkg`, under `$XDG_CACHE_HOME` when set;
  `%LOCALAPPDATA%\agentica\cache\pkg` on Windows) and run it: a cached folder
  is never overwritten.
- `PKG-NATIVE-PLATFORM`, `PKG-NATIVE-MISSING`, `PKG-NATIVE-ARCHIVE`: a package's
  `[native.NAME]` table has no entry for this system (add `linux`, `macos` or
  `windows`), its `file` is not in the package, a downloaded archive holds no
  file for its `member`, or the download is not a plain or gzipped TAR or a ZIP.
  The key path is in the report (`native.NAME.linux.file`).
- `PKG-NATIVE-BUILD`: a native module's `build` failed (no C compiler, a
  compile error), at `native.NAME.build`. `PKG-NATIVE-UNBUILT` is a warning,
  not an error: an `optional = true` module was not built and the program runs
  without it (`"warning": true` in `--json`).
- `PKG-FETCH`, `PKG-TAG-MOVED`, `PKG-PATH-COLLISION`, `PKG-MANIFEST-MISSING`:
  `agentica install` failed: git failed or the tag or commit does not exist, a
  copied path is unsafe, a file is over 1 MiB (16 MiB in all) or the cache is
  not writable (git's message is in the help); the tag now points to another
  commit than `agentica.lock` (the lock is not changed); two package paths
  differ only in case; no `agentica.toml`.
- `PKG-DEPENDENCY-EXISTS`, `PKG-DEPENDENCY-UNKNOWN`, `PKG-MANIFEST-EDIT`,
  `PKG-WRITE`: `agentica add` or `update` stopped before it wrote anything
  (except `PKG-WRITE`): the name is a dependency already (change its pin in
  `agentica.toml`, then `update NAME`); `update NAME` names no dependency; the
  manifest layout cannot take the one-line edit (write the line by hand); or a
  file cannot be written (`deps/` too).
- `CHECK-CONSTANT-EXPRESSION`, `CHECK-CONSTANT-TYPE`: a constant that is not a
  constant expression, or whose type is not data (`language-program-types.md`).
- `CHECK-DECL-ORDER`: a declaration out of the file order (imports, constants,
  `struct`/`enum`/aliases, `export def`, `def`).
- `CHECK-NOT-DECODABLE`, `CHECK-NOT-ENCODABLE`, `CHECK-JSON-FIELD-PLACE`: a JSON
  target or value with unsupported types; a `JsonField` that is not the direct
  type of a struct field (`json.md`).
- `CHECK-PIPE-METHOD`: `x |> String.upcase()`: a builtin with a method form for
  the left value is written with `.` (`x.upcase`) or piped by the method name
  alone (`x |> upcase()`).
- `CHECK-UNKNOWN-METHOD`: a method not defined for the receiver's type, a method
  call on a struct, or `.with(...)` on a non-struct. Common foreign names get
  the real one (`s.chars` says `s.split("")`, `to_string` says `to_s`).
- `CHECK-UNUSED-VALUE`: the result of a builtin without effects is ignored
  (`xs.push(1)` alone), or of a struct update.
- `CHECK-UNUSED-RESULT`: a `Result` is dropped, as a statement or the last
  statement of a `Void` block, from any call (`Result[Void]` too). Use `try`
  where it is allowed, a `case`, or `.unwrap!`; `_ = f(...)` drops it on
  purpose. `IO.inspect(r)` is exempt, and `Task.spawn(&f)` is not a Result.
- `CHECK-BLOCK-TYPE`: a block parameter has no type from the call, or a lambda
  parameter none from an `Fn` type, and its uses in the body leave no single
  type (`x * 2`: Int or String); annotate (`do |x: Int|`, `->(x: Int) { ... }`).
- `CHECK-CHAIN-AFTER-END`: `.name`, `[i]` or `|>` after the `end` of a `do`
  block; pass a lambda and pipe (`xs |> map(->(x) { f(x) }) |> size()`), write
  a one-line block in braces (`xs.map { |x| f(x) }.size`) or bind the result to
  a name first.
- `CHECK-LOOP-CONTROL`: `break` or `next` outside a `while`/`for` body, or
  inside a block.
- `CHECK-UNUSED-VARIABLE`, `CHECK-UNREACHABLE-CODE`,
  `CHECK-CAPTURED-ASSIGNMENT`: a name never read (`_x` or `_` keeps it), a
  statement that can never run, a block that assigns an outer variable (use
  `for` or `reduce`). See `language-statements-expressions.md`.
- `CHECK-NOT-A-HANDLE`: `Task.spawn_owning` with an argument that is not a
  handle, `Channel[T]`, resource or owned buffer, nor a struct, enum, `List`,
  `Map` or `Result` holding one.
- `CHECK-TOO-DEEP`: more than 1,000 levels of expressions and statements, or
  more than 1,000 type references in an expanded alias.
- `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW`: arithmetic failure
  (also an `ATS.add` past the 64-bit range, which leaves the table unchanged,
  and `abs`, `pow`, `gcd`, `floor`, `ceil` or `round` past the Int range).
- `RUNTIME-INVALID-COUNT`: a count or limit outside its range: `List.repeat`
  0..1048576, a negative `take`/`drop`, shift or `pow` count, `Channel.new`
  capacity 1..1048576, `Task.map` `limit` 1..1024, an `OpenSSL.Random` count
  0..1048576.
- `RUNTIME-INVALID-RANGE`: `Random.int` or `clamp` with min > max (or a NaN
  bound of `x.clamp`).
- `RUNTIME-INVALID-NUMBER`: `s.to_i!`/`to_f!` on bad text, `x.to_i!`, `floor`,
  `ceil` or `round` on NaN or infinity, `Math.sqrt` of a negative number,
  `Float.from_bits32` outside 0..4294967295, a byte item outside 0..255 in an
  `OpenSSL.Digest`, `OpenSSL.HMAC` or `Base64` call.
- `RUNTIME-INVALID-CHARACTER`: `String.code` without exactly one character, or
  `String.from_code` outside Unicode scalar values.
- `RUNTIME-STEP-LIMIT`: the execution step budget is exhausted; the stack shows
  where the loop runs.
- `RUNTIME-STACK-OVERFLOW`: recursion deeper than 10000; the stack shows the
  repeating function once, with its count. Only `return f(...)` tail calls are
  free.
- `RUNTIME-END-OF-INPUT`: `IO.gets!` (or `gets!`) at the end of input; test
  `IO.eof?()` first, or use `IO.gets`, which gives an error Result.
- `RUNTIME-INVALID-DURATION`: a negative `Task.sleep` duration or `Channel`
  timeout, a `Task.await` or `Task.map` `timeout_ms` of 0 or less.
- `RUNTIME-TASK-CANCELLED`, `RUNTIME-TASK-CRASHED`: `Task.await` on a task the
  VM cancelled or that crashed, when `R` is not a `Result`, at the await (the
  message is the crash text). A task can hold a cancelled child's handle by
  receiving it over a channel. `RUNTIME-TASK-CRASHED` is also a BDD step or test
  whose task crashed unawaited.
- `RUNTIME-TASK-AWAIT-CYCLE`: `Task.await` of a task that is waiting for the
  caller, directly or through other awaits, at the await.
- `RUNTIME-HANDLE-NOT-OWNED`: `Task.spawn_owning` of a handle the calling task
  does not own, one already handed over, a closed one (a closed channel too), or
  a view of a buffer (`Native.offset`), at the handle argument.
- `RUNTIME-TEST-*`: `testing.md`. `PARSE-GHERKIN-*`, `CHECK-BDD-*` and
  `RUNTIME-BDD-*`: `bdd.md`.
- `PARSE-EXTERN-*`, `CHECK-NATIVE-LOAD` and `RUNTIME-NATIVE-*`: each is named in
  the rule it breaks in `native.md`.

`LOWER-UNSUPPORTED`: the VM cannot run this form; an interpreter bug to
report.
