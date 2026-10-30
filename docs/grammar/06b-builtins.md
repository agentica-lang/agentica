### Methods on builtin types

`receiver.name(args)` calls a builtin whose first parameter has the receiver's
type. The checker picks the module from the static type (`String`, `Bytes`,
`List`, `Map`, `Set`, `Float`, `Result`, `Range`, `Int`, `Json` through `JSON`,
and `JSON.Codec[T]` through `JSON.Codec`); there is no dynamic dispatch.
`s.strip` is `String.trim(s)`, but `"a".from_int` is not a method. The methods
of a codec have no function form: `JSON.Codec.decode(c, s)` is
`CHECK-UNKNOWN-NAME`. Without parentheses, `receiver.name` on a non-struct value
is a method without arguments (`s.length`, `r.ok?`). On a struct, `.name` is a
field. Structs and enums have no methods. The one form on a struct type is
`Type.members`, the list of its fields (`docs/grammar/06-semantics.md`, "Structs
and lists").

Ruby aliases are the module functions named in the library pages: `strip`,
`include?`, `start_with?`, `end_with?`, `push`, `join`, `select`, `key?`,
`to_f`, and `to_s` and `inspect` on any data value. Ruby's other names for a
method work too, and the texts show only the first: `length` and `size` on
`String`, `Bytes`, `List`, `Map`, `Set` and `Range`; `collect` for `map`,
`inject` for `reduce` and `detect` for `find` (on `List` and `Lazy`); `member?`
for `include?` on `Set` and `Range`; `include?` and `member?` for `key?` on
`Map`. Two differ from Ruby: `to_i` and `to_f` on text return a `Result`
(`"abc".to_i` is an error, not `0`), and `to_i!` and `to_f!` halt on bad text.
An unknown method is `CHECK-UNKNOWN-METHOD`.

`x.to_s` is the text `"#{x}"` gives: a `String` as is, a `Json` as its JSON
text, and any other data value in its `inspect` form (`[1, 2]`, `ok(3)`,
`Item(name: "a")`). Inside a list, a `Json` shows as `<Json>`. Functions, tasks,
handles, `C.Pointer` values and resources have no `to_s`, so printing or
interpolating one is `CHECK-TYPE-MISMATCH`. Unlike Ruby, `nil.to_s` is `"nil"`.
`x.inspect` keeps a string's quotes; it is for display, not valid source.

Values are immutable: a method never changes its receiver, so `xs.push(2)`
returns a new list. A builtin without effects whose non-Void result is dropped
is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Builtins with effects,
functions ending in `!`, and builtins that take a function are exempt. A
negative literal receiver needs parentheses: `(-5).to_s`.

### Minimal builtin functions

The [library reference](../../site/content/library/_index.md) describes every
builtin: signatures, behaviour, costs, limits and runtime errors. `agentica help
NAME` prints one signature. This section keeps what the language fixes.

`puts(value)` writes the value's `to_s` and a newline; `print` writes without
one. `gets` and `gets!` are `IO.gets` and `IO.gets!`, and may drop their
parentheses (`line = gets!.strip`). `Map`, `Set` and `List` are builtin modules
whose generic functions the checker treats specially: see
[`List`](../../site/content/library/data-structures/list.md),
[`Map`](../../site/content/library/data-structures/map.md) and
[`Set`](../../site/content/library/data-structures/set.md).

Callbacks (`List.map`, `select`, `reduce`, `each`, `any?`, `all?`, `sort_by`
and the other methods that take a function) take a block, `&name` or a function
variable. Parameter and return types must match exactly, and a `map` callback
returns data, not Void. Annotated block parameters let an empty list or an empty
`reduce` initial value infer its type.

`Lazy[T]` is a lazy pipeline: an immutable recipe of a source and steps, not a
cursor. A `Lazy` has no `==`, no `to_s` and no JSON form (`CHECK-TYPE-MISMATCH`,
`CHECK-NOT-ENCODABLE`); `IO.inspect` prints `<Lazy>`. A `List` method on a
`Lazy` and a step that only `Lazy` has on a `List` or `Range` are
`CHECK-UNKNOWN-METHOD`. A block after `each_slice` on a `List` is
`CHECK-BLOCK-TARGET`, and `File.foreach(...).each do ... end` as one chain is
`CHECK-LAZY-NO-STEP`. A failed `try` in a block of a `Lazy` method ends the
pipeline, whatever the block's result type. Sources, steps and terminals are in
the [`Lazy` page](../../site/content/library/data-structures/lazy.md).

### JSON

`Json`, `JSON` and `JsonField` are reserved. A `Json` value has no constructor,
equality, fields or indexing. The functions, their errors, the schema and the
text they read and write are in the
[`JSON` page](../../site/content/library/text-and-data/json.md). The rules that
the checker enforces:

- `JSON.decode(source, T)`, `JSON.schema(T)` and `JSON.codec(T)` take a named
  struct type, not a value; bare type names are valid only for these three.
  Fields may be Int, Float, Bool, String, lists, String-keyed maps, nested or
  recursive structs, and `Optional` and `JsonField` of those; any other nested
  type, a generic struct or enum instance included, is `CHECK-NOT-DECODABLE`.
- `JSON.encode` and `JSON.from` accept Int, Float, Bool, String, Nil (as
  `null`), Json, lists, String-keyed maps, `Optional` and structs of those,
  whose fields may also be `JsonField`. An instance of a generic struct counts
  by its fields after substitution (`Box[List[Int]]`). Results, other enums and
  Int-keyed maps are `CHECK-NOT-ENCODABLE`. Untyped empty containers need an
  annotation.
- `JSON.codec(T)` takes the targets of `decode`, with its diagnostics, and
  returns a `JSON.Codec[T]`: the JSON of `T` as a value, for generic code, which
  cannot call `decode` or `encode` on its type parameter. A codec follows the
  rules of an `Fn` value: it may be a parameter, a struct field or a list item,
  and it has no `to_s`, `inspect` or equality and is no constant or `ATS` value.
  `IO.inspect` of a type that holds a codec is `CHECK-TYPE-MISMATCH`.

#### Optional values in JSON

`Optional[T]` is JSON's `null` or a `T`, anywhere a type is: a struct field, a
list item, a map value, an `Optional` item, or the whole value of `JSON.encode`
and `JSON.from`. `none` is `null`, `some(x)` is `x`, and a missing key of an
`Optional` struct field decodes as `none`; the rest (schema, error texts, round
trip) is in the library page.

- `Optional[Nil]` is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`, since
  `some(nil)` would be written as `null`. An `Optional` cannot hold a
  `JsonField` (`Optional[JsonField[T]]` is `CHECK-JSON-FIELD-PLACE`), and a
  `JsonField[Optional[T]]` is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`:
  use `Optional[T]` when a missing key and `null` mean the same, and
  `JsonField[T]` when they differ.
- `JSON.decode`, `JSON.schema` and `JSON.codec` take a struct name, so a
  top-level `Optional` is decoded as a field of a struct.

#### Optional and nullable fields (`JsonField`)

A struct field of type `JsonField[T]` keeps the three states of a key apart in
typed JSON: absent, `null`, or a value. `JsonField` is a builtin generic enum:

```agentica
enum JsonField[T]
  Absent
  Null
  Value(T)
end
```

- The variants are always qualified (`JsonField.Value(x)`). `Absent` and `Null`
  need an expected type, like any nullary variant of a generic enum
  (`CHECK-ENUM-TYPE-INFERENCE` otherwise); a struct field gives one. A `case`
  needs the three arms or a `_` arm, which is how a program treats absent and
  null alike.
- **Where:** in the type of a `JSON.decode` or `JSON.schema` target or of a
  `JSON.encode` or `JSON.from` argument, `JsonField` may only be the direct type
  of a struct field. A list item, a map value, an `Optional` item, a nested
  `JsonField[JsonField[T]]` or the whole argument of `JSON.encode` or
  `JSON.from` is `CHECK-JSON-FIELD-PLACE`, at the target or argument. A type
  argument counts after substitution: in `Box[JsonField[Int]]` (`struct Box[T]`
  with `value: T`) the field is a direct `JsonField` field, but `items: List[T]`
  or `f: JsonField[T]` with that argument is `CHECK-JSON-FIELD-PLACE`.
  `JSON.decode` and `JSON.schema` still take no generic instance. This check
  comes first, so `List[JsonField[Nil]]` is `CHECK-JSON-FIELD-PLACE`.
  `JsonField[Nil]` as a field is `CHECK-NOT-DECODABLE` or
  `CHECK-NOT-ENCODABLE`, since `Value(nil)` would be written as `null`. A bare
  `JsonField` target is `CHECK-UNKNOWN-TYPE`.
- Outside JSON, `JsonField[T]` is an ordinary enum value: locals, parameters,
  lists and maps may hold it, it prints when `T` does (`JsonField.Value(30)`),
  and it has no `==`. A user `struct JsonField`, `enum JsonField` or `import ...
  as JsonField` is `CHECK-REDEFINED-NAME`.

The decode, encode and schema forms, the error texts and the round trip are in
the library page.

### Builtin discovery and execution budget

`agentica help NAME --json` prints the name, arity, parameter types, result,
signature, effects and description, from the catalog that checking and execution
use. A parameter with a default also has `default`, its source text (`"0"`),
and the arity counts every parameter. `ruby` is the signature in the Ruby
method form (`s.strip() -> String` for `String.trim`), or null for a builtin
with no method form. The help text
and the helps of diagnostics write that form too (`s.strip`, not `String.trim`),
while both names stay accepted. Effects are informational (I/O, tasks, or
`test`). An unknown target exits 2, with a hint when the name is a close
builtin or one from another language that the checker knows (`Hash.new`,
`int`). A name that other languages use for
a builtin (`strip`, `String.to_i`, `value!`) is not unknown: it exits 0 with
the builtins it stands for, and `--json` prints
`{"alias": NAME, "builtins": [...], "hints": {...}}`, `builtins` holding what
`help NAME --json` prints for each. `agentica help --json` with no NAME prints
every public builtin as one JSON array, sorted by name, each element exactly
what `help NAME --json` prints.

`agentica doc PATH [--json]` prints the exported API of a module with its `##`
docs (section 4): PATH is a source file or a `std/` module name. It lexes and
parses the module, so its imports need not exist; only a module that re-exports
a name is linked, as `outline` below. Declarations without `export` are left
out. A lex or parse error exits 1, an unreadable path exits 2.

`agentica outline FILE [--json] [--stdin FILE]` lists the top-level declarations
of one file in source order, private ones too: imports, functions, structs with
their fields, enums with their variants, type aliases, resources and constants,
each with `exported`, its signature, its `##` doc and summary, and its span and
the span of its name. FILE is a source file or a `std/` module name. It lexes
and parses the file only, as `doc` does; a file that re-exports a name, such as
`export Url.parse`, is linked to list the original declaration with its doc, and
a re-export whose module does not link is left out. `--stdin FILE` takes the
text of FILE from standard input. A lex or parse error exits 1; a mistake in the
arguments or an unreadable path is `QUERY-USAGE` (section 7) and exits 2.

`agentica type-at FILE:LINE:COL [--json]` gives the checked type of the
innermost expression at a position (line and column from 1, in code points as
diagnostics count them), its span and source text, and the definition of what it
names: a function, struct, enum, variant, field or constant, with the span of
the declaration and of its name, its signature and its `##` doc (null when it
has none). A type name (in an annotation, a type argument or a field or
payload type) has the `kind` `type`, the span of the name (`Models.User` is one
span) and the struct, enum, type alias or resource it names as definition
(`alias` kind for an alias); a builtin type (`Int`, `List`) has no definition. A
type of another file is written through the import alias of
FILE (`Models.User`). On the name of a builtin (`split` in `xs.split(",")`) the
`kind` is `builtin` and `help` holds the object of `agentica help NAME --json`;
a builtin has no definition. A local (a parameter, a binding, a `for` variable
or a name in a `case` pattern) has its type and a definition at its binding,
whether the position is on a use or on the binding itself. The `kind` of the
JSON answer is an open set: a client accepts a value it does not know. FILE is a
path of the disk, linked and checked with its imports; it needs no `main`.
`--stdin` before the position (`type-at --stdin FILE:LINE:COL`) takes the text
of FILE from standard input. An error of the program is its own diagnostic and
exits 1. A position on no token of an expression (a blank, a comment, the body
text of a heredoc, a keyword such as `return` that is part of no expression) is
`QUERY-NO-EXPRESSION` and exits 2, as is a bad position (`QUERY-USAGE`). With
`--partial` (also on `refs`; `outline` accepts it and ignores it, since it never
checks) a program in which some functions do not check is answered from the
functions that do: the answer has `"partial": true` and `diagnostics`, and exits
0. A name in a function that did not check is answered by its definition after
linking, with a `type` of null. A program that does not link, or a position that
cannot be answered this way, is the first diagnostic and exits 1 as before.

`agentica symbol NAME [PATH...] [--json] [--stdin FILE]` finds where a name is
defined in the modules linked from the files under PATH (a file or a folder;
every `*.agc` file below a folder; default `.`). NAME is written as the code
writes it: `total`, `User.email`, `Option.Some`, `Models.User` through an import
alias of a file of PATH, `std/queue.pop`, or a builtin (`Map.get`). Each match
has its `kind` (`function`, `struct`, `enum`, `alias`, `resource`, `constant`,
`field`, `variant` or `builtin`), `module`, `exported` (private declarations
too), `signature`, `doc` and spans; a builtin has `help`, the object of
`agentica help NAME --json`. The answer with `--json` is one object, `{version,
command, query, matches, skipped}`. Only lexing, parsing and linking are needed.
The files of PATH are linked together; one that does not lex, parse or link is
listed under `skipped` with its first diagnostic while the others still answer
(exit 0). If none links, that first diagnostic is the answer and the exit status
is 1. A name that nothing declares is `QUERY-NOT-FOUND` and exits 2, as is a
mistake in the arguments (`QUERY-USAGE`). `--stdin FILE` takes the text of FILE
from standard input and searches it too.

`agentica refs NAME|FILE:LINE:COL [PATH...] [--json]` lists every reference to a
declaration: a function, struct, enum, variant, field (in a read, a construction
and a `with`), constant, type alias, resource, local or builtin. The declaration
is the one that NAME names, written and resolved as for `symbol`, or the one the
name at the position stands for. The files are linked together: FILE and the
files under PATH for a position, the files under PATH (default `.`) for a NAME,
and everything they import. One that does not link is listed under `skipped` and
the others still answer, except FILE, which must link. The program is checked as
`type-at` checks it, with the same exit codes. The answer is one object,
`{version, command, query, definition, builtin, references, skipped}`:
`definition` is the `symbol` match (null for a builtin, which `builtin` names),
and `references` lists each use with its `kind`, the `function` it is in and the
span of the name; the definition is not a reference, and no references is an
empty list. The linker and the checker decide what a name is, so two fields of
one name in two structs, or a name bound in two sibling blocks, are never mixed.
A NAME that nothing declares is `QUERY-NOT-FOUND`; one that several declarations
answer to is `QUERY-AMBIGUOUS-NAME`, whose help lists each as `FILE:LINE:COL`. A
position on the name in a declaration picks it, and so does one on a name of an
import list (`make` of `import {make} from "models"`), which selects the
imported declaration. A position on the module alias of `Models.total(u)`
selects the function `total`, not the module; one on a module alias or a path of
an import line is `QUERY-NO-EXPRESSION`. `--stdin FILE:LINE:COL` takes the text
of FILE from standard input; with a NAME, `--stdin FILE` searches that text as
one more file, as for `symbol`. With `--partial` and a position alone (no PATH),
the references to a function, struct, enum, alias, resource, constant or variant
are complete even when some functions do not check, and so are those of a local
of a function that checks; a field or a builtin needs every function checked. A
NAME or a PATH with `--partial` is `QUERY-USAGE`.

`agentica --max-steps N program.agc` limits a run to N expression or statement
entries across all tasks; N must be a positive integer. Runs are unlimited by
default, and checking never spends the budget. Exhaustion is
`RUNTIME-STEP-LIMIT` at the next node. It is not a wall-clock or blocking-I/O
timeout. Each scheduler takes steps in batches, so with more than one scheduler
the limit can trip a little late; `--schedulers 1` keeps the exact count.

At the end of a run the VM waits for the buffered writes of every open file, for
the output of stdout and stderr that a pipe has not taken yet, and then for the
frees of what native code still owns (see
[How a run ends](../../site/content/library/concurrency/task.md#how-a-run-ends)).
The wait is always bounded:
30000 milliseconds by default. `agentica --flush-timeout MS program.agc` or the
environment variable `AGENTICA_FLUSH_TIMEOUT_MS` sets it (an integer from 0 to
86400000; the flag wins, a bad value exits 2, and there is no way to turn the
limit off). On timeout, the run ends with the same exit code, and stderr gets
`agentica: file data may not be written: the flush took longer than MS ms` (with
`--json`, `{"flush_timeout_ms": MS, "warning": "file data may not be
written"}`); when a native free is what took too long, the warning says `native
resources may not be freed` instead (both, joined by `and`, when both did).

`agentica --schedulers N program.agc` or the environment variable
`AGENTICA_SCHEDULERS` sets the number of scheduler threads (an integer from 1 to
1024; the flag wins over a valid variable, an empty variable counts as unset,
and a bad value in either exits 2, before the program starts). The default is
one per logical core the process may use, at most 1024. With more than one,
tasks run in parallel and their order is not fixed; `--schedulers 1` runs one
task at a time in the order of a single run queue. The front end always compiles
on one scheduler. `agentica test` refuses the flag (exit 2); the VMs it starts
read `AGENTICA_SCHEDULERS`.

Everything is allowed by default. `--deny-run`, `--deny-net`, `--deny-fs` and
`--deny-env` each turn off a family of builtins: a call returns an error that
begins with `denied: ` and the flag (`denied: --deny-fs`), and the program goes
on. `--deny-run` turns off the `Process` starts; `--deny-net` every connect and
listen of `TCP` and `TLS`, so `std/http` too, before any DNS lookup; `--deny-fs`
every `File`, `Dir` and `Path` call but `Path.join`, `Lazy.write_lines`,
`Lazy.write_bytes`, and a TLS call that names a file; `--deny-env` `System.env`
(`System.os` and `System.pid` stay on: they hold no secret; the locale of error
texts still follows `LANG`). Each turns on `--deny-native`, since native code
could do the same. A program that can start processes escapes a single flag; use
`--sandbox`, or add `--deny-run`. `--sandbox` is all of them: the one flag for
code you do not trust. They apply to the program, not to the front end.
`agentica test` gives them to the test files, the step programs and the programs
under test, not to its runner.

Calls nest at most 10000 deep in each task; a deeper call is
`RUNTIME-STACK-OVERFLOW` at the call. A tail call (`return f(...)` to a user
function) replaces the caller's frame and does not count, so deep tail recursion
runs. A call inside a larger expression, such as `return 1 + f(n - 1)`, and a
call of a builtin are not tail calls.

### The bytecode cache

`agentica FILE.agc` and each test file of `agentica test` keep their compiled
program in `_build/bytecode/`, with `_build/` in the folder of the nearest
`agentica.toml` or, with none, beside the root file (`AGENTICA_BUILD_DIR` names
another folder in place of `_build/`). The entry holds the bytes `agentica compile` writes, the
version, build and path of the binary, the SHA-256 of every file the front end
read (with `agentica.toml` and `agentica.lock`), and what the resolver looked
at: each place of the `pkg/` search that was empty or held a file, and where
each relative import led. A lookup checks them again; any difference, or a
damaged entry, compiles the program again and replaces the entry. A run that
hits has no front-end diagnostics, since the program checked when it was
cached. The entry is used only when `_build/`, `bytecode/` and the file are
what the cache made: real folders and a regular file, never a link, owned by
the user and writable by no one else (the folders are made with mode 0700).
Otherwise the run goes on without the cache. On Windows, which has no modes or
owner ids to read, only the link and file-kind checks apply: the cache trusts
its folder, with no owner or ACL check, and a folder that other users can write
is out of scope. `check`, `compile`, `--dump`, `--dump-ir`, `check --stdin` and
`run` do not use it; `--no-cache` skips it for one run; a folder that cannot be
written is not an error. The `--deny-*` flags do not apply to it: they are for
the program.

### Running a compiled program

`agentica compile file.agc -o file.agcb` writes a program as bytecode, and
`agentica run [OPTIONS] [--] file.agcb [ARGS...]` runs it on the VM with no
front end: nothing is read, checked or compiled. `run` must be the first word
after `agentica`; after an option it is taken as a source file name and the
front end answers with a usage error (exit 2). The options are `--max-steps N`,
`--seed N`, `--flush-timeout MS`, `--schedulers N`, `--jit MODE`, the `--deny-*`
flags, `--sandbox`, `--source-root DIR` (the folder put before the file names
that the bytecode stores, except the `std/` modules), `--ai` and `--json`, each
at most once and with the values and limits they have for `agentica FILE.agc`;
`--version` prints the Agentica version and the versions of the libraries the VM
links. The words after the file are the program's arguments, even when they look
like options. The loader treats the file as untrusted, but its native code runs
unless a `--deny-*` flag or `--sandbox` is given. A file that is not valid
bytecode, or whose format or Agentica version is not the binary's, is refused
before anything runs; a source file also gets the hint to run it as `agentica
FILE.agc`. The exit status is the program's own: `System.exit(n)`, 1 for a
diagnostic, and 2 for a command line or a start that fails (a bad option, an
unreadable file, bad bytecode), with a message that starts `agentica run:`.
