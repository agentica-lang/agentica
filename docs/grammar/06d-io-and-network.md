### TCP, TLS and HTTP

Networking uses the normal expression syntax and lightweight tasks. The network
names in §4 are reserved, and handles are opaque: they belong to their run and
close when it ends. No CLI flag is needed; `--deny-net` turns them off
([`06b-builtins.md`](06b-builtins.md)). The functions, the timeouts, the limits
and the errors are in the
[`TCP, TLS and HTTP` page](../../site/content/library/io-and-system/network.md);
the protocol is in [`docs/vm/10-io-http.md`](https://github.com/agentica-lang/agentica/blob/master/docs/vm/10-io-http.md) and
[`docs/vm/10-io-tls.md`](https://github.com/agentica-lang/agentica/blob/master/docs/vm/10-io-tls.md).

#### HTTP client and server (`std/http`)

HTTP is the `std/http` library, imported with `import HTTP from "std/http"`; any
alias works. It calls the internal module `HttpWire`, which no other module can
name (`CHECK-UNKNOWN-NAME`). A complete program is in
[`examples/http_server.agc`](../../examples/http_server.agc).

### Logging (`std/logger`)

`std/logger` is imported with `import Logger from "std/logger"`. It calls the
internal module `LogRegistry`, which no other module can name
(`CHECK-UNKNOWN-NAME`). `LogLevel` and `LogEvent` are builtin types and their
names are reserved in every program (`CHECK-REDEFINED-NAME`). The levels,
handlers and formats are in the
[`Logger` page](../../site/content/library/io-and-system/logger.md).

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. A file handle
is opaque, belongs to one evaluation, and closes when it ends. The host user's
permissions apply; `--deny-fs` turns these calls off. Every File, Dir and Path
call that takes `timeout_ms` defaults it to 30000, and `File.open` defaults
`mode` to `"read"` (see "Default parameter values" in section 6). The calls, the
platform differences and the errors are in the
[`File, Dir and Path` page](../../site/content/library/io-and-system/files.md);
the compression calls are in the
[`Zlib` page](../../site/content/library/text-and-data/zlib.md) (`Zlib` is a
reserved name).

### Processes

`Process` is an opaque handle, with no constructor, fields, equality or JSON
encoding; `IO.inspect` prints `<Process>`. `agentica --deny-run file.agc` (or
`--sandbox`) turns the starts off. The calls, the lookup of a command, the
captured output and the channel to a child are in the
[`Process` page](../../site/content/library/io-and-system/process.md).

### Native code

An `extern` block (section 5) declares C functions of a native library, which a
program then calls like any `def`. The calls that read and write memory, the
resources, the out parameters, the structs, the compute calls and the waits are
in the
[`Native code` pages](../../site/content/library/io-and-system/native/_index.md).

```ruby
extern "libm.so.6"
  export def cos(x: C.Double) -> C.Double
end
```

The rules (the C types and the codes of a bad one, the library string and
`Native.load`, `Native.function?`, resources, callbacks, `--deny-native`, the
systems that run native code) are in those pages. The language fixes these:

- `C.UInt64` and `C.ULong` do not exist (`PARSE-EXTERN-TYPE`): declare a
  `uint64_t` or `size_t` as `C.Int64` and an `unsigned long` as `C.Long`.
- `C.Pointer` is a builtin type that any code may hold, with no `==`. A
  resource has no `to_s` (`CHECK-TYPE-MISMATCH`) and no JSON encoding
  (`CHECK-NOT-ENCODABLE`), as other handles.
- `Native.closed?(x)` and `Native.size_of(Name)` take a resource or buffer and a
  struct name; any other argument is `CHECK-TYPE-MISMATCH`.
- `Native.callback(Name, &function)` takes a declared function named with `&`:
  an `Fn` value or a function of an extern block is `CHECK-NATIVE-CALLBACK`.
- The VM trusts the signature: a wrong one is undefined behavior in C, and
  native code runs with the rights of the program.
- A function of an `extern module` block (section 5) takes and returns `Int`,
  `Float`, `Bool`, `String`, `Bytes`, `Void` as the result, a `List`,
  `Optional` or `Result` of these, a `Map` with `Int`, `String` or `Bytes` keys,
  and the structs and enums of the program that are not generic, whose fields
  and payloads cross too. A resource of the block crosses as the whole type of
  a parameter, and anywhere in a result but in a field or payload. Any other
  type, or two such types or resources of one bare name in one block, is
  `CHECK-NATIVE-TYPE` at the type in the signature.
- The first call of a module function loads the module and binds the function
  by name: the module's table must have the same canonical signature (aliases
  expanded, user types by their bare names), the same mode (`def` short,
  `compute def` dirty) and each user type with the same fields or variants, else
  `RUNTIME-NATIVE-SIGNATURE`; a module that does not load is
  `RUNTIME-NATIVE-LOAD`. A `compute def` of a module runs on the compute pool
  as one of an extern block does. A resource of a module is a resource as
  above: owned by the task that made it, held by each call that takes it, and
  freed once by the module's free function.
