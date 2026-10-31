# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic
Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `HttpClientOptions(proxy: "http://host:port")` sends the client's `http://`
  requests through a forward proxy in absolute form (`https://` with a proxy is
  an error until `CONNECT`).
- `agentica fmt --check [PATH...]` lists the `.agc` files whose layout the
  formatter would change and exits 1 if there are any (it keeps a short `do`
  block or case arm on one line); `agentica fmt --tree FILE` prints the tree
  that formatting keeps.
- `channel.empty?` is `true` when no value is left to receive.
- `HTTP.Handler` and `HTTP.StreamHandler` name the handler types of
  `HTTP.listen` and its forms; a middleware is a function from a `Handler` to a
  `Handler`.
- `HTTP.listen_upload` (and `listen_upload_tls`) gives a handler the body of the
  request on a channel as it arrives (`HTTP.RequestBody`: `pieces` and a `done`
  task), for uploads too big to hold; `HTTP.UploadHandler` names its type, and
  `HTTP.read_all` collects a body for a small route.
- `HTTP.listen_websocket` (and `listen_websocket_tls`) upgrades a request to a
  WebSocket (RFC 6455): `HTTP.accept_websocket` checks the handshake and runs a
  session that gets `HTTP.Message`s (text, binary, ping, pong, close) on two
  channels, and `HTTP.upgrade_only` wraps an ordinary `Handler` for the other
  routes. Unmasking is slow (about 7 MB/s); the other `listen` forms still
  answer an `Upgrade` 501.

### Changed

- **Breaking:** `channel.closed?` is `true` as soon as the channel is closed,
  even with values still buffered (as Ruby's `Queue#closed?`), so a producer
  sees the reader's close between sends. Write `ch.closed? and ch.empty?` for
  the old meaning, closed and drained.

## [0.19.0] - 2026-10-31

The first stable release since 0.18.0, with the changes of `0.19.0-beta.1`,
`0.19.0-beta.2` and `0.19.0-beta.3` below.

### Added

- `bytes.decode(encoding)` and `text.encode(encoding)` read and write UTF-8,
  UTF-16, UTF-32 (LE, BE, or with a byte order mark), ASCII, Latin-1,
  ISO-8859-15 and Windows-1252.
- Hex, binary and octal integer literals, as in Ruby: `0xFF`, `0b1010`,
  `0o755`, with `_` between digits.
- `HTTP.start`, `HTTP.send_request`, `HTTP.read_body` and `HTTP.finish` give
  one HTTP/1.1 connection that the program drives: read the response head,
  then the body piece by piece, and send a second request on the same socket
  once the body has been read to its end (after Ruby's `Net::HTTP`).
- `HTTP.get_response(url)` and `HTTP.post_response(url, body)` make one
  request with no client to open or close, as Ruby's `Net::HTTP.get_response`
  does. Many requests still use `HTTP.client()` with `get` and `post`.
- `HTTP.open` gives a response body on a channel (`HTTP.Stream`: `status`,
  `headers`, `body` and a `done` task) for a download too big to hold or that
  never ends, and `HTTP.upload` sends a body that another task feeds through a
  channel, chunked or with an exact `length`.

### Changed

- `HTTP.text` decodes the `charset` of `Content-Type` with `bytes.decode`: a
  Latin-1, Windows-1252 or UTF-16 body that was an error now decodes, and a
  `us-ascii` body with a non-ASCII byte is now an error.

## [0.19.0-beta.3] - 2026-10-31

### Added

- `HTTP.StreamResponse` takes `length: some(n)`: a streamed body of known
  size goes out with `Content-Length` and no chunk framing, and a body that
  ends short or runs over closes the connection.
- Every field of `HttpClientOptions` and `HttpServerOptions` has a default,
  so `HttpClientOptions(timeout_ms: 5000)` changes one field.
- `HTTP.client`, `HTTP.listen` (and its TLS and stream forms), `HTTP.download`
  and `Archive.extract_tar` / `extract_zip` take their options last with a
  default, so `HTTP.client()` and `HTTP.listen(host, port, &handle)` work.
- `JSON.encode` and `JSON.from` work on a value of a type parameter inside a
  generic function; each call checks that the type it binds is encodable
  (`CHECK-NOT-ENCODABLE` at that argument).

### Changed

- `"text".bytes` on a string literal without interpolation is a constant made
  once when the program loads, not a copy on each evaluation.

### Removed

- **Breaking:** `HTTP.client_options()`, `HTTP.server_options()`,
  `HTTP.download_options()` and `Archive.options()`: leave the argument out, or
  build the record (`HttpClientOptions(timeout_ms: 5000)`,
  `HttpServerOptions()`, `HTTP.DownloadOptions()`, `Archive.Options()`).

### Fixed

- A native callback may print more than the output buffer holds; it waits for
  the writer instead of failing with `RUNTIME-NATIVE-CALLBACK`.

## [0.19.0-beta.2] - 2026-10-31

### Added

- `callback Name(params) -> result` in an extern block and
  `Native.callback(Name, &fn)`: C calls an Agentica function back (`qsort`, a
  SQLite collation); `Optional[Name]` parameters pass NULL for `none`.
- A parameter may default to a struct built with no arguments, `options:
  Options = Options()`, when every field of the struct has a default.
- `HTTP.text(body, headers)` decodes a body as UTF-8 only: the `charset` of
  `Content-Type` must be `utf-8` or absent, and any other charset is an error
  that names it.

### Changed

- A parameter whose type has a type parameter may take a default (`none`, `[]`
  or `{}`), as a field of a generic struct does.
- **Breaking:** the body of an `HttpResponse` is `Bytes`, for the client's
  responses and for the ones a `listen` handler returns (write `"text".bytes`,
  and `HTTP.text(r.body, r.headers)` to read text); `HttpResponse` is no longer
  JSON encodable. `HTTP.post` and `HTTP.request` take a `Bytes` body before
  `headers`, which is `[]` by default and no longer comes first. Rebuild `.agcb`
  files that call them.
- **Breaking:** the `body` of an `HttpRequest` in a `listen` handler is `Bytes`,
  as the client sent it (read text with `HTTP.text(request.body,
  request.headers)`); the server no longer answers 400 for a request body that
  is not UTF-8. Rebuild `.agcb` files with such a handler.

### Fixed

- Compiling deeply nested `some(...)` calls is much faster (900 levels: from
  4 s to 0.6 s).

## [0.19.0-beta.1] - 2026-10-30

### Added

- Linux ARM64 builds and CI, with native calls; the JIT stays x86-64 only.
- A `linux-arm64` release archive (glibc 2.28), which runs on the interpreter:
  no JIT on ARM64 yet.
- `HTTP.listen_stream` and `HTTP.listen_stream_tls`: a handler returns an
  `HTTP.StreamResponse` whose body is a `Channel[Bytes]`, sent as chunks as they
  arrive, for Server-Sent Events, tokens or files; `HTTP.whole(data)` is the
  channel of a route with one whole body.

## [0.18.0] - 2026-10-30

### Added

- `agentica check [PATH...]` checks several files and folders and prints a
  count; `--json` gives one entry per file.
- `TLS.connect` takes an optional client certificate and key for mTLS.
- `Cipher.des_ede3_cbc_encrypt` and `_decrypt`, and `CMAC.aes` and
  `CMAC.des_ede3`.
- `Cipher.aes_256_gcm_encrypt` and `_decrypt`.
- `KDF.pbkdf2_hmac_sha256` and `KDF.scrypt`.
- `Optional[T]` for a value that may be missing: `some(x)`, `none`, `case`
  arms, `==`, and the methods `unwrap_or`, `unwrap!`, `map`, `some?`, `none?`
  and `to_result`.
- JSON encodes and decodes `Optional[T]`, and `none` may be a field or
  parameter default.

### Changed

- **Breaking:** rebuild `.agcb` files compiled by 0.17.x that call
  `TLS.connect`.
- **Breaking:** `Cipher`, `CMAC` and `KDF` are reserved type names.
- **Breaking:** `File.stat` and `File.lstat` give `kind` `"fifo"`, `"socket"`,
  `"characterSpecial"`, `"blockSpecial"` or `"unknown"` instead of `"file"`
  for special files.
- **Breaking:** `Optional`, `some` and `none` are reserved names; rebuild
  `.agcb` files compiled by 0.17.x that declare their own `enum Optional`.
- **Breaking:** `map.get(key)` and `text.index_of(part)` give an `Optional`
  instead of a `Result` (use `.to_result("message")` for `try`); rebuild
  `.agcb` files compiled by 0.17.x that call them.

## [0.17.0] - 2026-10-30

### Added

- `Bytes`, a compact immutable byte string: `s.bytes`, `Bytes.from_list`,
  `b.to_a`, `b[i]`, `slice`, `take`, `drop`, `+`, `Bytes.concat`, `==`, and use
  as a `Map` key or `Set` item.

### Changed

- **Breaking:** `Bytes` is a reserved type name. A struct, enum, type alias or
  import alias called `Bytes` is `CHECK-REDEFINED-NAME`.
- **Breaking:** `Digest`, `HMAC`, `Base64` and `SecureRandom.random_bytes` take
  and return `Bytes` instead of `List[Int]`.
- **Breaking:** `IO.read_bytes`, `File.read_bytes`, `File.write_bytes`,
  `File.sha256` and `String.from_bytes` use `Bytes`; `String.to_bytes` is now
  `s.bytes`.
- **Breaking:** `Zlib`, `File.chunks` and the Lazy byte steps (`gzip`,
  `gunzip`, `deflate`, `inflate`, `write_bytes`) use `Bytes`.
- **Breaking:** `TCP.recv_bytes`, `TCP.send_bytes`, `Process.read_bytes` and
  `Process.send_bytes` use `Bytes`.
- **Breaking:** `std/binary` reads from and writes `Bytes`; `Binary.concat` is
  replaced by `Bytes.concat`.
- **Breaking:** `C.Bytes` parameters take `Bytes`; `Native.get_bytes` returns
  and `Native.put_bytes` takes `Bytes`.
- **Breaking:** rebuild `.agcb` files compiled by 0.16.x: the byte builtin keys
  they import are gone.

### Fixed

- The JIT no longer overwrites the first argument register of a function value
  call with its result, which made a hand-made `.agcb` fail where the
  interpreter ran it.

## [0.16.0] - 2026-10-29

### Added

- `std/uri` encodes and decodes URL components and query strings.
- `std/html` escapes and unescapes HTML text.
- `std/cookie` reads a `Cookie` header and writes a `Set-Cookie` header.
- `std/mime` gives the media type of a file by its extension.
- `HMAC.secure_compare(a, b)` compares two byte lists in constant time.
- `Archive.Options()` and `HTTP.DownloadOptions()` give the default options.

### Changed

- `HTTP.request` and `HTTP.post` default `headers` to `[]` and `body` to `""`.
- `timeout_ms` defaults to 30000 on every `File`, `Dir` and `Path` call that
  takes one, and on `Process.spawn`, `spawn_captured` and `spawn_channel`.
- `File.open` defaults `mode` to `"read"`, `File.each_line` and `File.foreach`
  default `buffer_bytes` to 65536, and `spawn_captured` and `spawn_channel`
  default `dir` to `"."`.

## [0.15.0] - 2026-10-29

### Added

- `Base64` encodes and decodes bytes: `encode64`, `strict_encode64`,
  `urlsafe_encode64` and their decoders.
- `Digest.hexencode` and `hexdecode` turn bytes into hex text and back.
- `Digest.md5`, `sha1`, `sha256` and `sha512`, each with a `_hexdigest` form.
- `HMAC.sha256` and `HMAC.sha512`, each with a `_hexdigest` form.
- `SecureRandom.random_bytes`, `hex` and `uuid` draw secure random bytes for
  keys and tokens.
- `JSON.codec(User)` gives a `JSON.Codec[User]` with `decode`, `encode` and
  `from`, so generic code can read and write JSON of its type parameter.

### Changed

- **Breaking:** `Base64`, `Digest`, `HMAC` and `SecureRandom` are reserved
  names.
- **Breaking:** `Crypto.sha256` is now `Digest.sha256`; rebuild old `.agcb`
  files.
- `--jit on` is the default on x86-64; `--jit off` or `AGENTICA_JIT=off` turns
  the JIT off.
- `--jit on` keeps short loops that wait on channels, tasks, processes,
  sockets, stdin or files interpreted, and starts faster.

## [0.14.0] - 2026-10-28

### Added

- Generic structs: `struct Box[T]`, with the type argument inferred.
- Generic functions: `def first_or[T](xs: List[T], fallback: T) -> T`.
- `Analysis.entry` and `Analysis.adopt` share a file's analysis cache between
  tasks.
- `JsonField` can be a type argument of a generic struct for `JSON.encode` and
  `JSON.from`.

### Changed

- The experimental x86-64 JIT runs function values, tail calls, repeated block
  calls and small builtins inside compiled code.

### Fixed

- `JSON.encode` and `JSON.from` refuse a `JsonField[Nil]` behind a recursive
  generic field.
- Checking `JSON.encode`, `puts` or `to_s` of structs that refer to one another
  is no longer exponential.

## [0.13.0] - 2026-10-27

### Added

- `ATS[K, V]` shared tables that tasks update together, for counters and
  caches.
- `Type.members` lists the fields of a struct type as `List[StructMember]`.
- `JsonField[T]` fields tell an absent key, `null` and a value apart in JSON.
- `JSON.decode(json, T)` decodes a `Json` value directly.

### Changed

- **Breaking:** `ATS`, `StructMember` and `JsonField` are reserved names.
- **Breaking:** `JSON.schema` leaves out `required` when no field is required.
- The experimental x86-64 JIT compiles tail calls and struct updates.
- `--jit on` has a per-run compile budget; past it, code is interpreted.

### Fixed

- Windows: the check and bytecode caches retry removing a temporary file.

## [0.12.0] - 2026-10-27

### Added

- `resource Name, free_ref: c_function` for a resource freed by `void f(T **)`,
  such as `duckdb_close`.
- `Native.from_string(text)` and `text.bytesize` pass text with its byte length
  to C, and keep pointers into it.
- `Native.load("NAME")` opens a native library and returns a `Result`;
  `Native.closed?(x)` tells a closed resource or a freed buffer.
- `Native.offset(p, n)` and `Native.address(p)` point into an owned buffer and
  give a pointer's integer value.
- `Native.size_of`, `Native.get_struct` and `Native.put_struct` read and write
  a C struct of an extern block.
- Extern types `C.Int8`, `C.Int16`, `C.UInt8`, `C.UInt16`, `C.UInt32` and
  `C.Long`.
- `[native]` entries of `agentica.toml` may give `system` as an absolute path
  or a list of candidates.
- Float literals take an exponent: `1.0e300`, `1.5e-3`, `1e5`.
- Builtins can have default arguments, and `agentica help` shows them.
- `File.chunks(path)` reads a file as a `Lazy` of byte chunks, and
  `lazy.write_bytes(path)` writes them to a file.
- Lazy zlib steps `deflate`, `inflate`, `gzip` and `gunzip` work on byte
  chunks with bounded memory.
- `Zlib.deflate`, `inflate`, `gzip` and `gunzip` take default `level` (6) and
  `max_bytes` (1048576).

### Changed

- **Breaking:** the Zlib streaming encoder and decoder (`deflate_init`,
  `inflate_init` and the rest) and the types `ZlibEncoder`, `ZlibDecoder` and
  `ZlibProgress` are removed: use the Lazy steps.
- **Breaking:** `Zlib.deflate_file`, `inflate_file`, `gzip_file` and
  `gunzip_file` are removed: use `File.chunks(src).gzip.write_bytes(dst)`,
  which overwrites an existing `dst`.
- **Breaking:** the Zlib errors name `max_bytes` instead of `max_out_bytes`.
- An integer argument or struct field of an extern function takes the bits of
  its type, signed or unsigned: a `C.Int32` takes up to 2^32 - 1.
- The experimental x86-64 JIT (`--jit on`) runs more code compiled: native
  calls, small functions, String, List, Map and Set builtins, map reads, list
  literals, blocks with `map`, `filter` and `reduce`, module constants,
  structs, enum values and `try`.
- `--jit on` starts faster on large programs, uses less memory, and no longer
  slows down a program that compiles nothing hot.
- A warm `agentica check` and `agentica type-at` do less work (2.3 times faster
  on `compiler/`).
- The end of the run frees the native resources and buffers still open, so a C
  stream that `main` never closed keeps what was written to it; a running
  compute call that holds a resource delays the exit, at most the flush limit.

### Fixed

- `agentica doc`, `outline`, `type-at` and `refs` handle the re-exports of a
  facade file (`Web.Address`).
- A block of unknown result type (`map`, `Native.memory_pointer`, `Task.map`)
  that returns `error(...)` before its `ok(...)` no longer needs an annotation.

## [0.11.0] - 2026-10-26

### Added

- `export Alias.name` re-exports an imported name, so one facade module can
  hold the API of a package of several files.
- `[style] blank_line_after_end = true` in `agentica.toml` requires an empty
  line after a bare `end` (`CHECK-BLANK-LINE-AFTER-END`).
- `Task.spawn(&f)` and `Task.spawn do ... end` take a function or block with
  no argument.
- `agentica test --tags EXPR` keeps the scenarios whose tags match.
- `BDD.keep` and `BDD.call` keep a non-JSON value, such as an open
  connection, between the steps of a scenario; `BDD.read_line` gives a step
  the program's next output line.
- **Breaking:** `BDD.skip(ctx, reason)` ends a scenario as skipped; the text
  summary has `S skipped`, and `--json` has `skipped`, `reason` and the status
  `"skipped"`.

### Changed

- **Breaking:** `agentica test` without `--steps` uses the nearest
  `steps.agc` of each path that holds a feature; two different ones are a
  usage error.
- `Task.spawn_owning` takes a struct, enum, List, Map or Result that holds
  handles and hands them all over, or none.
- `check` and `type-at` keep checked imports in `_build/check/`, so a warm run
  is about 5 times faster; `--no-cache` turns it off.
- `Map.delete` and `Set.delete` are much faster on large maps, and
  `put`/`add` are about 2.5 times faster.
- A timed channel `send` or `recv` answered within a turn no longer reads the
  clock.

### Fixed

- Bytes written to a file are no longer lost at exit when its `File.close`
  or `File.write` times out.
- `agentica test` reports a failed step at its keyword's column, and names
  each `Scenario Outline` row `Name (values)`.
- `Given the Agentica program` no longer stops a program after 1,000,000
  steps.
- `resource Name, free: PQfinish` accepts a C free function that starts with
  a capital letter.
- Linux shutdown skips a standard C stream already locked by native compute
  code.
- `String#to_f` reads exponents and `+inf.0`, `-inf.0`, `+nan.0`.

## [0.10.0] - 2026-10-25

### Added

- Packages can download pinned native libraries from TAR or ZIP archives;
  `std/archive` safely extracts allowlisted TAR, gzip TAR and ZIP files.
- Experimental, opt-in `--jit on` / `AGENTICA_JIT=on` compiles supported hot
  loops to x86-64 machine code; compiled calls and returns transition through
  the interpreter. ARM remains interpreter-only.
- `HTTP.download` streams response bodies to files, with a 256 MiB limit.
- Module aliases read exported constants, and enum variants support bare
  method and field access.
- Struct fields can have defaults.
- Packages can declare native libraries for `extern` blocks
  (`PKG-NATIVE-PLATFORM`, `PKG-NATIVE-MISSING`).
- `extern` supports variadic functions, `C.Float`, `C.Function`, C structs by
  value, owned buffers and typed memory operations.
- `File.sha256` hashes regular files in fixed-size chunks; `Zlib` adds DEFLATE,
  gzip and CRC32 support for bytes, files and streams.
- Added FFI and DuckDB examples.

### Changed

- **Breaking:** `Native.string_at` and `Native.bytes_at` are replaced by
  `Native.get_string` and `Native.get_bytes`, which take an offset.
- `extern` blocks declaring a resource or struct are placed with their types
  and definitions.
- **Breaking:** top-level package `native/` files affect package hashes, as
  does `agentica.toml` when it declares native libraries or `native/` has
  non-`.agc` files; update affected locks with `agentica update`.
- Linux uses system zlib by default; `AGENTICA_ZLIB=vendored` selects the
  pinned static library.

### Fixed

- `Archive.extract_tar` correctly accepts destinations containing host
  backslashes, including Windows cache roots.

## [0.10.0-beta.1] - 2026-10-24

### Changed

- `Analysis.refresh` no longer checks again the modules that did not change,
  so an editor waits only for the edited file and the modules that import it.
- Loops and function calls run faster: the VM joins each step check, and each
  constant before an integer operator or compare, with the instruction after it
  (integer loops take about half the time they did in 0.9.0).

### Fixed

- A program with one busy task no longer runs about twice as slow with the
  default scheduler count: its own scheduler keeps it, and the idle ones stay
  asleep.

## [0.9.0] - 2026-10-23

The first stable release since 0.8.1, with the changes of `0.9.0-beta.1` and
`0.9.0-beta.2` below. Windows and macOS now run every feature that Linux runs.

### Added

- Windows: `Native.wait_readable` and `Native.wait_writable` wait on a native
  library's socket; any other value is an error.
- The `AGENTICA_VM_TRACE=profile` report ends with what the VM ran: an `op` row
  for each opcode with its share, the 20 most common opcode pairs, and an
  `events` line (frame reloads and the paths of builtin calls).

### Changed

- **Breaking:** the extern type `C.Int` is now `C.Int32`, so both widths are
  explicit (`C.Int32`, `C.Int64`); `C.Int` is `PARSE-EXTERN-TYPE`.

### Fixed

- On Windows a program no longer hangs at its end while a `compute def` call
  still runs and holds the lock of a C stream other than stdout or stderr.
- On Windows, `File.open(path, "create_private")` no longer follows a dangling
  link.

## [0.9.0-beta.2] - 2026-10-22

### Added

- `extern` blocks and `Native.wait_*` work on macOS (x86_64 and arm64).
- `Native.string_at`, `Native.bytes_at` and `Native.pointer` read memory that C
  returns and make sentinel pointers.

### Fixed

- Windows: `install`, `add` and `update` no longer leave temporary git folders
  in the package cache.
- Windows: a program with several schedulers no longer hangs, now and then, in
  a garbage collection.

## [0.9.0-beta.1] - 2026-10-22

Not published: the release smoke test failed, so `0.9.0-beta.2` is the first
release with these changes.

### Added

- `extern` blocks call C functions of native libraries on Linux x86_64 and
  Windows x64; `--deny-native` refuses such a program.
- Native types `C.Int`, `C.Int64`, `C.Double`, `C.Bool`, `C.String`,
  `C.Pointer`, `C.Bytes`, and `resource Name, free: fn` freed once.
- `out` parameters of extern functions return a record with `result` and one
  field per out value.
- `compute def` runs a long native call on the compute pool while other tasks
  run.
- `Native.wait_readable` and `Native.wait_writable` park a task on a native
  descriptor (Linux only for now).
- `length` and `size` work on `Map`, `Set` and `Range`.
- Ruby synonyms `collect`, `select`, `inject`, `detect`, `member?` and `key?`.
- `List.first`, `List.last`, and `empty?` on `List`, `Map` and `String`.
- `--deny-run` (which also denies native calls), `--deny-net`, `--deny-fs`,
  `--deny-env` and `--sandbox`, also for `agentica test`.
- `agentica install` fetches the packages of `agentica.lock` into `deps/`;
  `add` and `update` edit `agentica.toml` and the lock. **Breaking:** scripts
  named `install`, `add` or `update` run as `agentica ./NAME`.
- Builds read packages only from `deps/<name>/`; `agc_libs/` stays for local
  libraries.
- Git dependencies take `subdir` (`agentica add ... --subdir DIR`), so one
  repository can hold several packages.
- Workspaces: a `[workspace]` table lets members of one repository use each
  other's folders directly.
- Compiled programs are cached in `_build/bytecode/` (`AGENTICA_BUILD_DIR`
  moves it); `--no-cache` turns it off.
- `agentica help NAME` maps Ruby, Python and JS names to the builtin, and
  unknown methods suggest the Ruby one.

### Changed

- `help` and diagnostics show the Ruby form of a builtin (`s.strip`); both
  names still work.
- Windows: `agentica.exe` is long-path aware, so paths of 260 characters or
  more work when `LongPathsEnabled` is set.

### Removed

- **Breaking:** `--allow-run` is gone: programs may start processes by
  default.

### Fixed

- On Windows, open TCP and TLS sockets are closed, not reset, at the end of a
  run.
- Windows: non-ASCII text typed on a console reaches standard input as UTF-8.

## [0.8.1] - 2026-10-22

### Added

- `agentica type-at` (and `std/analysis`) answers a type name in an annotation,
  a type argument, a field or a payload (`kind` `type`), with the struct, enum
  or alias as definition.
- `std/analysis` has `type_at_partial` and `refs_partial`, as `type-at` and
  `refs` with `--partial`.

## [0.8.0] - 2026-10-21

### Added

- `agentica symbol NAME [PATH...]` finds where a name is defined, with its
  signature, `##` doc and span.
- `agentica refs NAME|FILE:LINE:COL [PATH...]` lists every reference to a name
  or to the name at a position.
- `agentica type-at` gives the `doc` and `signature` of a definition, answers a
  builtin with its `help`, and answers a local (parameter, binding, `for`
  variable, `case` pattern name).
- `type-at` and `refs` take `--partial`: a program in which some functions do
  not check is still answered.
- `Std.source(path)` gives the text of a `std/` source that the binary carries.
- `std/analysis` answers `check`, `outline`, `type-at`, `symbol` and `refs` from
  a program, over a session with unsaved buffers.
- `Analysis.refresh(session, path)` keeps the checked program in the session,
  so the next questions skip parsing and checking when nothing changed.

### Changed

- `std/internal/` can be imported only from `std/` modules
  (`CHECK-IMPORT-IO`).
- `agentica check` no longer requires `main`, so a library file checks clean;
  `run` and `compile` still report a missing `main`.
- **Breaking:** `Std` is a reserved type name.

## [0.7.0] - 2026-10-21

### Added

- `agentica doc PATH [--json]` prints the exported API of a file or a `std/`
  module with its `##` docs.
- `agentica outline FILE [--json] [--stdin FILE]` lists the declarations of a
  file, private ones too, with their signatures, docs and spans.
- `agentica type-at FILE:LINE:COL [--json]` gives the type and the definition at
  a position of a checked file; `type-at --stdin FILE:LINE:COL` reads the file
  from standard input.

### Changed

- **Breaking:** programs run on one scheduler per logical core by default, so
  tasks run in parallel and their order is not fixed; use `--schedulers 1` (or
  `AGENTICA_SCHEDULERS=1`) for the old order. `--max-steps` can trip a little
  late with more than one scheduler. `agentica test` refuses `--schedulers`;
  the VMs it starts read `AGENTICA_SCHEDULERS`.
- `HTTP.wait` returns only after the server's handlers and the tasks they
  spawned have ended; it used to return as soon as the server was closed.

### Fixed

- `agentica check --stdin --json` is a usage error (exit 2); it used to take
  `--json` as the file name.
- A child's stderr no longer stalls the VM when the VM's stderr is not read,
  and it keeps its order with stdout when both go to one pipe (`2>&1`).
- A Unix socket as standard output no longer holds the end of the run when its
  reader reads only after the exit and the output fills more than a quarter of
  its buffer.

## [0.6.0] - 2026-10-21

### Added

- `agentica check --stdin FILE` checks standard input as if `FILE` held it.
- `JSON.kind(value)` gives the kind of a JSON value as a String.
- `agentica help --json` with no NAME prints every builtin as a JSON array.

### Changed

- **Breaking:** extra words after `agentica check FILE` are a usage error
  (exit 2); they used to be ignored.
- `agentica --json help` prints the JSON array, not the text summary.

## [0.5.0] - 2026-10-21

### Added

- Packages: git dependencies in `agentica.toml`, pinned by `agentica.lock`, and
  imports as `pkg/<name>/<module>` from a cache filled by hand (no fetching
  yet). New codes `PKG-*` and `CHECK-IMPORT-PACKAGE`.
- `String.to_bytes(s)`, the UTF-8 bytes of a String.
- `Crypto.sha256(data)`, the SHA-256 digest of a list of bytes.
- Generic type aliases: `type Matrix[T] = List[List[T]]`.
- `Lazy[T]` pipelines over lists, ranges, `Lazy.produce`, file lines
  (`File.foreach`) and channels (`ch.lazy`), with `try` in every step block
  and `lz.write_lines(path, timeout_ms)`.
- `Task.cancel(task)` cancels a task and its descendants.
- A line that starts with `.name` continues the line before it.
- `Profile.measure`, `Profile.steps()` and folded flame graph stacks.
- TLS sockets and `std/http` on Windows; Windows trust reads the CA store for
  intermediates.
- One CI conformance matrix on Linux, Windows and macOS (Intel and ARM).

### Changed

- **Breaking:** with an `agentica.toml` in the folder of the root file or above
  it (up to the file system root), `pkg/` searches `agc_libs/` beside that
  manifest, and the manifest must be valid (`PKG-MANIFEST-INVALID`).
- **Breaking:** `Lazy`, `Profile` and `Crypto` are reserved type names.
- The lingering close of `std/http` drops at most 256 KiB of input.

### Fixed

- A cancelled `TCP.accept` or socket read gives up its place at once, and a
  task spawned by a cancelled task starts cancelled.
- A type alias sees only its own parameters.
- Windows: `pkg/` roots follow the documented rules.
- Windows: a standard input read no longer holds a pool thread.
- Windows: a socket as standard output or error keeps its unread output at
  exit.

## [0.5.0-beta.1] - 2026-10-20

### Added

- Native release archives for Linux x86-64, Windows x86-64, macOS Intel and
  macOS Apple silicon, with `SHA256SUMS`.
- `TCP` on Windows and macOS, and `agentica test` on Windows.
- `System.os()`.
- `--schedulers N` (`AGENTICA_SCHEDULERS`): the first step of the multicore VM,
  which still runs one scheduler outside a test switch.
- Windows test tooling: `make tests KIND=...`, Docker and Wine checks, and
  native console and Ctrl+Break checks in CI.

### Changed

- **Breaking:** `_` is a discard wherever a name is bound; reading `_` is
  `CHECK-UNKNOWN-NAME`.
- **Breaking:** on Windows, `Process.spawn_channel` gives the child one pipe per
  direction (`AGENTICA_CHANNEL=3,4`).
- TLS system trust uses the macOS and Windows stores, read once per process on
  every system.
- The HTTP client is written in `std/http` over `TCP` and `TLS`, and shares one
  TLS context per client.
- HTTPS servers time the TLS handshake as part of the wait for a request.
- Windows: `Path.remove`, `Path.rename`, `File.try_lock` and non-blocking
  standard input and output.
- A deadline and a result in the same loop pass resolve in the order the loop
  saw them.

### Fixed

- Windows runs `.com` programs and refuses ambiguous executable names.
- A socket as standard output no longer stalls tasks on macOS.
- Early UTF-8 errors in HTTP request bodies, closing of a cancelled
  `TCP.accept`, and Windows file errors, locks and `Process.close`.

## [0.4.1-beta.1] - 2026-10-17

### Added

- Native Windows files, imports, environment, driver and compiler bootstrap.
- Native compiler bootstrap and copied-binary checks on Windows and macOS.

- Type aliases, default parameter values, heredocs, case guards and nested
  patterns.
- Enumerable methods for lists and maps, plus `String.compare`.
- `Task.map` with bounded concurrency and per-item timeouts.
- VM profiling and a security reporting policy.

### Changed

- Faster compilation, program startup and test execution, with fewer
  allocations.
- Simplified compiler internals and shared VM operations for a future JIT.
- CI runs on GitHub-hosted Linux, macOS and Windows runners.
- Updated documentation and contributor guidelines.

### Fixed

- Windows and macOS VM builds and Linux CI toolchain compatibility.
- macOS FIFO completion after a reader closes.
- Native Windows file I/O, environment access and Unicode path handling.
- BDD runner selection in bootstrap and replacement front ends.

### Removed

- **Breaking:** logger `_meta` functions; use the level functions with optional
  fields instead.
- The legacy Racket compiler and its development tools.

## [0.4.0] - 2026-10-16

### Added

- One Linux binary with the compiler, VM and standard library included.
- CLI and test driver written in Agentica, plus `agentica run` for bytecode.
- Bootstrap builds without Racket and checks that the compiler reproduces
  itself.

### Changed

- **Breaking:** `agentica-vm` is replaced by `agentica run`; `AGENTICA_VM` is
  removed.
- **Breaking:** use `make` to build the single binary; the old build targets and
  separate executables are removed.

## [0.3.0] - 2026-10-15

### Added

- Module constants, named imports, immutable sets and struct updates.
- TOML, binary data and structured logging libraries.
- Task await timeouts and channel ownership.
- Private files and directories, file locks, safe removal and atomic renames.
- Environment and canonical path access, bit operations and nanosecond timing.
- Runtime and test stack traces, with better diagnostic suggestions.

### Changed

- Faster list operations; numeric lists use half the memory.
- More file metadata and portable source paths in bytecode.
- **Breaking:** imports use `import Alias from "path"`; source files must
  contain valid UTF-8.
- **Breaking:** declarations follow a fixed order; parser and checker nesting is
  limited to 1,000 levels.
- **Breaking:** bytecode formats 4 and 5 require recompiling older programs; new
  builtin type names are reserved and structs cannot have a function field named
  `with`.
- **Breaking:** the test driver runs in Agentica, with changes to infrastructure
  errors and temporary-directory cleanup.
- **Breaking:** child processes no longer inherit VM metrics variables.

### Fixed

- Generic enum type-checker crashes and misleading test-runner error reports.

## [0.2.0] - 2026-10-14

### Added

- Ruby-style operators, string interpolation, methods, closures, ranges and
  pipes.
- Loop controls, digit separators and documentation comments.
- Channels, task supervision, resource ownership and private child-process
  communication.
- Unit tests and BDD written in Agentica.
- TCP, TLS and HTTP support on the VM, plus streaming file reads.
- Bytecode compilation, tail calls, execution tracing and improved CLI help.
- Expanded standard library, documentation site and portable Linux releases.

### Changed

- **Breaking:** the C VM replaces the Racket evaluator; seeded random sequences
  change, and asynchronous I/O requires Linux.
- **Breaking:** HTTP and BDD move to standard-library modules with revised APIs.
- **Breaking:** task crashes are isolated; resources close when their owning
  task ends, and tests use a private communication channel.
- **Breaking:** imports omit `.agc`; declarations need blank lines, `##` denotes
  documentation and new builtin names are reserved.
- **Breaking:** string interpolation, splitting and value formatting change;
  missing or empty CA files are errors, and bare process commands use only
  `PATH`.
- Default builds use system OpenSSL and libgc; releases bundle them.
- Adopted Apache-2.0 with the LLVM exception.

### Fixed

- VM shutdown hangs and blocking file, output and process operations.
- Imported type names in output and diagnostics.

## [0.1.0] - 2026-10-04

First release of Agentica, a statically typed language designed for AI agents.

### Added

- Racket interpreter with a CLI for running, checking and inspecting programs.
- Typed collections, structs, functions, modules, JSON and Result error
  handling.
- Stable diagnostics, machine-readable output and execution budgets.
- Tasks, networking, processes, file operations and BDD testing.
- Examples, agent skills and automated releases.

### Changed

- Improved operator diagnostics and internal error reporting.
- `main` returns `Void`; maps preserve insertion order and support fallible
  lookups.

[unreleased]: https://github.com/agentica-lang/agentica/compare/0.19.0...HEAD
[0.19.0]: https://github.com/agentica-lang/agentica/compare/0.19.0-beta.3...0.19.0
[0.19.0-beta.3]: https://github.com/agentica-lang/agentica/compare/0.19.0-beta.2...0.19.0-beta.3
[0.19.0-beta.2]: https://github.com/agentica-lang/agentica/compare/0.19.0-beta.1...0.19.0-beta.2
[0.19.0-beta.1]: https://github.com/agentica-lang/agentica/compare/0.18.0...0.19.0-beta.1
[0.18.0]: https://github.com/agentica-lang/agentica/compare/0.17.0...0.18.0
[0.17.0]: https://github.com/agentica-lang/agentica/compare/0.16.0...0.17.0
[0.16.0]: https://github.com/agentica-lang/agentica/compare/0.15.0...0.16.0
[0.15.0]: https://github.com/agentica-lang/agentica/compare/0.14.0...0.15.0
[0.14.0]: https://github.com/agentica-lang/agentica/compare/0.13.0...0.14.0
[0.13.0]: https://github.com/agentica-lang/agentica/compare/0.12.0...0.13.0
[0.12.0]: https://github.com/agentica-lang/agentica/compare/0.11.0...0.12.0
[0.11.0]: https://github.com/agentica-lang/agentica/compare/0.10.0...0.11.0
[0.10.0]: https://github.com/agentica-lang/agentica/compare/0.10.0-beta.1...0.10.0
[0.10.0-beta.1]: https://github.com/agentica-lang/agentica/compare/0.9.0...0.10.0-beta.1
[0.9.0]: https://github.com/agentica-lang/agentica/compare/0.9.0-beta.2...0.9.0
[0.9.0-beta.2]: https://github.com/agentica-lang/agentica/compare/0.9.0-beta.1...0.9.0-beta.2
[0.9.0-beta.1]: https://github.com/agentica-lang/agentica/compare/0.8.1...0.9.0-beta.1
[0.8.1]: https://github.com/agentica-lang/agentica/compare/0.8.0...0.8.1
[0.8.0]: https://github.com/agentica-lang/agentica/compare/0.7.0...0.8.0
[0.7.0]: https://github.com/agentica-lang/agentica/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/agentica-lang/agentica/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/agentica-lang/agentica/compare/0.5.0-beta.1...0.5.0
[0.5.0-beta.1]:
https://github.com/agentica-lang/agentica/compare/0.4.1-beta.1...0.5.0-beta.1
[0.4.1-beta.1]:
https://github.com/agentica-lang/agentica/compare/0.4.0...0.4.1-beta.1
[0.4.0]: https://github.com/agentica-lang/agentica/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/agentica-lang/agentica/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/agentica-lang/agentica/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/agentica-lang/agentica/releases/tag/0.1.0
