### TCP, TLS and HTTP

Networking uses the normal expression syntax and lightweight tasks. The network
names in §4 are reserved, and handles are opaque: they belong to their run and
close when it ends. No CLI flag is needed; `--deny-net` turns them off
([`06b-builtins.md`](06b-builtins.md)). The functions, the timeouts, the limits
and the errors are in the
[`TCP, TLS and HTTP` page](../../site/content/library/io-and-system/network.md);
the protocol is in [`docs/vm/10-io-http.md`](../vm/10-io-http.md) and
[`docs/vm/10-io-tls.md`](../vm/10-io-tls.md).

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

- The C types are the integers `C.Int8`, `C.Int16`, `C.Int32`, `C.Int64`
  (`int8_t` to `int64_t`), `C.UInt8`, `C.UInt16`, `C.UInt32` (`uint8_t` to
  `uint32_t`) and `C.Long` (`long`: 32 bits on Windows, 64 on Linux and
  macOS), each an `Int` in Agentica, `C.Double` (`double`, `Float`), `C.Float`
  (a 32-bit `float`, `Float`), `C.Bool` (`bool`, `Bool`), `C.String` (a
  `const char *`, `String`), `C.Pointer`, `C.Bytes`, `C.Function` (a function
  pointer) and the resources and structs of the block; a result may also be
  `Void`. `C.Int` is `PARSE-EXTERN-TYPE`: write the width. A function takes at
  most 64 parameters (`PARSE-EXTERN-ARITY`).
- A signed integer result is sign-extended and an unsigned one zero-extended,
  so a `C.UInt32` above 2^31 is a positive `Int`. There is no unsigned 64-bit
  type: declare a `uint64_t` or `size_t` as `C.Int64` and an `unsigned long` as
  `C.Long` (`C.UInt64` and `C.ULong` are `PARSE-EXTERN-TYPE`).
- The library is a plain string literal: a name without `/`, which the system
  loader looks up, or an absolute path; anything else is `PARSE-EXTERN-LIBRARY`.
  A library, dependency or function that cannot be found is
  `RUNTIME-NATIVE-LOAD` at the extern function. A package names its libraries in
  its manifest (`[native.NAME]`, 05b-modules.md).
- `Native.load("NAME") -> Result[Void]` opens a library before its first call.
  Its argument is a string literal that means what `extern "NAME"` means;
  anything else is `CHECK-NATIVE-LOAD` at the argument.
- `C.Pointer` is a C pointer (`void *`), a builtin type that any code may hold.
  It has no `==`, and `IO.inspect` prints `<C.Pointer>`. `C.Bytes` is a
  parameter only (as a result it is `PARSE-EXTERN-TYPE`): a `Bytes`.
- A function declared `-> Db`, for a `resource Db, free: db_close` of the block,
  gives a `Result[Db]`. A `def` of the free function in the same block is
  `PARSE-EXTERN-FREE`. `to_s` of a resource is `CHECK-TYPE-MISMATCH`, and its
  JSON encoding is `CHECK-NOT-ENCODABLE`, as for other handles. An `out`
  parameter makes the call return a record, with the C result as `result` and
  each value C left in a slot as the field of its name. A `struct` of the block
  is a record, copied both ways. `Native.closed?(x)` and `Native.size_of(Name)`
  take a resource or buffer and a struct name; any other argument is
  `CHECK-TYPE-MISMATCH`.
- Native code is allowed by default and can start programs itself.
  `agentica --deny-native file.agc` (and `agentica run --deny-native`, or any
  `--deny-*` flag, or `--sandbox`) refuses a program that declares any extern
  function or calls a `Native.*` builtin before anything runs:
  `RUNTIME-NATIVE-DENIED`, exit 2. Under `agentica test` such a test file is a
  file error with that code.
- Elsewhere than Linux and macOS (x86_64 and arm64) and Windows x64, such a
  program is refused at load with `RUNTIME-NATIVE-UNSUPPORTED`, exit 2;
  `check`, `compile` and the queries work on every system.
- The VM trusts the signature: a wrong one is undefined behavior in C, and
  native code runs with the rights of the program.
