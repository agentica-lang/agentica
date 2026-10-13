### Methods on builtin types

`receiver.name(args)` calls a builtin function with the receiver as its first argument. The checker picks the module from the receiver's static type, so there is no dynamic dispatch:

| Receiver type | Module |
|---|---|
| `String` | `String` |
| `List[T]` | `List` |
| `Map[K, V]` | `Map` |
| `Float` | `Float` |
| `Result[T]` | `Result` |
| `Json` | `JSON` |
| `Range` | `Range` |
| `Int` | `Int` (`times`, `upto`, `downto`) and aliases |

Only functions whose first parameter has the receiver's type are methods: `s.trim` is `String.trim(s)`, `xs.map(&f)` is `List.map(xs, &f)`, but `"a".from_int` is not a method. Without parentheses, `receiver.name` on a non-struct value is a method with no arguments: `s.length`, `xs.size`, `r.ok?`. On a struct, `.name` is field access; structs and enums have no methods, and user functions cannot be called as methods. `.call(...)` invokes a function value.

Ruby aliases:

| Receiver | Alias | Same as |
|---|---|---|
| `String` | `size` | `String.length` |
| `String` | `to_i`, `to_i!` | `String.to_int` (Result), `String.to_int!` |
| `String` | `to_f`, `to_f!` | `String.to_float` (Result), `String.to_float!` |
| `String` | `strip` | `String.trim` |
| `String` | `include?`, `start_with?`, `end_with?` | `String.contains?`, `String.starts_with?`, `String.ends_with?` |
| `String` | `to_s` | the same string |
| `List` | `length` | `List.size` |
| `List` | `push` | `List.append` |
| `List[String]` | `join` | `String.join` |
| `Int` | `to_s`, `to_f` | `String.from_int`, `Float.from_int` |
| `Float` | `to_s` | `String.from_float` |
| `Float` | `to_i`, `to_i!` | `Float.to_int` (Result), `Float.to_int!` |
| any data value | `to_s` | the text `"#{x}"` gives |
| any data value | `inspect` | the text `IO.inspect(x)` prints |

Unlike Ruby, `"abc".to_i` returns `Result[Int]` (an error here), not `0`; `to_i!` halts on bad text. An unknown method is `CHECK-UNKNOWN-METHOD`, with a suggestion or the list of that type's methods.

Every data value has `to_s`: numbers, `Bool`, `String`, `nil`, `Json`, ranges, and lists, maps, Results, structs and enums made of those. `x.to_s` is the text `"#{x}"` gives: a `String` as is, a `Json` as its JSON text, and anything else in its `IO.inspect` form (`true`, `nil`, `[1, 2]`, `ok(3)`, `Item(name: "a")`, `Shape.Box(1, 2)`). `puts(x)`, `print(x)` and `IO.warn(x)` take any value with `to_s` and write that text. Only a top-level `Json` becomes JSON text; inside a list or Result it shows as `<Json>`, so `puts(JSON.parse(s))` prints `ok(<Json>)`. Functions, tasks and resource handles (sockets, files, processes, HTTP values) have no `to_s`: printing or interpolating one is `CHECK-TYPE-MISMATCH`, and `.to_s` on one is `CHECK-UNKNOWN-METHOD`. A struct field named `to_s` is read as the field. Unlike Ruby, `nil.to_s` is `"nil"`, and `puts([1, 2])` writes `[1, 2]` on one line.

`x.inspect` returns the `IO.inspect` form as a `String`, for the same types as `to_s`. It differs from `to_s` only for strings, which keep their quotes (`"a".inspect` is `"a"` with the quote characters), and for `Json`, which gives `<Json>`. Use `IO.inspect(x)` to print that form and get `x` back. The debug form is for display: strings use the host's escapes, so it is not guaranteed to be valid Agentica source (`"a\#{b}".inspect` shows `#{` without the backslash).

Values are immutable, so a method never changes its receiver: `xs.push(2)` returns a new list. Calling a builtin without effects and ignoring a non-`Void` result is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Functions ending in `!` are exempt, since they can halt, and so are builtins that take a function (`xs.map(&save)`), since the function may have effects. A negative literal receiver needs parentheses: `(-5).to_s`, because `-5.to_s` is `-(5.to_s)`.

```ruby
words = line.strip.split(" ")
puts(words.join(","))
first = words[0].to_i!
xs = xs.push(first)
```

### Minimal builtin functions

```text
puts(value: T) -> Void        # T has to_s
print(value: T) -> Void       # no newline
gets() -> Result[String]
gets!() -> String
```

`puts` writes the text and a newline; `print` writes it without one. `gets` and `gets!` are `IO.gets` and `IO.gets!`, and like them they may drop their parentheses (`line = gets!.strip`). These names are reserved and cannot be redefined.

To work with maps and lists there are two builtin modules, `Map` and `List`, called as `Module.function(...)`. Their functions are generic, so the checker treats them specially. The names `Map` and `List` are reserved and cannot be redefined.

The signatures of the `Map` and `List` functions are in `agentica help NAME --json` and in the library pages [`map.md`](../../site/content/library/map.md) and [`list.md`](../../site/content/library/list.md).

Callbacks (`List.map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`) take a block, a named function reference (`&name`) or a function-valued variable. They run exactly once per element, left to right, and use the caller's execution budget and error handling. Callback parameter and return types must match exactly; `map` callbacks must return data, not Void. Callback signatures (`&name`, a `Fn` variable, or a block with annotated parameters such as `do |x: Int|`) infer empty input lists and empty `reduce` initial values. `List.each` calls `f` on each element in order; `List.any?` and `List.all?` stop at the first element that decides the answer.

Collection operations preserve their inputs.

| Function | Behavior | Cost |
|---|---|---|
| `List.map`, `List.filter` | transform each element; keep the elements whose predicate returns true; both preserve order | O(n), excluding callback work |
| `List.reduce` | folds left, calling `f(accumulator, item)` with the initial value first; an empty list returns the initial value | O(n), excluding callback work |
| `List.append`, `List.reverse` | a new list | O(n); repeated appends can cost O(n²) |
| `List.set` | zero-based; `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument if it is negative or outside the list | O(n) |
| `List.repeat` | `count` in 0..1048576, an empty typed list for zero; otherwise `RUNTIME-INVALID-COUNT` at the count argument | O(count) |
| `List.concat` | joins lists of the same element type | O(length of the first list) |
| `List.take`, `List.drop` | the first `count` elements; the list without them. `count` must be nonnegative (`RUNTIME-INVALID-COUNT` at the count argument); a count above the length gives the whole list or an empty list, respectively | O(n) with the current list representation |
| `List.at` | zero-based; `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument for a negative or out-of-range index, like indexing syntax | O(n) |
| `List.sort`, `List.sort_by` | ascending; elements (for `sort`) or keys (for `sort_by`, whose function runs once per element, left to right) must be `Int`, `Float` or `String`, else `CHECK-TYPE-MISMATCH`. Stable: equal elements keep their order. Strings compare by Unicode code point (`"B"` before `"a"`); Float NaN goes last | O(n log n), plus the key calls |
| `Map.get` (two arguments) | `ok(value)` for a present key, `error(message)` for an absent one | |
| `Map.get` (three arguments) | the present value or the default; the default is always evaluated, even when the key exists. `false` and `nil` are present values | |
| `Map.delete` | ignores absent keys and keeps the order of the remaining keys; a deleted key reinserted with `Map.put` goes to the end | O(n) |
| `Map.values` | follows the `Map.keys` order | O(n) |

Expected types flow into these operations for contextual empty collections and Results; without enough context the existing empty-collection diagnostics apply.

The `String` module works on text. `String.length` and `String.slice` count Unicode characters, not bytes; a `slice` out of range is a runtime error. With a non-empty `sep`, `String.split(s, sep)` keeps every part, even empty ones at the ends or between two separators, so `String.join(String.split(s, sep), sep)` gives back `s`; `String.split("", sep)` is `[""]`. `String.split(s, "")` returns a list with one Unicode character per element. The conversions `String.to_int!` and `String.to_float!` accept decimal numbers with an optional sign; `to_int!` fails with `RUNTIME-INVALID-NUMBER` if the text is not a decimal integer and with `RUNTIME-INTEGER-OVERFLOW` if it is outside the range of `Int`, while `to_float!` rejects text that is not a real decimal with `RUNTIME-INVALID-NUMBER`.

```text
Float.from_int(n: Int) -> Float
Float.to_int(x: Float) -> Result[Int]
Float.to_int!(x: Float) -> Int
```

The signatures of the `String` functions are in `agentica help NAME --json` and in [`string.md`](../../site/content/library/string.md); those of `Float` are in [`numbers.md`](../../site/content/library/numbers.md).

`String.index_of` returns the character index of the first match, `ok(0)` for an empty part, and an error when the part is absent. `String.at` reads one character at a zero-based index and halts with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument outside the string. `String.reverse` reverses Unicode characters. `String.code` returns the code point of a one-character string; `String.from_code` builds one from a Unicode scalar value (0..0x10FFFF, without surrogates). Both halt with `RUNTIME-INVALID-CHARACTER` at their argument on other input. `Float.from_int` converts to the nearest Float. `Float.to_int` truncates toward zero; NaN and infinity are errors, and results outside `Int` are errors. `Float.to_int!` halts instead, with `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`.

The `IO` module writes and reads through the standard ports; `IO.warn` writes to standard error. `IO.inspect` prints any value in a stable debug form and returns it. `IO.gets` returns `ok(line)` without its terminator (LF, CR, or CRLF), or an error value at EOF. A blank line is `ok("")`, not EOF. `IO.gets!` returns the line directly and halts with `RUNTIME-END-OF-INPUT` at EOF; `IO.eof?` lets you check first. The `System` module exposes the program arguments and ends the run with a code.

```text
System.args() -> List[String]
System.exit(code: Int) -> Void
```

The signatures of the `IO`, `Time` and `Random` functions are in `agentica help NAME --json` and in [`io.md`](../../site/content/library/io.md) and [`system.md`](../../site/content/library/system.md).

`Time.now_ms()` reads wall-clock time as milliseconds since the Unix epoch; it can jump when the system clock changes. `Time.monotonic_ms()` counts milliseconds from an arbitrary origin and never goes backward; subtract two readings to measure durations. `Random.int(min, max)` returns a uniform `Int` in `min .. max`, both inclusive, over the whole `Int` range; `min > max` halts with `RUNTIME-INVALID-RANGE` at the call. `Random.float()` returns a uniform `Float` in `0.0` up to, but not including, `1.0`. Each run has its own generator. Without `--seed` it is seeded from operating-system randomness, so runs differ. `agentica --seed N program.agc` (N in `0 .. 2147483647`, otherwise exit 2) repeats the same sequence for the same program and input. `agentica --seed N test` passes the seed to every scenario's step program and to the programs under test. Each task has its own generator: the main task is seeded from `--seed`, and each spawn takes one draw from the parent's generator to seed the child, so a task's values depend only on its own calls and on how many tasks its parent spawned before it. With `--seed`, only each task's own values repeat on the VM: how tasks interleave can still depend on timer and thread-pool timing (sleeps, file and stdin reads), even on one scheduler, so a multi-task run as a whole is not repeatable. The generator is not suitable for secrets. `Time` and `Random` are reserved builtin module names: no declaration or import alias may use them.

- `IO.read()` drains text until EOF; do not use it to read one message from a peer that keeps stdin open. `IO.gets()` reads a line instead. Both read stdin through the VM's own input buffer. On Linux it is filled by reads on the I/O thread pool, so other tasks keep running while one waits for input; on other platforms the read blocks.
- `IO.read_bytes(count)` waits for exactly `count` bytes or EOF and returns a list of integers in `0 .. 255`, with no UTF-8 decoding. A short final read succeeds; EOF before any bytes is `ok([])`. Zero returns `ok([])` without consuming input, even before EOF. Counts must be `0 .. 1048576` (1 MiB per call), bounding eager allocation; invalid counts return an error without consuming input. Input-port failures also return an error. Larger streams can be processed in multiple reads.
- `String.from_bytes(data)` checks every integer is `0 .. 255`, then decodes UTF-8 strictly. Empty bytes produce `ok("")`; invalid, overlong, surrogate, or incomplete sequences return an error, never replacement characters. Byte reads may split a multibyte character; decode only when its complete bytes are available. Existing text and byte readers share one port; text readers should only be used at a complete character boundary.
- `IO.eof?()` peeks at the next byte without consuming it. It can block while awaiting data or EOF, but never waits to decode a whole UTF-8 character. It is not a readiness poll. Reads have no timeout, and the step budget cannot interrupt blocking I/O.
- `IO.flush()` flushes stdout and returns nil; it does not close the stream or flush stderr. Output functions do not automatically flush. For interactive stdio protocols, write one compact JSON message per line and flush after each response; logs go to stderr with `IO.warn`.

### JSON

`Json` and `JSON` are reserved builtin names. A `Json` is opaque: it has no constructor, equality, fields, or direct indexing. `IO.inspect` prints `<Json>` and `j.inspect` gives `"<Json>"` without exposing its contents. `j.to_s`, `"#{j}"`, `puts(j)` and `JSON.encode(j)` give its JSON text.

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(value: Json) -> Bool
JSON.schema(type: T) -> Json
JSON.decode(s: String, type: T) -> Result[T]
JSON.parse(s: String) -> Result[Json]
JSON.encode(value: T) -> String
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
JSON.list(j: Json) -> Result[List[Json]]
```

JSON builders create Json values directly: object takes Map[String, Json],
array takes List[Json], and from accepts the same recursively encodable data
as JSON.encode. Non-finite Float conversion halts with RUNTIME-JSON-ENCODE.
Null and false remain distinct, as do empty objects and arrays.

JSON.schema(User) accepts the same named structs as JSON.decode and returns
an object schema with properties and required fields. Int schemas specify
signed 64-bit bounds; lists use items and String-keyed maps use
additionalProperties. Nested/recursive structs use $defs/$ref. Extra struct
keys remain allowed, matching decoding. Schema is a Json value, not text.

`JSON.decode(text, User)` returns Result[User]. Its second argument is a named
struct type, not a runtime value; bare type names are valid only for decode/schema.
Fields may contain Int, Float, Bool, String, lists, String-keyed maps, and nested
or recursive structs. Unsupported nested types give CHECK-NOT-DECODABLE.
Malformed JSON, missing fields, wrong types, Int overflow, or non-finite Float
conversion return errors with field/index paths. Extra object keys are ignored.
Integer JSON values may decode as Float; decimal/exponent values never decode
as Int. Maps decoded from JSON use sorted key order.

- `JSON.parse` reads exactly one JSON value, with optional surrounding JSON whitespace (space, tab, CR, LF). Empty input, malformed JSON, trailing content, invalid Unicode escapes, raw control characters in strings, or non-finite parsed numbers return an error. A repeated object key keeps the last value.
- `JSON.get` requires an object and a present key; `JSON.at` requires an array and an index in `0 .. length - 1`. Missing keys, bad indexes, and wrong kinds return errors, not runtime diagnostics. JSON `false` and `null` are valid present values.
- String and Bool extraction require the exact JSON kind. `JSON.int` requires an integer within signed 64-bit bounds; a decimal or exponent form is not an Int, even if mathematically integral. `JSON.float` accepts an integer or decimal/exponent number and converts it to finite binary64, with normal rounding; conversion overflow returns an error. Parsed integers may exceed Int bounds until extracted.
- `JSON.list` returns an array's elements as opaque Json values in order; heterogeneous arrays are valid. JSON null stays inside Json, distinct from a Bool or Nil extraction (there is no null extractor yet).
- `JSON.encode` accepts Int, Float, Bool, String, Nil (as `null`), Json, lists, String-keyed maps, and structs whose nested types are also encodable. Results and Int-keyed maps, including empty or nested ones, are `CHECK-NOT-ENCODABLE` errors. Untyped empty containers still need an annotation.
- Encoding produces compact JSON, preserving struct declaration order and map insertion order. A parsed object holds each key once (a repeated key keeps its last value) and encodes with its keys sorted by their UTF-8 bytes, so `JSON.encode(JSON.parse(x))` is canonical: two texts that differ only in whitespace, key order or repeated keys give the same text, while arrays keep their order and numbers their kind (`1` and `1.0` stay different). Comparing canonical texts therefore compares JSON values. Objects built with `JSON.object` or `JSON.from` have no fixed order. Non-finite Floats halt with `RUNTIME-JSON-ENCODE` at the encode call; they are never silently replaced by null. The VM's `vm/json.c` parses and encodes JSON.
- See `examples/json.agc` for encoding, extraction, and `try`.

### Builtin discovery and execution budget

`Map.get` and `ok` select signatures by arity. Their text help lists all variants; JSON help contains `name`, `description`, `effects`, and `overloads`, whose entries describe each signature. Other builtin help keeps the single-signature JSON format.

`agentica help NAME --json` prints name, arity, parameter types, result, signature, effects, and description from the same catalog used by checking and execution. Effects say what a builtin does besides returning its result: I/O, tasks, or `test` for an assertion that records a failure on its test. They are informational, not permission enforcement; a call to a builtin with no effects whose result is unused is CHECK-UNUSED-VALUE. Unknown help targets exit 2. Options may also precede `help`.

`agentica --max-steps N program.agc` limits execution to N expression/statement entries, including repeated loop conditions across all tasks. N must be a positive integer (bad CLI values exit 2). Runs are unlimited by default; checking never executes or spends the budget. Exhaustion is `RUNTIME-STEP-LIMIT` at the next node to execute. The synchronized counter resets per evaluation. This is not a wall-clock or blocking-I/O timeout.

At the end of a run the VM writes the buffered output of every file still open and waits until those writes finish. `agentica --flush-timeout MS program.agc` waits at most MS milliseconds (a non-negative integer; bad values exit 2). When time runs out the run still ends, with the same exit code, and stderr gets one line saying that file data may not be written: `agentica: file data may not be written: the flush took longer than MS ms`, or in `--json` mode `{"flush_timeout_ms": MS, "warning": "file data may not be written"}`. Without the flag there is no limit, so a write to a FIFO nobody reads keeps the run open.

Calls nest at most 10000 deep in each task; a deeper call is `RUNTIME-STACK-OVERFLOW` at the call. A tail call (`return f(...)`, a direct call to a user function) replaces the caller's frame and does not count toward this limit, so deep tail recursion runs.
