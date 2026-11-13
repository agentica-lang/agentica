## 7. Diagnostics for agents

Each error has a stable code, a file, a line and a column, a concrete
explanation, and the source line with a mark under the span. Spans travel from
the tokens to the AST.

```text
example.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

When the checker knows the fix, the diagnostic ends with a `= help:` line.

There are no warnings: a program that the compiler accepts has nothing to
report, and what would be a warning in another language is an error with its
own code (for example `CHECK-UNUSED-IMPORT`, `CHECK-UNREACHABLE-CODE`,
`CHECK-UNUSED-VARIABLE` and `CHECK-UNUSED-RESULT`).

A compile-time diagnostic names the first file as you typed it and an imported
file by its absolute path. A runtime diagnostic and the frames of its stack name
each file as you can open it from the working directory: `agentica
examples/hello.agc` reports `examples/hello.agc:3:5` and
`examples/lib/util.agc:7:11`, and a standard module is `std/NAME.agc`. The
bytecode stores each file relative to the folder of the first file (`hello.agc`,
`lib/util.agc`, `../shared/x.agc`), so it is the same wherever the program was
built; `agentica` puts the folder you typed before those names, and `agentica
run` alone prints them as stored.

`agentica --ai` and `agentica --json` print the same diagnostic as compact text,
or as one JSON object. In `--json` mode, when a diagnostic ends the run, it is
the last line of stderr, except that a warning about the flush of files or
output (§6) can follow it when the end-of-run flush fails or runs out of time.
Task crash lines (with `"task": true`), the unobserved-crash summary
(`{"unobserved_crashes": N, "first": "..."}`) and the flush warning of §6 are
not the run's diagnostic.

A runtime diagnostic of a running task also shows the call stack of the task
that failed, innermost frame first, in all three formats. There is no flag. The
stack is shown when the failing task has more than one frame or is not `main`; a
failure directly in `main` looks as it does without a stack.

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

A frame line is the function's declared name and the place it was running. For
the innermost frame that is the place of the error, and for each caller it is
the call it waits on. A block shows as `block` and a lambda as `lambda`, a
function from an imported file shows its name (the file is in the place), and
the builtins that run a block (`xs.map`) are skipped, since the frame below
already points at the call. A frame that a tail call replaced is gone: the
frame left ends with `(after a tail call)`, so a reader knows that callers are
missing there. Neighbouring frames with the same function and place are one
line with a count, as in `walk at tree.agc:9:12 (9998 times)`, so a runaway
recursion that ends in `RUNTIME-STACK-OVERFLOW` takes a few lines. After that
merge at most 20 lines show: the 15 innermost, a line `... 312 frames not
shown ...`, and the 5 outermost. A task's stack ends with the task's function,
and a last line `task spawned at file:line:column` gives the place of the
`Task.spawn` call that started it. A function name or file path longer than 256
bytes is cut there, at a character boundary, and ends with `...`.

`--ai` puts the same lines under `  stack:` after the `source:` line. `--json`
adds a `stack` array of objects with the keys `column`, `file`, `function` and
`line` (and `repeat` for a merged line, `tail: true` after a tail call),
innermost first; `stack_omitted` with the number of frames not shown; and, for a
task, `spawned_at` with `column`, `file` and `line`. The keys stay sorted, so
`spawned_at`, `stack` and `stack_omitted` come after `range` and before `task`.
Every `RUNTIME-` diagnostic that is raised while a task runs has the stack,
`RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` included, and so does a task
crash line. `System.exit`, the out-of-memory exit, and failures outside any task
(the stall check `every task is waiting and nothing can wake them`, a failed
flush of output) have none.

The code carries the prefix of the stage that failed: `LEX-`, `PARSE-`, `CHECK-`
(before running), or `RUNTIME-` (while running). The VM compiler stages use
`LOWER-` and `BYTECODE-`. Each stage stops at the first error. The diagnostics
that an agent most needs to tell apart are: invalid syntax, unknown name,
incompatible type, wrong arity, unknown or missing field, missing return, and
runtime error.

`QUERY-` is the prefix of the query commands (`agentica outline`, `agentica
type-at`, `agentica refs`, `agentica symbol`). A mistake in the question is
`QUERY-USAGE`: a missing or extra argument, an unknown option, `--stdin` without
a file, a bad `FILE:LINE:COL`, or a path that cannot be read. It is located at
the pseudo-file `<arguments>`, line 1, column 1, and the command exits 2.
`QUERY-NO-EXPRESSION` is a `type-at` or `refs` position that is on no token of
an expression (a blank between tokens, a comment, a keyword, past the end of a
line or of the file), or a `refs` position on a module alias or a path of an
import line (a module is not a declaration); it is located at the position in
the file (the empty span at the end of the line or of the file when the position
is past it) and exits 2. `QUERY-NOT-FOUND` is a `symbol` or `refs` NAME that no
linked module declares and the catalog lacks, or a `help std/MODULE[.NAME]`
module or export that does not exist; it is located at `<arguments>`,
may carry a "did you mean" help, and exits 2. `QUERY-AMBIGUOUS-NAME` is a `refs`
NAME that more than one declaration answers to; it is located at `<arguments>`,
its help lists each candidate as `FILE:LINE:COL`, and it exits 2. A `LEX-`,
`PARSE-` or `CHECK-` error in the queried file exits 1, and wins over a position
that is on no expression. Exit 1 means fix the program, exit 2 fix the question.
A usage error is a diagnostic too, so with `--json` it is JSON as well.

`FMT-` is the prefix of `agentica fmt`. `FMT-USAGE` is a mistake in the call
(an unknown option, a wrong form, a missing path, or a folder with no `.agc`
file), located at `<arguments>` as `QUERY-USAGE` is, with exit 2. A file named
in the call is formatted whatever its extension, as `check` does. `FMT-INTERNAL`
is a file whose formatted text would not keep its tree or its comments; the
file is left as it is, and the command exits 1, as for a file that does not
parse.

`LINT-` is the prefix of `agentica lint`. A `LINT-` code is a suggestion from
the style guide, or a likely typo (`LINT-ERROR-KIND`), not an error: the
program is valid without it, and the command exits 0 unless `--strict` is
given. A suggestion has a source span and a help that names the form to write.

Names and forms from other languages get a `help` that names the Agentica form
(`len(x)`, `elif`, `let x = 5`, `Mutex.new`, `Agent.start_link`, `Thread.new`, a
Ruby String method Agentica lacks): those without a code of their own are in the
tables of `compiler/check/check_tables.agc` and the parser, and tests assert the
code, never the help text. A method hint is given only when the suggested method
exists for the receiver's type. The help text of every diagnostic is in
`compiler/`, and `agentica --json check` prints it. The common triggers of a
code that is not obvious from its section:

- `x = 1;` (`LEX-UNEXPECTED-CHAR`)
- `'+'`, `'abc'`, `` `abc` `` (`LEX-UNEXPECTED-CHAR`)
- bytes that are not valid UTF-8 in a source file (`LEX-INVALID-UTF8`)
- `xs << x` (`PARSE-UNEXPECTED-TOKEN`)
- `<<NAME`, `<<-NAME`, `<<~'NAME'`, `<<~name` (`LEX-UNEXPECTED-CHAR`)
- a heredoc with one line of text or none (`LEX-HEREDOC-ONE-LINE`)
- a tab in the indentation of a heredoc (`LEX-HEREDOC-INDENT`), a heredoc with
  no end line (`LEX-UNTERMINATED-HEREDOC`)
- a `<%` tag with no `%>` on its line in an `<<~EAG` template
  (`PARSE-EAG-UNTERMINATED-TAG`)
- an `<% end %>` with nothing to close, or an `<% if %>`, `<% for %>`, `<% while
  %>`, `<% case %>` or a tag with `do` that the template never ends
  (`PARSE-EAG-BLOCK`)
- a `<%@ %>` directive of an `<<~EAG` template that is not `escape function`, is
  not on the first line of the body, or comes twice (`PARSE-EAG-DIRECTIVE`)
- an `<<~EAG` template in a file that does not import `std/eag`
  (`CHECK-EAG-IMPORT`)
- `// note`, `/* note */` (`PARSE-UNEXPECTED-TOKEN`)
- `/a+` with no closing `/` on the line, or a line that starts with `/ 2`
  (`LEX-UNTERMINATED-REGEX`)
- `/a[/]b/` (`LEX-UNTERMINATED-REGEX`)
- `/#{name}/` (`LEX-REGEX-INTERPOLATION`)
- `/a/x`, `/a/ii` (`LEX-REGEX-FLAG`)
- `/a+/` in a file that does not import `std/regex` (`CHECK-REGEX-IMPORT`)
- `/ab)/`, `/a{2,1}/` (`CHECK-INVALID-REGEX`)
- `puts /x/` (`PARSE-UNEXPECTED-TOKEN`)
- a `##` doc block that is not directly above a `def`, `struct`, `enum`, field
  or variant (`PARSE-DETACHED-DOC`)
- a function before a `struct`, `enum` or type alias, a constant after a
  declaration that is not an import, a re-export or a constant, an `import`
  after a declaration or a re-export (`CHECK-DECL-ORDER`)
- `def edge(xs: List[Int], end: Int)`, `in = 1` or a field `do: Int`
  (`PARSE-RESERVED-WORD`)
- `some(x), none -> ...` (`CHECK-CASE-ARM-BINDING`)
- a statement or an extra `end` at the top level (`PARSE-TOP-LEVEL-STATEMENT`)
- `n * 1.5` with an Int `n` (`CHECK-TYPE-MISMATCH`)
- `a < b` on Strings (`CHECK-TYPE-MISMATCH`)
- `while x {`, `if x {`, `else {`, `for x in xs {`, `case x {`, `def f() -> T
  {`, `do \|x\| {` (`PARSE-UNEXPECTED-TOKEN`)
- a `}` with no `{` open (`LEX-UNMATCHED-DELIMITER`), an unclosed `{`
  (`LEX-UNCLOSED-DELIMITER`)
- `Logger.error(...)` (`CHECK-IMPORT-NAME`)
- `Request` as a type (`CHECK-UNKNOWN-TYPE`)
- `Channel.new(n)` with no expected type (`CHECK-EXPECTED-TYPE`)
- `ATS.new()` with no expected type (`CHECK-EXPECTED-TYPE`)

Diagnostics refer to Agentica and never expose host exceptions or tracebacks:
the frames of a stack are Agentica functions.
