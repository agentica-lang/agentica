### Methods on builtin types

`receiver.name(args)` calls a builtin whose first parameter has the receiver's
type. The checker picks the module from the static type (`String`, `List`,
`Map`, `Set`, `Float`, `Result`, `Range`, `Int`, and `Json` through `JSON`);
there is no dynamic dispatch. `s.trim` is `String.trim(s)`, but `"a".from_int`
is not a method. Without parentheses, `receiver.name` on a non-struct value is a
method without arguments (`s.length`, `r.ok?`). On a struct, `.name` is a field.
Structs and enums have no methods.

Ruby aliases are the module functions named in the library pages: `size`,
`length`, `strip`, `include?`, `start_with?`, `end_with?`, `push`, `join`,
`to_f`, and `to_s` and `inspect` on any data value. Two differ from Ruby: `to_i`
and `to_f` on text return a `Result` (`"abc".to_i` is an error, not `0`), and
`to_i!` and `to_f!` halt on bad text. An unknown method is
`CHECK-UNKNOWN-METHOD`.

`x.to_s` is the text `"#{x}"` gives: a `String` as is, a `Json` as its JSON
text, and any other data value in its `inspect` form (`[1, 2]`, `ok(3)`,
`Item(name: "a")`). Inside a list, a `Json` shows as `<Json>`. Functions, tasks
and handles have no `to_s`, so printing or interpolating one is
`CHECK-TYPE-MISMATCH`. Unlike Ruby, `nil.to_s` is `"nil"`. `x.inspect` keeps a
string's quotes; it is for display, not valid source.

Values are immutable: a method never changes its receiver, so `xs.push(2)`
returns a new list. A builtin without effects whose non-Void result is dropped
is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Builtins with effects,
functions ending in `!`, and builtins that take a function are exempt. A
negative literal receiver needs parentheses: `(-5).to_s`.

### Minimal builtin functions

`puts(value)` writes the value's `to_s` and a newline; `print` writes without
one. `gets` and `gets!` are `IO.gets` and `IO.gets!`, and may drop their
parentheses (`line = gets!.strip`). `Map`, `Set` and `List` are builtin modules
whose generic functions the checker treats specially. Signatures are in
[`library/data-structures/list.md`][agentica-link-1],
[`library/data-structures/map.md`][agentica-link-2]
and
[`library/data-structures/set.md`][agentica-link-3].

Callbacks (`List.map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`,
and the Enumerable methods below) take a block, `&name` or a function variable.
Each runs once per element, left to right, under the caller's budget. Parameter
and return types must match exactly, and a `map` callback returns data, not
Void. Annotated block parameters let an empty list or an empty `reduce` initial
value infer its type. `List.any?` and `List.all?` stop at the first deciding
element.

Collection operations preserve their inputs. Costs exclude callback work.

- `List.map` and `List.filter` are O(n). `List.reduce` folds left, calling
  `f(accumulator, item)`; an empty list gives the initial value.
- `List.append` (`push`) takes near constant time, so building a list with n
  appends is O(n). `List.concat` joins lists of one element type: O(b) when the
  right list has at most 32 items, otherwise O(a + b). `List.reverse` is O(n).
- `List.set` and `List.at` are zero-based and take O(log32 n) time (at most four
  steps for a million items). A negative or out-of-range index is
  `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument.
- `List.repeat` takes a count from 0 to 1048576; zero gives an empty list of the
  element type. Other counts are `RUNTIME-INVALID-COUNT`.
- `List.take` and `List.drop` need a nonnegative count
  (`RUNTIME-INVALID-COUNT`). A larger count gives the whole list or an empty
  list. They are O(n) in the size of the result.
- `List.sort` and `List.sort_by` sort ascending. Elements, or the keys from
  `sort_by` (computed once per element, left to right), must be `Int`, `Float`
  or `String`; otherwise `CHECK-TYPE-MISMATCH`. The sort is stable. Strings
  compare by code point, so `"B"` is before `"a"`. NaN goes last. O(n log n),
  plus key calls.
- `List.find` gives `ok(element)` for the first element the block accepts, or
  `error("not found")`, and stops calling the block there.
  `List.each_with_index` calls `f(element, index)` with the index from 0 and
  gives nothing back. `List.flat_map` joins the lists the block returns, in
  order. `List.partition` gives `[accepted, rejected]`. `List.take_while` and
  `List.drop_while` call the block until it first returns false, and not after.
  All are O(n).
- `List.each_slice(n)` gives the slices of `n` elements as a `List[List[T]]`,
  the last one shorter. It has no block form: a block after it is
  `CHECK-BLOCK-TARGET`, and `xs.each_slice(2).each do |pair| ... end` walks the
  slices. An `n` below 1 is `RUNTIME-INVALID-COUNT` at the argument.
- `List.group_by` (the key is an `Int` or a `String`; other types are
  `CHECK-TYPE-MISMATCH` at the block) gives a `Map[K, List[T]]` whose keys and
  elements keep the order of first appearance. `List.tally` counts equal `Int`
  or `String` items in a `Map[K, Int]` in the same order. `List.uniq` keeps the
  first of each `Int` or `String` item. O(n).
- `List.sum` adds a `List[Int]` or `List[Float]` from the left; an empty list
  gives `0` or `0.0`, and an `Int` overflow is `RUNTIME-INTEGER-OVERFLOW` at the
  call. Other item types are `CHECK-TYPE-MISMATCH`.
- `List.min_by` and `List.max_by` call the key block once for each element, from
  the first to the last, and give `ok(element)` for the least or greatest key,
  or `error("the list is empty")`. The key is an `Int`, a `Float` or a `String`.
  The first element wins a tie. A NaN key never wins unless every key is NaN,
  and then the first element wins. `String` keys compare with `String.compare`.
- `Map.each` calls `f(key, value)` for each entry in insertion order and gives
  nothing back. `Map.filter` keeps the entries `f(key, value)` accepts, in
  insertion order. Both are O(n).
- `String.compare(a, b)` (also `a.compare(b)`) gives `-1`, `0` or `1` in the
  order of `sort`: code point order, which is the byte order of UTF-8.
- These methods are written in Agentica in `stdlib/prelude/` and run in the
  program: they use its step budget, and a runtime error in one is reported at
  the call in the program (at the argument it names), never in the prelude. They
  have one name each: `select`, `collect`, `detect`, `inject` and `reject` are
  `CHECK-UNKNOWN-METHOD`, and so are the same names on a `Range`.
- `Map.get` with two arguments gives `ok(value)` or `error(message)`. With
  three, the default is always evaluated; `false` and `nil` are present values.
- `Map.delete` ignores absent keys and keeps the order of the rest; a key put
  back later goes to the end. It is O(n). `Map.values` follows the `Map.keys`
  order.
- `Set.delete` is O(n) like `Map.delete`.

`Lazy[T]` is a lazy pipeline: an immutable recipe of a source and steps, not a
cursor. Building one runs nothing; a terminal runs it, pulling one item at a
time through every step, so no step builds a list of all the items. Each
terminal runs the source again from the start, except a channel, which cannot
be read twice. The library page is
[`library/data-structures/lazy.md`][agentica-link-5].

- Sources: `xs.lazy` (`List[T]` to `Lazy[T]`), `(a..b).lazy` and
  `(a...b).lazy` (`Lazy[Int]`), and `Lazy.produce(seed) do |x| ... end`, the
  endless `seed`, `f(seed)`, `f(f(seed))`, ...
- `File.foreach(path, buffer_bytes, timeout_ms)` (`Lazy[String]`): the lines
  of a file, read as `File.each_line` reads them. The file opens when a
  terminal starts and is closed before the terminal returns, whatever ended it
  (the end, a step that had enough, an error from a block, a failed `try`, a
  read error); a crash or cancel of the task closes it at the task's end. After
  a read timeout the handle is released at once and the OS descriptor closes
  when the read that timed out ends. A
  read error, a bad timeout or path ends the terminal with that error; a
  buffer outside 1024..16777216 is `RUNTIME-INVALID-COUNT` at the argument.
  `File.foreach(...).each do ... end`, with no step in between, written as one
  chain, is `CHECK-LAZY-NO-STEP`: that is `File.each_line`.
- `ch.lazy(timeout_ms)` (`Channel[T]` to `Lazy[T]`): the values of a channel
  until it is closed and drained. Each wait for a value obeys the timeout; a
  timeout ends the terminal with `error("channel: timed out")`. A negative
  timeout is `RUNTIME-INVALID-DURATION` at the argument; `ch.lazy(0)` takes only
  what is already there. A second terminal on the same channel goes on with the
  values the first did not take (`ok([])` once it is drained); a value a
  terminal took is gone even if a later step dropped it, and `take_while`
  consumes the first value its block rejects.
- Steps give a new `Lazy`: `map`, `filter`, `take(n)`, `take_while`, `drop(n)`,
  `drop_while`, `flat_map` (the block gives a `List[U]`), `with_index do |x, i|
  ... end` (maps each item with its index from 0), `each_slice(n)`,
  `each_cons(n)` (windows of `n` items; none when the source has fewer) and
  `chunk_while do |a, b| ... end` (a new group where the block is false for
  two neighbours); the last three give `Lazy[List[T]]`. A negative count, or a
  size below 1, is `RUNTIME-INVALID-COUNT` at the argument, when the step is
  built.
- Terminals always give a `Result`: `to_a` and `first(n)` give
  `Result[List[T]]`, `reduce(init) do |acc, x| ... end` gives `Result[B]`,
  `find` gives `ok(item)` or `error("not found")` (as `List.find`), and `each`
  takes a block that returns `Result[Void]` (as `File.each_line`), stops at its
  first `error` and gives it back. `take`, `take_while`, `first` and `find`
  stop the source: an endless source then ends, and `Lazy.produce` does not
  call its block for an item that no step needs. `to_a`, `reduce` and `each` on
  an endless source never end.
- `lz.write_lines(path, timeout_ms)` (on a `Lazy[String]`, `Result[Void]`) is
  the terminal that writes each item and a line feed to a file, created or
  truncated. The file opens before the first item is pulled (a failed open
  pulls nothing) and is flushed and closed before the terminal returns,
  whatever ended it; a crash or cancel of the task closes it at the task's
  end. Lines are buffered and written 64 KiB at a time; `timeout_ms` bounds the
  open, each write and the close. A bad timeout or path, a failed open, write
  or close, and a line over 1 MiB end the terminal with that error. What was
  written before an error stays in the file. A line holding a line feed reads
  back as two lines.
- `try` works in every block of a `Lazy` method, whatever the block's result
  type: a failed `try` ends the pipeline at once, no later item is pulled, and
  the terminal returns its error. A file the run opened is closed first.
- Each item pulled from the source costs one step, and each callback a step
  plus its body, as in `Range.each`. A terminal can be switched out between
  items, so `--max-steps` (`RUNTIME-STEP-LIMIT`), the turns of other tasks and
  a cancel reach a pipeline with no callback. Callbacks run on the task that
  called the terminal; a recipe can be shared by tasks on any scheduler. A
  runtime error in a callback ends the run as anywhere else. A terminal over a
  file or a channel parks while it waits, as `File.each_line` and `recv` do,
  and a cancel reaches it there.
- A `Lazy` has no `==`, no `to_s` and no JSON form (`CHECK-TYPE-MISMATCH`,
  `CHECK-NOT-ENCODABLE`); `IO.inspect` prints `<Lazy>`. `Lazy` is a reserved
  type name. A `List` method on a `Lazy` (`lz.size`) and a step that only
  `Lazy` has on a `List` or `Range` (`xs.each_cons(2)`) are
  `CHECK-UNKNOWN-METHOD`, with a help that shows `to_a` or `.lazy`.

Expected types flow into these operations for empty collections and Results.

- `String.length` and `String.slice` count characters, not bytes. An
  out-of-range `slice` is a runtime error.
- `String.split(s, sep)` keeps empty parts, so `String.join(String.split(s,
  sep), sep)` gives `s`. `String.split("", sep)` is `[""]`; `String.split(s,
  "")` gives one character per element.
- `String.to_int!` accepts a signed decimal: `RUNTIME-INVALID-NUMBER` for other
  text, `RUNTIME-INTEGER-OVERFLOW` outside `Int`. `String.to_float!` rejects
  text that is not a real decimal with `RUNTIME-INVALID-NUMBER`.
- `String.index_of` gives the character index of the first match (`ok(0)` for an
  empty part), or an error when absent. `String.at` halts with
  `RUNTIME-INDEX-OUT-OF-RANGE` outside the string.
- `String.code` and `String.from_code` halt with `RUNTIME-INVALID-CHARACTER` on
  other input: a one-character string, or a scalar value (0 to 0x10FFFF, no
  surrogates).
- `Float.to_int` truncates toward zero; NaN, infinity and results outside `Int`
  are errors. `Float.to_int!` halts instead, with `RUNTIME-INVALID-NUMBER` or
  `RUNTIME-INTEGER-OVERFLOW`.
- `Int.bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left`, `shift_right` and
  `shift_right_unsigned` work on the 64-bit two's complement form of their
  arguments and read the result back the same way. They are methods on `Int`
  (`flags.bit_and(4)`, `x.shift_left(8)`) with no effects. The core has no hex
  literals, so masks are written in decimal. `bit_and`, `bit_or`, `bit_xor`
  and `bit_not` never fail; `bit_not(a)` is `-1 - a`.
- `Int.shift_left(a, n)` is the low 64 bits of `a * 2^n`: bits that leave the
  top are dropped and bit 63 becomes the sign, so `1.shift_left(63)` is
  `-9223372036854775808` and the shift wraps where `*` halts with
  `RUNTIME-INTEGER-OVERFLOW`. `shift_right` is arithmetic (copies of the sign
  bit come in) and rounds toward minus infinity, so `(-7).shift_right(1)` is
  `-4`. `shift_right_unsigned` is logical (zeros come in), so
  `(-1).shift_right_unsigned(60)` is `15`. A count of 64 or more shifts every
  bit out: `shift_left` and `shift_right_unsigned` give `0`, and `shift_right`
  gives `0` for `a >= 0` and `-1` for `a < 0`. A negative count is
  `RUNTIME-INVALID-COUNT` at the count argument.
- `Float.to_bits(x)` gives the IEEE 754 binary64 bits of `x` as a two's
  complement `Int` (`1.0` is `4607182418800017408`, `-0.0` is
  `-9223372036854775808`). Every NaN gives the quiet NaN `9221120237041090560`.
  `Float.from_bits(n)` reads the 64 bits of any `Int` as a binary64; subnormals,
  infinities and `-0.0` come back exactly and any NaN pattern gives NaN, so
  `Float.to_bits(Float.from_bits(n)) == n` except for NaN patterns other than
  the quiet NaN.
- `Float.to_bits32(x)` rounds `x` to binary32 (to nearest, ties to even) and
  gives its 32 bits as an `Int` from `0` to `4294967295`. A magnitude of `2^128
  - 2^103` or more becomes infinity with the same sign, small magnitudes round
  to a subnormal or to zero and keep their sign, and every NaN gives
  `2143289344`. `Float.from_bits32(n)` widens a binary32 to a `Float` exactly;
  an `n` outside `0 .. 4294967295` is `RUNTIME-INVALID-NUMBER` at the argument.
  `Float.to_bits32(Float.from_bits32(n)) == n` except for NaN patterns other
  than `2143289344`.

- `IO.gets` gives `ok(line)` without its terminator (LF, CR or CRLF), or an
  error at EOF; a blank line is `ok("")`. `IO.gets!` halts with
  `RUNTIME-END-OF-INPUT` at EOF. `IO.read()` drains stdin to EOF, so it cannot
  read one message from a peer that keeps stdin open.
- `IO.read_bytes(count)` waits for exactly `count` bytes or EOF, and gives
  integers 0 to 255 with no decoding. Counts are 0 to 1048576; zero gives
  `ok([])` without consuming input. `String.from_bytes` decodes strictly as
  UTF-8: invalid, overlong, surrogate and incomplete sequences are errors, never
  replacement characters. `String.to_bytes(s)` is its inverse: the UTF-8 bytes
  of `s` as a `List[Int]` of 0 to 255 (`[]` for `""`); it cannot fail, so
  `String.from_bytes(String.to_bytes(s))` is `ok(s)`.
- `Crypto.sha256(data)` gives the SHA-256 digest of the bytes in `data` as a
  `List[Int]` of 32 integers 0 to 255 (`Crypto.sha256([])` starts `[227, 176,
  196, ...]`, hex `e3b0c442...`). An item outside 0 to 255 is
  `RUNTIME-INVALID-NUMBER` at the argument. It is built on OpenSSL, takes time
  in proportion to the list and has no effect label. `Crypto` is a reserved
  type name. It is the first part of the `Crypto` module of
  `docs/future/20-crypto.md` §20; until `Bytes` exists, bytes are a
  `List[Int]`.
- `IO.eof?()` peeks without consuming and can block until data or EOF arrives.
  Reads have no timeout, and the step budget cannot interrupt blocking I/O.
- `IO.flush()` flushes stdout only. On Linux, macOS and Windows, a print copies
  its text into a 64 KiB buffer of the stream and waits in order for room when
  the buffer is full, without stopping other tasks; a print has no timeout. The
  loop writes the buffer as the reader takes it, so a print reaches a pipe or
  file without `IO.flush()`; `IO.flush()` returns when the buffer is empty, that
  is, when the data is in the pipe or file, and it can wait for a slow reader.
  When stdout and stderr are the same terminal or file, their output keeps the
  order of the calls (on Windows, when both descriptors are one handle object,
  as with a pipe given to both); otherwise there is no order between them. On
  other systems, output functions do not flush by themselves. A stdio protocol
  writes one compact JSON message per line, flushes after each reply, and sends
  logs to `IO.warn` (stderr).
- `Time.now_ms()` is wall-clock milliseconds since the Unix epoch, and can jump;
  `Time.monotonic_ms()` never goes backward; `Time.monotonic_ns()` is the same
  clock in nanoseconds, for short durations. `Random.int(min, max)` is uniform
  over `min .. max`, both included; `min > max` halts with
  `RUNTIME-INVALID-RANGE`. `Random.float()` is in `0.0` up to, not including,
  `1.0`.
- `Profile.measure(label) do ... end` runs the block (no parameters) once and
  gives what it gives, a `Result` included; a function value of no parameters
  works too. With `AGENTICA_VM_TRACE=profile` it adds a `section` row for
  `label` to the profile: calls, steps, microseconds and GC milliseconds.
  Sections are inclusive (a section holds the measures nested in it), and a
  label inside itself in one task counts each call but its numbers once.
  `Profile.steps()` is the step count of the running task (the entries that
  `--max-steps` counts): the same on every run of the same work, with or
  without the profile. `Profile` is a reserved type name.
- `System.env(name)` reads one environment variable of the process: `ok(value)`,
  with `ok("")` for a variable set to the empty string, and `error(message)` for
  one that is not set. A name that is empty or contains `=` or NUL is an error
  too, not a halt. A value that is not valid UTF-8 is not an error: each byte
  that is not part of a valid UTF-8 sequence becomes U+FFFD, as in `Dir.list`
  names. The VM hides the variables it keeps for itself, `AGENTICA_CHANNEL` and
  a `UV_USE_IO_URING` that it set itself; a child started with `Process.spawn`
  does not get them either. No flag is needed, as for files: the permissions of
  the host user apply. The home directory is `System.env("HOME")`. There is no
  call that lists the variables. A child started with `Process.spawn` also does
  not get `AGENTICA_VM_METRICS` or `AGENTICA_VM_METRICS_FILE` (reserved for the
  VM's own metrics, a later phase), though `System.env` shows them to the
  program.
- `System.os()` is the operating system of the running program, a `String`:
  `"linux"`, `"macos"` or `"windows"`, and on any other system the lowercase
  name `uname` gives (`"unknown"` when the system cannot say or the name is not
  printable ASCII). It needs no flag.
- `System.pid()` is the process id of the running program, an `Int`. It needs no
  flag. A program that starts a VM with `--driver-pid` passes it, because the
  child VM checks it against its parent.
- `Std.source(path)` is the text of a `std/` source that the binary carries, a
  `Result[String]`, by its exact path in `stdlib/`: `"queue.agc"`,
  `"bdd/gherkin.agc"`, `"prelude/list.agc"`. Any other path, `"std/queue.agc"`
  and `"queue"` included, is an error. It needs no flag and has no effects: it
  reads constant data of the binary. `Std` is a reserved type name.
- `FrontEnd.hand_off(program, options, arguments)`,
  `FrontEnd.std_source(path)` and `FrontEnd.stdin_bytes()` belong to the front
  end of the single `agentica` binary: the first hands a compiled program (a
  `List[Int]` of bytes) to the VM, which runs it in a new runtime with the given
  VM options and arguments, the second reads an embedded `std/` source by its
  path in `stdlib/`, and the third reads standard input to its end as a
  `Result[List[Int]]` (an error over 16 MiB or when the read fails; a later
  call reads on from there). They are not for programs: they need no flag, but
  any program that calls them, and any front end run by `agentica run`, halts
  with `RUNTIME-FRONT-END-ONLY`.
- Each run has one generator, seeded from the operating system unless `agentica
  --seed N program.agc` is given (N in `0 .. 2147483647`, otherwise exit 2).
  Each task has its own generator: the main task starts from the seed, and each
  spawn takes one draw from its parent. Timers, I/O and more than one
  scheduler can still change how tasks interleave, so a multi-task run as a
  whole is not repeatable. The
  generator is not for secrets.

### JSON

`Json` and `JSON` are reserved. A `Json` value has no constructor, equality,
fields or indexing. `IO.inspect` prints `<Json>`; `to_s`, interpolation, `puts`
and `JSON.encode` give its text. Signatures are in
[`library/text-and-data/json.md`][agentica-link-4].

- `JSON.object` takes `Map[String, Json]`, `JSON.array` takes `List[Json]`, and
  `JSON.from` takes any encodable value. A non-finite Float halts with
  `RUNTIME-JSON-ENCODE`. Null and `false` stay distinct, and so do empty objects
  and empty arrays.
- `JSON.schema(T)` takes a named struct, as `decode` does, and returns an object
  schema with `properties` and `required`. Int bounds are signed 64-bit; lists
  use `items`; String-keyed maps use `additionalProperties`; nested and
  recursive structs use `$defs` and `$ref`. Extra keys stay allowed.
- `JSON.decode(text, T)` takes a named struct type, not a value; bare type names
  are valid only for `decode` and `schema`. Fields may be Int, Float, Bool,
  String, lists, String-keyed maps, and nested or recursive structs; other
  nested types are `CHECK-NOT-DECODABLE`. Malformed JSON, missing fields, wrong
  types, Int overflow and non-finite numbers give errors with a field or index
  path. Extra keys are ignored. A JSON integer may decode as a Float; a decimal
  or exponent never decodes as an Int. Decoded maps are in sorted key order.
- `JSON.parse` reads exactly one value, with optional surrounding whitespace
  (space, tab, CR, LF). Empty input, trailing content, invalid escapes, raw
  control characters and non-finite numbers are errors. A repeated object key
  keeps its last value.
- `JSON.get` needs an object and a present key; `JSON.at` needs an array and an
  index in range. Missing keys, bad indexes and wrong kinds are errors. JSON
  `false` and `null` are present values.
- The extractors (`JSON.string`, `bool`, `int`, `float`, `list`) need the exact
  kind. `JSON.int` needs an integer within 64-bit bounds, so `1.0` is not an
  Int. `JSON.float` rounds to a finite binary64, and overflow is an error.
  Parsed integers may exceed `Int` until extracted. JSON `null` stays a `Json`.
- `JSON.kind` names the kind of any `Json` and never fails: `"null"`, `"bool"`,
  `"int"`, `"float"`, `"string"`, `"array"` or `"object"`. A number written
  without fraction or exponent, or built from an Int, is `"int"`, even outside
  64-bit bounds (then `JSON.int` still errors); any other number is `"float"`.
- `JSON.encode` accepts Int, Float, Bool, String, Nil (as `null`), Json, lists,
  String-keyed maps and structs of those. Results and Int-keyed maps are
  `CHECK-NOT-ENCODABLE`. Untyped empty containers need an annotation. A
  non-finite Float halts with `RUNTIME-JSON-ENCODE`; it is never written as
  null.
- Encoding is compact: struct fields in declaration order, map entries in
  insertion order. A parsed object encodes its keys sorted by UTF-8 bytes, so
  `JSON.encode(JSON.parse(x))` is canonical: texts that differ only in
  whitespace, key order or repeated keys give the same text. `1` and `1.0` stay
  different.

### Builtin discovery and execution budget

`agentica help NAME --json` prints the name, arity, parameter types, result,
signature, effects and description, from the catalog that checking and execution
use. Effects are informational (I/O, tasks, or `test`). An unknown target exits
2. `agentica help --json` with no NAME prints every public builtin as one JSON
array, sorted by name, each element exactly what `help NAME --json` prints.

`agentica doc PATH [--json]` prints the exported API of a module with its `##`
docs (section 4): PATH is a source file or a `std/` module name. It only lexes
and parses the module, so its imports need not exist. Declarations without
`export` are left out. A lex or parse error exits 1, an unreadable path exits 2.

`agentica outline FILE [--json] [--stdin FILE]` lists the top-level declarations
of one file in source order, private ones too: imports, functions, structs with
their fields, enums with their variants, type aliases and constants, each with
`exported`, its signature, its `##` doc and summary, and its span and the span
of its name. FILE is a source file or a `std/` module name. It only lexes and
parses the file, so its imports need not exist. `--stdin FILE` takes the text of
FILE from standard input. A lex or parse error exits 1; a mistake in the
arguments or an unreadable path is `QUERY-USAGE` (section 7) and exits 2.

`agentica type-at FILE:LINE:COL [--json]` gives the checked type of the
innermost expression at a position (line and column from 1, in code points as
diagnostics count them), its span and source text, and the definition of what it
names: a function, struct, enum, variant, field or constant, with the span of
the declaration and of its name, its signature and its `##` doc (null when it
has none). A type argument is answered in a later version. A type of another
file is written through the import alias of FILE (`Models.User`). On the name of
a builtin (`split` in `xs.split(",")`) the `kind` is `builtin` and `help` holds
the object of `agentica help NAME --json`; a builtin has no definition. A local
(a parameter, a binding, a `for` variable or a name in a `case` pattern) has its
type and a definition at its binding, whether the position is on a use or on the
binding itself. The `kind` of the JSON answer is an open set: a client accepts a
value it does not know.
FILE is a path of the disk, linked and checked with its imports; it needs no
`main`. `--stdin` before the position (`type-at --stdin FILE:LINE:COL`) takes
the text of FILE from standard input. An error of the program is its own
diagnostic and exits 1. A position on no token of an expression (a blank, a
comment, the body text of a heredoc, a keyword such as `return` that is part of
no expression) is `QUERY-NO-EXPRESSION` and exits 2, as is a bad position
(`QUERY-USAGE`).

`agentica symbol NAME [PATH...] [--json] [--stdin FILE]` finds where a name is
defined in the modules linked from the files under PATH (a file or a folder,
every `*.agc` file below it; default `.`). NAME is written as the code writes
it: `total`, `User.email`, `Option.Some`, `Models.User` through an import alias
of a file of PATH, `std/queue.pop`, or a builtin (`Map.get`). Each match has its
kind (`function`, `struct`, `enum`, `alias`, `constant`, `field`, `variant` or
`builtin`), `module`, `exported` (private declarations too), signature, `##`
doc and spans; a builtin has `help`, the object of `agentica help NAME --json`.
Only lexing, parsing and linking are needed: each file of PATH is linked on its
own, and one that does not is listed under `skipped` with its first diagnostic
while the others still answer (exit 0); if none links, that diagnostic is the
answer and the exit status is 1. A name that nothing declares is
`QUERY-NOT-FOUND` and exits 2, as is a mistake in the arguments
(`QUERY-USAGE`). `--stdin FILE` takes the text of FILE from standard input and
searches it too.

`agentica --max-steps N program.agc` limits a run to N expression or statement
entries across all tasks; N must be a positive integer. Runs are unlimited by
default, and checking never spends the budget. Exhaustion is
`RUNTIME-STEP-LIMIT` at the next node. It is not a wall-clock or blocking-I/O
timeout. Each scheduler takes steps in batches, so with more than one scheduler
the limit can trip a little late; `--schedulers 1` keeps the exact count.

At the end of a run the VM waits for the buffered writes of every open file, and
for the output of stdout and stderr that a pipe has not taken yet. The wait is
always bounded: 30000 milliseconds by default. `agentica --flush-timeout MS
program.agc` or the environment variable `AGENTICA_FLUSH_TIMEOUT_MS` sets it (an
integer from 0 to 86400000; the flag wins, a bad value exits 2, and there is no
way to turn the limit off). On timeout, the run ends with the same exit code,
and stderr gets `agentica: file data may not be written: the flush took longer
than MS ms` (with `--json`, `{"flush_timeout_ms": MS, "warning": "file data may
not be written"}`).

`agentica --schedulers N program.agc` or the environment variable
`AGENTICA_SCHEDULERS` sets the number of scheduler threads (an integer from 1 to
1024; the flag wins over a valid variable, an empty variable counts as unset,
and a bad value in either exits 2, before the program starts). The default is
one per logical core the process may use, at most 1024. With more than one,
tasks run in parallel and their order is not fixed; `--schedulers 1` runs one
task at a time in the order of a single run queue. The front end always compiles
on one scheduler. `agentica test` refuses the flag (exit 2); the VMs it starts
read `AGENTICA_SCHEDULERS`.

Calls nest at most 10000 deep in each task; a deeper call is
`RUNTIME-STACK-OVERFLOW` at the call. A tail call (`return f(...)` to a user
function) replaces the caller's frame and does not count, so deep tail recursion
runs. A call inside a larger expression, such as `return 1 + f(n - 1)`, and a
call of a builtin are not tail calls.

### Running a compiled program

`agentica compile file.agc -o file.agcb` writes a program as bytecode, and
`agentica run [OPTIONS] [--] file.agcb [ARGS...]` runs it on the VM with no
front end: nothing is read, checked or compiled. `run` must be the first word
after `agentica`; after an option it is taken as a source file name and the
front end answers with a usage error (exit 2). The options are `--max-steps N`,
`--seed N`, `--flush-timeout MS`, `--schedulers N`, `--allow-run`,
`--source-root DIR` (the folder put before the file names that the bytecode
stores, except the `std/` modules), `--ai` and `--json`, each at most once and
with the values and limits they have for `agentica FILE.agc`; `--version` prints
the Agentica version and the versions of the libraries the VM links. The words
after the file are the program's arguments, even when they look like options.
The loader treats the file as untrusted. A file that is not valid bytecode, or
whose format or Agentica version is not the binary's, is refused before anything
runs; a source file also gets the hint to run it as `agentica FILE.agc`. The
exit status is the program's own: `System.exit(n)`, 1 for a diagnostic, and 2
for a command line or a start that fails (a bad option, an unreadable file, bad
bytecode), with a message that starts `agentica run:`.

[agentica-link-1]: ../../site/content/library/data-structures/list.md
[agentica-link-2]: ../../site/content/library/data-structures/map.md
[agentica-link-3]: ../../site/content/library/data-structures/set.md
[agentica-link-4]: ../../site/content/library/text-and-data/json.md
[agentica-link-5]: ../../site/content/library/data-structures/lazy.md
