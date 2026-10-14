### Methods on builtin types

`receiver.name(args)` calls a builtin whose first parameter has the receiver's type. The checker picks the module from the static type (`String`, `List`, `Map`, `Float`, `Result`, `Range`, `Int`, and `Json` through `JSON`); there is no dynamic dispatch. `s.trim` is `String.trim(s)`, but `"a".from_int` is not a method. Without parentheses, `receiver.name` on a non-struct value is a method without arguments (`s.length`, `r.ok?`). On a struct, `.name` is a field. Structs and enums have no methods.

Ruby aliases are the module functions named in the library pages: `size`, `length`, `strip`, `include?`, `start_with?`, `end_with?`, `push`, `join`, `to_f`, and `to_s` and `inspect` on any data value. Two differ from Ruby: `to_i` and `to_f` on text return a `Result` (`"abc".to_i` is an error, not `0`), and `to_i!` and `to_f!` halt on bad text. An unknown method is `CHECK-UNKNOWN-METHOD`.

`x.to_s` is the text `"#{x}"` gives: a `String` as is, a `Json` as its JSON text, and any other data value in its `inspect` form (`[1, 2]`, `ok(3)`, `Item(name: "a")`). Inside a list, a `Json` shows as `<Json>`. Functions, tasks and handles have no `to_s`, so printing or interpolating one is `CHECK-TYPE-MISMATCH`. Unlike Ruby, `nil.to_s` is `"nil"`. `x.inspect` keeps a string's quotes; it is for display, not valid source.

Values are immutable: a method never changes its receiver, so `xs.push(2)` returns a new list. A builtin without effects whose non-Void result is dropped is `CHECK-UNUSED-VALUE`; write `xs = xs.push(2)`. Builtins with effects, functions ending in `!`, and builtins that take a function are exempt. A negative literal receiver needs parentheses: `(-5).to_s`.

### Minimal builtin functions

`puts(value)` writes the value's `to_s` and a newline; `print` writes without one. `gets` and `gets!` are `IO.gets` and `IO.gets!`, and may drop their parentheses (`line = gets!.strip`). `Map` and `List` are builtin modules whose generic functions the checker treats specially. Signatures are in [`library/list.md`](../../site/content/library/list.md) and [`library/map.md`](../../site/content/library/map.md).

Callbacks (`List.map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`) take a block, `&name` or a function variable. Each runs once per element, left to right, under the caller's budget. Parameter and return types must match exactly, and a `map` callback returns data, not Void. Annotated block parameters let an empty list or an empty `reduce` initial value infer its type. `List.any?` and `List.all?` stop at the first deciding element.

Collection operations preserve their inputs. Costs exclude callback work.

- `List.map` and `List.filter` are O(n). `List.reduce` folds left, calling `f(accumulator, item)`; an empty list gives the initial value.
- `List.append` and `List.reverse` are O(n), so repeated appends can cost O(n²). `List.concat` joins lists of one element type.
- `List.set` and `List.at` are zero-based. A negative or out-of-range index is `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument.
- `List.repeat` takes a count from 0 to 1048576; zero gives an empty list of the element type. Other counts are `RUNTIME-INVALID-COUNT`.
- `List.take` and `List.drop` need a nonnegative count (`RUNTIME-INVALID-COUNT`). A larger count gives the whole list or an empty list.
- `List.sort` and `List.sort_by` sort ascending. Elements, or the keys from `sort_by` (computed once per element, left to right), must be `Int`, `Float` or `String`; otherwise `CHECK-TYPE-MISMATCH`. The sort is stable. Strings compare by code point, so `"B"` is before `"a"`. NaN goes last. O(n log n), plus key calls.
- `Map.get` with two arguments gives `ok(value)` or `error(message)`. With three, the default is always evaluated; `false` and `nil` are present values.
- `Map.delete` ignores absent keys and keeps the order of the rest; a key put back later goes to the end. It is O(n). `Map.values` follows the `Map.keys` order.

Expected types flow into these operations for empty collections and Results.

- `String.length` and `String.slice` count characters, not bytes. An out-of-range `slice` is a runtime error.
- `String.split(s, sep)` keeps empty parts, so `String.join(String.split(s, sep), sep)` gives `s`. `String.split("", sep)` is `[""]`; `String.split(s, "")` gives one character per element.
- `String.to_int!` accepts a signed decimal: `RUNTIME-INVALID-NUMBER` for other text, `RUNTIME-INTEGER-OVERFLOW` outside `Int`. `String.to_float!` rejects text that is not a real decimal with `RUNTIME-INVALID-NUMBER`.
- `String.index_of` gives the character index of the first match (`ok(0)` for an empty part), or an error when absent. `String.at` halts with `RUNTIME-INDEX-OUT-OF-RANGE` outside the string.
- `String.code` and `String.from_code` halt with `RUNTIME-INVALID-CHARACTER` on other input: a one-character string, or a scalar value (0 to 0x10FFFF, no surrogates).
- `Float.to_int` truncates toward zero; NaN, infinity and results outside `Int` are errors. `Float.to_int!` halts instead, with `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`.

- `IO.gets` gives `ok(line)` without its terminator (LF, CR or CRLF), or an error at EOF; a blank line is `ok("")`. `IO.gets!` halts with `RUNTIME-END-OF-INPUT` at EOF. `IO.read()` drains stdin to EOF, so it cannot read one message from a peer that keeps stdin open.
- `IO.read_bytes(count)` waits for exactly `count` bytes or EOF, and gives integers 0 to 255 with no decoding. Counts are 0 to 1048576; zero gives `ok([])` without consuming input. `String.from_bytes` decodes strictly as UTF-8: invalid, overlong, surrogate and incomplete sequences are errors, never replacement characters.
- `IO.eof?()` peeks without consuming and can block until data or EOF arrives. Reads have no timeout, and the step budget cannot interrupt blocking I/O.
- `IO.flush()` flushes stdout only. On Linux, a print copies its text into a 64 KiB buffer of the stream and waits in order for room when the buffer is full, without stopping other tasks; a print has no timeout, and `IO.flush()` returns when the buffer is empty. Between stdout and stderr there is no order when both go to the same place. Output functions do not flush by themselves. A stdio protocol writes one compact JSON message per line, flushes after each reply, and sends logs to `IO.warn` (stderr).
- `Time.now_ms()` is wall-clock milliseconds since the Unix epoch, and can jump; `Time.monotonic_ms()` never goes backward. `Random.int(min, max)` is uniform over `min .. max`, both included; `min > max` halts with `RUNTIME-INVALID-RANGE`. `Random.float()` is in `0.0` up to, not including, `1.0`.
- Each run has one generator, seeded from the operating system unless `agentica --seed N program.agc` is given (N in `0 .. 2147483647`, otherwise exit 2). Each task has its own generator: the main task starts from the seed, and each spawn takes one draw from its parent. Timers and I/O can still change how tasks interleave, so a multi-task run as a whole is not repeatable. The generator is not for secrets.

### JSON

`Json` and `JSON` are reserved. A `Json` value has no constructor, equality, fields or indexing. `IO.inspect` prints `<Json>`; `to_s`, interpolation, `puts` and `JSON.encode` give its text. Signatures are in [`library/json.md`](../../site/content/library/json.md).

- `JSON.object` takes `Map[String, Json]`, `JSON.array` takes `List[Json]`, and `JSON.from` takes any encodable value. A non-finite Float halts with `RUNTIME-JSON-ENCODE`. Null and `false` stay distinct, and so do empty objects and empty arrays.
- `JSON.schema(T)` takes a named struct, as `decode` does, and returns an object schema with `properties` and `required`. Int bounds are signed 64-bit; lists use `items`; String-keyed maps use `additionalProperties`; nested and recursive structs use `$defs` and `$ref`. Extra keys stay allowed.
- `JSON.decode(text, T)` takes a named struct type, not a value; bare type names are valid only for `decode` and `schema`. Fields may be Int, Float, Bool, String, lists, String-keyed maps, and nested or recursive structs; other nested types are `CHECK-NOT-DECODABLE`. Malformed JSON, missing fields, wrong types, Int overflow and non-finite numbers give errors with a field or index path. Extra keys are ignored. A JSON integer may decode as a Float; a decimal or exponent never decodes as an Int. Decoded maps are in sorted key order.
- `JSON.parse` reads exactly one value, with optional surrounding whitespace (space, tab, CR, LF). Empty input, trailing content, invalid escapes, raw control characters and non-finite numbers are errors. A repeated object key keeps its last value.
- `JSON.get` needs an object and a present key; `JSON.at` needs an array and an index in range. Missing keys, bad indexes and wrong kinds are errors. JSON `false` and `null` are present values.
- The extractors (`JSON.string`, `bool`, `int`, `float`, `list`) need the exact kind. `JSON.int` needs an integer within 64-bit bounds, so `1.0` is not an Int. `JSON.float` rounds to a finite binary64, and overflow is an error. Parsed integers may exceed `Int` until extracted. JSON `null` stays a `Json`.
- `JSON.encode` accepts Int, Float, Bool, String, Nil (as `null`), Json, lists, String-keyed maps and structs of those. Results and Int-keyed maps are `CHECK-NOT-ENCODABLE`. Untyped empty containers need an annotation. A non-finite Float halts with `RUNTIME-JSON-ENCODE`; it is never written as null.
- Encoding is compact: struct fields in declaration order, map entries in insertion order. A parsed object encodes its keys sorted by UTF-8 bytes, so `JSON.encode(JSON.parse(x))` is canonical: texts that differ only in whitespace, key order or repeated keys give the same text. `1` and `1.0` stay different.

### Builtin discovery and execution budget

`agentica help NAME --json` prints the name, arity, parameter types, result, signature, effects and description, from the catalog that checking and execution use. Effects are informational (I/O, tasks, or `test`). An unknown target exits 2.

`agentica --max-steps N program.agc` limits a run to N expression or statement entries across all tasks; N must be a positive integer. Runs are unlimited by default, and checking never spends the budget. Exhaustion is `RUNTIME-STEP-LIMIT` at the next node. It is not a wall-clock or blocking-I/O timeout.

At the end of a run the VM waits for the buffered writes of every open file, and for the output of stdout and stderr that a pipe has not taken yet. The wait is always bounded: 30000 milliseconds by default. `agentica --flush-timeout MS program.agc` or the environment variable `AGENTICA_FLUSH_TIMEOUT_MS` sets it (an integer from 0 to 86400000; the flag wins, a bad value exits 2, and there is no way to turn the limit off). On timeout, the run ends with the same exit code, and stderr gets `agentica: file data may not be written: the flush took longer than MS ms` (with `--json`, `{"flush_timeout_ms": MS, "warning": "file data may not be written"}`).

Calls nest at most 10000 deep in each task; a deeper call is `RUNTIME-STACK-OVERFLOW` at the call. A tail call (`return f(...)` to a user function) replaces the caller's frame and does not count, so deep tail recursion runs.
