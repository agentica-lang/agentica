### Methods on builtin types

`receiver.name(args)` calls a builtin whose first parameter has the receiver's
type. The checker picks the module from the static type (`String`, `Bytes`,
`List`, `Map`, `Set`, `Float`, `Result`, `Range`, `Int`, `JSON.Value` through
`JSON`, and `Codec[T]` through `Codec`); there is no dynamic dispatch. `s.strip`
is `String.strip(s)`, and `n.to_s` is `Int.to_s(n)`. The methods of a codec are
also functions, `Codec.decode(c, s)`, as `String.upcase` is. Without
parentheses, `receiver.name` on a non-struct value is a method without arguments
(`s.length`, `r.ok?`). On a struct, `.name` is a field. Structs and enums have
no methods. The forms on a type name are `Type.members`, the list of the fields
of a struct (`docs/grammar/06-semantics.md`, "Structs and lists"), and
`Type.codec`, its codec (JSON, below).

A builtin has its Ruby name (`strip`, `include?`, `start_with?`, `to_i`,
`to_f`, `to_s` and `join`); an old name (`trim`, `contains?`, `to_int`,
`String.from_int`, `String.join`) is `CHECK-UNKNOWN-METHOD`, or
`CHECK-UNKNOWN-NAME` for a function, with the Ruby form as help. Ruby aliases
are the module functions named in the library pages: `push`, `select`, `key?`,
and `to_s` and `inspect` on any data value. Ruby's other names for a
method work too, and the texts show only the first: `length` and `size` on
`String`, `Bytes`, `List`, `Map`, `Set` and `Range`; `collect` for `map`,
`inject` for `reduce` and `detect` for `find` (on `List` and `Lazy`); `member?`
for `include?` on `List`, `Set` and `Range`; `include?` and `member?` for `key?` on
`Map`. Two differ from Ruby: `to_i` and `to_f` on text return a `Result`
(`"abc".to_i` is an error, not `0`), and `to_i!` and `to_f!` halt on bad text.
An unknown method is `CHECK-UNKNOWN-METHOD`.

`x.to_s` is the text `"#{x}"` gives: a `String` as is, a `JSON.Value` as its
JSON text, an `Error` as its message, and any other data value in its `inspect`
form (`[1, 2]`, `ok(3)`, `Item(name: "a")`). An `Error` inspects as the
`error(...)` call that builds it, without the fields that hold their default and
without `location`, both alone and as the payload of a failed Result. Inside a
list, a `JSON.Value` shows as `<JSON.Value>`. Functions, tasks, handles,
`C.Pointer` values and resources have no `to_s`, so printing or interpolating
one is `CHECK-TYPE-MISMATCH`. Unlike Ruby, `nil.to_s` is `"nil"`. `x.inspect`
keeps a string's quotes; it is for display, not valid source.

Values are immutable: a method never changes its receiver, so `xs.push(2)`
returns a new list. A builtin without effects whose non-Void result is dropped
is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Builtins with effects,
functions ending in `!`, and builtins that take a function are exempt, except
that a dropped `Result` is `CHECK-UNUSED-RESULT` for any call (see "Result and
propagation" in the semantics). A negative literal receiver needs parentheses:
`(-5).to_s`.

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

A builtin family groups builtins under one reserved name, as Ruby's
`OpenSSL::Cipher` does: its members are written `Family.Member` and their
functions `Family.Member.fn(args)`, two levels at most
(`OpenSSL.Cipher.aes_256_gcm_encrypt(key, iv, data)`,
`OpenSSL.Random.uuid`, `data |> OpenSSL.Digest.sha256()`). A member is a group
of functions or a builtin type. A member the family lacks is
`CHECK-UNKNOWN-NAME`, with the members in the help; a group of functions where
a type is wanted is `CHECK-UNKNOWN-TYPE`. The one family today is `OpenSSL`
(`Digest`, `HMAC`, `Cipher`, `CMAC`, `KDF`, `RSA`, `Random`).

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

`JSON` is reserved; `JSON.Value` and `JSON.Field` are members of its family. A
`JSON.Value` has no constructor, equality, fields or indexing. The functions,
their errors, the schema and the text they read and write are in the [`JSON`
page](../../site/content/library/text-and-data/json.md). The rules that the
checker enforces:

- `JSON.decode(source, T)` and `JSON.schema(T)` take a named struct or enum
  type, not a value, and so does `T.codec`; bare type names are valid only for
  these. `JSON.decode` also takes `List[T]` and `Map[String, T]` of such a type
  (or of a field type below); `schema` and `codec` refuse them
  (`CHECK-TYPE-MISMATCH`). Fields and payloads may be Int, Float, Bool, String,
  lists, String-keyed maps, nested or recursive structs and enums, and
  `Optional` of those (and `JSON.Field`, for a struct field); any other nested
  type, a generic struct or enum instance included, is `CHECK-NOT-DECODABLE`.
- `JSON.encode` and `JSON.from` accept Int, Float, Bool, String, Nil (as
  `null`), JSON.Value, lists, String-keyed maps, `Optional`, structs and user
  enums of those, whose struct fields may also be `JSON.Field`. An instance of a
  generic struct or enum counts by its fields or payloads after substitution
  (`Box[List[Int]]`, `Maybe[Int]`). Results, builtin enums (`TaskExit`) and
  Int-keyed maps are `CHECK-NOT-ENCODABLE`. Untyped empty containers need an
  annotation.
- A user enum is a tagged object `{"tag": "Rect", "values": [1.0, 2.0]}`: `tag`
  is the variant name and `values` the payloads in order. The page has the
  errors and the schema (a `oneOf`). A `JSON.Field` in a payload is
  `CHECK-JSON-FIELD-PLACE`.
- `T.codec` takes the targets of `decode`, with its diagnostics (a value is
  `CHECK-UNKNOWN-METHOD`), and gives a `Codec[T]`: the JSON of `T` and its
  members as a value, for generic code, which cannot call `decode` on its type
  parameter. `codec.decode`, `codec.encode` and `codec.from` are the JSON
  functions of `T`, and `codec.members` is the `List[StructMember]` of
  `T.members` (empty for an enum). `Codec` is reserved as a type name and as
  an import alias (`import Codec from "x"` is `CHECK-REDEFINED-NAME`). A codec
  follows the rules of an `Fn` value: it may be a parameter, a struct field or a
  list item, and it has no `to_s`, `inspect` or equality and is no constant or
  `ATS` value. `IO.inspect` of a type that holds a codec is
  `CHECK-TYPE-MISMATCH`. `JSON.codec(T)` gets a help that shows `T.codec`.

#### Optional values in JSON

`Optional[T]` is JSON's `null` or a `T`, anywhere a type is: a struct field, a
list item, a map value, an `Optional` item, or the whole value of `JSON.encode`
and `JSON.from`. `none` is `null`, `some(x)` is `x`, and a missing key of an
`Optional` struct field decodes as `none`.

- `Optional[Nil]` is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`, since
  `some(nil)` would be written as `null`. An `Optional` cannot hold a
  `JSON.Field` (`Optional[JSON.Field[T]]` is `CHECK-JSON-FIELD-PLACE`), and a
  `JSON.Field[Optional[T]]` is `CHECK-NOT-ENCODABLE` or `CHECK-NOT-DECODABLE`:
  use `Optional[T]` when a missing key and `null` mean the same, and
  `JSON.Field[T]` when they differ.
- `JSON.decode`, `JSON.schema` and `T.codec` take a struct or enum name, so
  a top-level `Optional` is decoded as a field of a struct.

#### Optional and nullable fields (`JSON.Field`)

A struct field of type `JSON.Field[T]` keeps the three states of a key apart in
typed JSON: absent, `null`, or a value. `JSON.Field` is a builtin generic enum:

```agentica
enum JSON.Field[T]
  Absent
  Null
  Value(T)
end
```

- The variants are always qualified (`JSON.Field.Value(x)`). `Absent` and `Null`
  need an expected type, like any nullary variant of a generic enum
  (`CHECK-ENUM-TYPE-INFERENCE` otherwise); a struct field gives one. A `case`
  needs the three arms or a `_` arm, which is how a program treats absent and
  null alike.
- **Where:** in the type of a `JSON.decode` or `JSON.schema` target or of a
  `JSON.encode` or `JSON.from` argument, `JSON.Field` may only be the direct
  type of a struct field. A list item, a map value, an `Optional` item, a nested
  `JSON.Field[JSON.Field[T]]` or the whole argument of `JSON.encode` or
  `JSON.from` is `CHECK-JSON-FIELD-PLACE`, at the target or argument. A type
  argument counts after substitution: in `Box[JSON.Field[Int]]` (`struct Box[T]`
  with `value: T`) the field is a direct `JSON.Field` field, but `items:
  List[T]` or `f: JSON.Field[T]` with that argument is `CHECK-JSON-FIELD-PLACE`.
  `JSON.decode` and `JSON.schema` still take no generic instance. This check
  comes first, so `List[JSON.Field[Nil]]` is `CHECK-JSON-FIELD-PLACE`.
  `JSON.Field[Nil]` as a field is `CHECK-NOT-DECODABLE` or
  `CHECK-NOT-ENCODABLE`, since `Value(nil)` would be written as `null`. A bare
  `JSON.Field` target is `CHECK-UNKNOWN-TYPE`.
- Outside JSON, `JSON.Field[T]` is an ordinary enum value: locals, parameters,
  lists and maps may hold it, it prints when `T` does (`JSON.Field.Value(30)`),
  and it has no `==`.

### Builtin discovery and execution budget

`agentica help NAME --json` prints the name, arity, parameter types, result,
signature, effects and description, from the catalog that checking and execution
use. A parameter with a default also has `default`, its source text (`"0"`),
and the arity counts every parameter. `ruby` is the signature in the Ruby
method form (`list.select(f: Fn[A, Bool]) -> List[A]` for `List.filter`), or
null for a builtin with no method form. The help text and the helps of
diagnostics write that form too (`list.select`, not `List.filter`), while both
names stay accepted. Effects are informational (I/O, tasks, or
`test`). An unknown target exits 2, with a hint when the name is a close
builtin or one from another language that the checker knows (`Hash.new`,
`int`). A name that other languages use for
a builtin (`len`, `List.push`, `value!`) is not unknown: it exits 0 with
the builtins it stands for, and `--json` prints
`{"alias": NAME, "builtins": [...], "hints": {...}}`, `builtins` holding what
`help NAME --json` prints for each. `agentica help --json` with no NAME prints
every public builtin as one JSON array, sorted by name, each element exactly
what `help NAME --json` prints.

The query commands (`doc`, `help std/...`, `outline`, `type-at`, `symbol` and
`refs`) are described for users in [Command line](../../site/content/cli.md).
None of them runs the program. The contract that page leaves out:

- `agentica doc PATH` and `outline FILE` take a source file or a `std/` module
  name and only lex and parse it, so its imports need not exist; a file that
  re-exports a name (`export Url.parse`) is also linked, and a re-export whose
  module does not link is left out of `outline`. A lex or parse error exits 1;
  an unreadable path exits 2 (`QUERY-USAGE` in `outline`).
- `agentica help std/MODULE[.NAME] --json`: a module is `{module, doc, items:
  [{kind, name, summary}]}`, and a name has the `help NAME --json` fields that
  apply (`name`, `arity`, `parameters`, `result`, `signature`), `description`
  (the whole doc or null), `summary`, `kind` and `module`, and no `effects`. A
  name that is empty after the dot is `QUERY-USAGE`.
- Positions of `type-at` and `refs` count from 1, in code points as diagnostics
  count them. The `kind` of the JSON answer of `type-at` is an open set: a
  client accepts a value it does not know. A bad position is `QUERY-USAGE` and a
  position on no expression is `QUERY-NO-EXPRESSION`, both exit 2 (section 7);
  an error of the program is its own diagnostic and exits 1.
- `--stdin` replaces the text of FILE with standard input: before the position
  in `type-at --stdin FILE:LINE:COL`, and with a NAME in `symbol` and `refs` the
  text is searched as one more file.
- With `--partial` (`type-at`, and `refs` with a position and no PATH;
  `outline` accepts it and ignores it) a program in which some functions do not
  check is answered from the functions that do: the answer has `"partial":
  true` and `diagnostics`, and exits 0. A name in a function that did not check
  is answered by its definition after linking, with a `type` of null. The
  references to a function, struct, enum, alias, resource, constant or variant
  are complete, and so are those of a local of a function that checks; a field
  or a builtin needs every function checked. A program that does not link, or a
  position that cannot be answered this way, is the first diagnostic and exits
  1. A NAME or a PATH with `--partial` is `QUERY-USAGE`.
- `symbol` and `refs` link the files under PATH (default `.`) together and
  everything they import; one that does not lex, parse or link is listed under
  `skipped` with its first diagnostic while the others still answer (exit 0),
  except the FILE of a `refs` position, which must link. If none links, the
  first diagnostic is the answer (exit 1). A match has `kind` (`function`,
  `struct`, `enum`, `alias`, `resource`, `constant`, `field`, `variant` or
  `builtin`), `module`, `exported` (private declarations too), `signature`,
  `doc` and spans; a builtin has `help`, the object of `agentica help NAME
  --json`. The answer of `symbol` is `{version, command, query, matches,
  skipped}`.
- `refs` lists every reference to a declaration (a function, struct, enum,
  variant, field in a read, a construction and a `with`, constant, type alias,
  resource, local or builtin); the definition is not a reference. The
  linker and the checker decide what a name is, so two fields of one name in
  two structs, or a name bound in two sibling blocks, are never mixed. A NAME
  that nothing declares is `QUERY-NOT-FOUND`; one that several declarations
  answer to is `QUERY-AMBIGUOUS-NAME`, whose help lists each as `FILE:LINE:COL`.
  A position on a name in a declaration picks it, and so does one on a name of
  an import list (`make` of `import {make} from "models"`), which selects the
  imported declaration; a position on the module alias of `Models.total(u)`
  selects the function `total`, not the module.

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
on. `--deny-net` stops every connect and listen of `TCP` and `TLS`, `std/http`
too, before any DNS lookup. `--deny-fs` covers every `File`, `Dir` and `Path`
call but `Path.join`, `Lazy.write_lines`, `Lazy.write_bytes`, and a TLS call
that names a file. `--deny-env` covers `System.env` (`System.os` and
`System.pid` stay on: they hold no secret). Each turns on `--deny-native`, since
native code could do the same. `--sandbox` is all of them. The flags apply to
the program, not to the front end; `agentica test` gives them to the test files,
the step programs and the programs under test, not to its runner. The table of
flags is in [Command line](../../site/content/cli.md#options).

Calls nest at most 10000 deep in each task; a deeper call is
`RUNTIME-STACK-OVERFLOW` at the call. A tail call (`return f(...)` to a user
function, or `f(...)` as the last expression that gives the function's value)
replaces the caller's frame and does not count, so deep tail recursion runs. A call inside a larger expression, such as `return 1 + f(n - 1)`, and a
call of a builtin are not tail calls.

### The bytecode cache

`agentica FILE.agc` and each test file of `agentica test` keep their compiled
program in `_build/bytecode/` and read it back while the sources are the same
(files, ownership checks and flags in [Command
line](../../site/content/cli.md#bytecode-cache)). The entry holds the bytes
`agentica compile` writes, the version, build and path of the binary, the
SHA-256 of every file the front end read (with `agentica.toml` and
`agentica.lock`), and what the resolver looked at: each place of the `pkg/`
search that was empty or held a file, and where each relative import led. A
lookup checks them again; any difference, or a damaged entry, compiles the
program again and replaces the entry. A run that hits has no front-end
diagnostics, since the program checked when it was cached. When the folders fail
the ownership checks the run goes on without the cache, and a folder that cannot
be written is not an error. The `--deny-*` flags do not apply to the cache: they
are for the program.

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
