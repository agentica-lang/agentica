### TCP, TLS and HTTP

Networking uses the normal expression syntax and lightweight tasks. The network
names in §4 are reserved, and handles are opaque: they belong to their run and
close when it ends. No CLI flag is needed; `--deny-net` turns them off
([`06b-builtins.md`](06b-builtins.md)). Signatures and details are in
[`library/io-and-system/network.md`][agentica-link-1];
the protocol is in [`docs/vm/10-io-http.md`](../vm/10-io-http.md) and
[`docs/vm/10-io-tls.md`](../vm/10-io-tls.md).

- Ports are 1 to 65535 to connect and 0 to 65535 to listen; port 0 asks for an
  assigned port, which `TCP.local_port` returns. A host with NUL is an error.
- TLS checks certificates and host names, with TLS 1.2 or later; verification
  cannot be turned off. An empty CA file means system trust; a nonempty one
  replaces it, and a missing or empty file fails the connect. A peer that closes
  without TLS's close message ends the stream like EOF, so the protocol must
  detect a cut message.
- Timeouts are positive milliseconds and cover the whole operation, lock waits
  included. A timeout during active I/O closes that socket, and later calls fail
  with `network: socket is closed`. A timeout while only waiting for a lock
  keeps it open.
- `send` takes UTF-8 text and flushes; `send_bytes` takes values 0 to 255, at
  most 1 MiB per call. `recv_bytes` takes 1 to 1048576 and gives `ok([])` at
  EOF. `read_line` is an error on an empty EOF, on a reset in the middle of a
  line, and on a line over 1 MiB, which also closes the socket.
- Header values use the Latin-1 byte range. CR, LF, control characters and
  framing headers set by the program are rejected.

#### HTTP client and server (`std/http`)

HTTP is the `std/http` library, imported with `import HTTP from "std/http"`; any
alias works. It calls the internal module `HttpWire`, which no other module can
name (`CHECK-UNKNOWN-NAME`). A complete program is in
[`examples/http_server.agc`](../../examples/http_server.agc).

A client call is whole: it returns after the whole body, which must be valid
UTF-8. One `timeout_ms` covers the whole call. Calls wait in FIFO order for one
of the `max_connections` slots (at most 65536). `max_body_bytes` is at most 64
MiB. A call in flight when `close_client` runs fails with `http: client is
closed`; its request is not sent, unless a connection had already started
sending it.

A `GET`, `HEAD`, `OPTIONS`, `PUT` or `DELETE` sent on a reused connection that
the server had already closed is retried once on a new connection, within the
same timeout, if no response byte arrived. `POST`, `PATCH` and other methods are
never retried.

URLs are `http://` or `https://`. A request that sets `Host`, `Content-Length`,
`Transfer-Encoding` or `Connection` itself is an error. Status codes 4xx and 5xx
are normal responses. Protocol errors start with `http: `; connection errors
keep their TCP or TLS text; a timeout is `network: operation timed out`.

`listen` (or `listen_tls`) serves in the background, with one task per
connection. The handler gets a whole `HttpRequest` and returns a whole
`HttpResponse`; the server adds the framing headers it needs. If the handler
returns `error(message)`, or the response cannot be sent (a status outside 200
to 599, a bad header, a handler-set `Content-Length` or `Transfer-Encoding`, or
a body on 204 or 304), the client gets a 500 with an empty body and the
connection closes. Stderr gets `http: handler error: <message>` or `http:
invalid response: <reason>`. A handler has no time limit. A runtime error in a
handler crashes its connection task, and the run reports the crash.

`server_options()` gives 30 s request and idle timeouts, 128 connections and 1
MiB bodies. `request_timeout_ms` bounds the first byte of a connection's first
request, then the rest of each request, then the response write;
`idle_timeout_ms` bounds the wait for a later request. Connections beyond
`max_connections` wait in the backlog. A request rejected before the handler
runs gets an empty answer and a close (400, 413, 417, 431, 501 or 505).
`close_server` closes the listener, ends every connection, cancels the handlers
and the tasks they spawned, and is idempotent. Return from `main` ends the run,
whatever the server is doing.

### Logging (`std/logger`)

`std/logger` is imported with `import Logger from "std/logger"`. It calls the
internal module `LogRegistry`, which no other module can name
(`CHECK-UNKNOWN-NAME`). `LogLevel` and `LogEvent` are builtin types and their
names are reserved in every program (`CHECK-REDEFINED-NAME`).

There are four levels, `LogLevel.Debug < LogLevel.Info < LogLevel.Warning <
LogLevel.Error`. Each level has one function, `Logger.debug(message, fields)`,
and the same for `info`, `warning` and `err` (the function for the last level is
`err` because `error` is reserved; the output says `error`). `fields` is a
`Map[String, String]` with the default `{}`, so `Logger.info("started")` and
`Logger.info("request done", {"path": "/items"})` are both calls.
`Logger.log(level, message, fields)` takes the level as a value.

The global level (`Logger.set_level`, `info` by default) is checked first, by
every call. Each handler has its own level and gets an event only when the event
is at or above it. `Logger.enabled?(level)` is true only if the level is at or
above the global level and some attached handler accepts it, so a costly message
goes inside `if Logger.enabled?(LogLevel.Debug)`.

A handler is a function `Fn[LogEvent, Void]` (`&Logger.stderr_json`) or a block,
attached under a name with `Logger.attach(name, level, handler)` and removed
with `Logger.detach(name)`; both return `error(...)` for a name in use or not in
use. `Logger.handlers()` lists the names in attach order. Handlers run in attach
order, synchronously, in the task that logs; an event keeps the handlers it
started with, and a handler error is the error of that task.

The first call of any `Logger` function attaches a handler named `console`
(`Logger.stderr_text`, level `info`). `Logger.detach("console")` removes it. The
handlers and the global level are held by the VM and belong to one run; this
registry is the language's only global state.

`Logger.stderr_text` and `Logger.stderr_json` write `Logger.format_text(event)`
and `Logger.format_json(event)` to stderr with one `IO.warn` call. The text form
is `TIME LEVEL MESSAGE key=value ...` with the time in UTC
(`2026-10-12T10:15:02.345Z`); a message, key or value that is empty, has `=`, a
quote, a backslash or a control character, or (for a key or value) a space, is
written as a JSON string. The JSON form is one object per line with the keys
`time`, `level` (`debug`, `info`, `warning`, `error`), `msg`, `fields` and
`task`. `Logger.time_text(ms)` formats milliseconds since the Unix epoch as that
time text.

Not planned for `std/logger`: log files and rotation, syslog, sampling,
per-module levels, `Json` field values, configuration through environment
variables, and lazy log arguments (a block given to `attach` is a handler, not a
lazy message). Not planned for tracing: a language-level trace, trace lines on
stdout, counters inside the tracer, a flag to turn stack traces off, and a stack
of the parent task at spawn time; VM tracing is a developer tool of the VM, not
a language feature.

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. A file handle
is opaque, belongs to one evaluation, and closes when it ends. The host user's
permissions apply; `--deny-fs` turns these calls off. File operations
accept regular files and symlinks to them, and also FIFOs, pipes and devices
that can wait, whose calls wait on the event loop; they reject directories, a
missing path for a read, and a path that reopens a pipe the VM made for itself.
On Windows no File call waits on a stream: they accept only regular files
(and folders where a folder is meant), and a named pipe or a device is refused
at once with an error. Streams that can wait reach the program there as
standard input, output or error, as process pipes and as sockets.
Signatures are in
[`library/io-and-system/files.md`][agentica-link-2].

- `File.open` modes: `read` (an existing path that is not a directory), `write`
  (creates or truncates), `append` (creates or appends) and `create_private` (a
  new write-only file for the host user alone; any existing entry, a dangling
  link included, is an error and a link is never followed). On Unix it
  is mode 0600, less where the umask clears bits. On Windows the file is made
  with a protected DACL that grants only the current user, and creation fails
  unless the object it opened has that owner and that DACL; there is no mode.
- `File.try_lock(handle, timeout_ms)` takes an exclusive lock on the open file
  without waiting, for any handle mode: `ok(true)` when taken (again on the same
  handle too), `ok(false)` when another handle or process holds it. The lock
  lasts until the handle is closed, its task ends or the process ends, and a
  child process never keeps it. Only a regular file can be locked: a handle on a
  pipe, a FIFO or a device (such as `/dev/null`) is an error. There is no unlock
  call (close the handle). On Unix the lock is advisory (`flock`): code that
  does not ask for a lock can still access the file. On Windows it locks the
  whole byte range with `LockFileEx`, so the OS also rejects reads and writes
  through other handles while the lock is held.
- Text is strict UTF-8. Whole-text helpers and each stream read or write are
  limited to 1 MiB. `read_bytes` takes 1 to 1048576 bytes and gives `ok([])` at
  EOF. `read_line` strips LF or CRLF and accepts a final unterminated line; it
  is an error at EOF or on invalid UTF-8.
- `File.each_line(path, buffer_bytes, timeout_ms) do |line| ... end` gives
  `Result[Void]`. It opens `path` for reading and passes the block one line at a
  time, never reading the whole file. A line is at most `buffer_bytes` bytes
  including its terminator; a longer line ends the call with `error("filesystem:
  line exceeds buffer_bytes")`. `buffer_bytes` is 1024 to 16777216, otherwise
  `RUNTIME-INVALID-COUNT` at that argument, checked before the file opens.
  `timeout_ms` applies to each read, the open and the close, not to the whole
  call, and must be positive, otherwise `error("filesystem: timeout must be
  positive milliseconds")`. LF and CRLF are removed, a final line without a
  newline is passed, and invalid UTF-8 ends the call with an error. The block
  returns `Result[Void]`: `ok()` goes on to the next line and an error stops and
  is returned by `each_line`. `try` works in the block. The file is closed on
  every return path.
- `File.sha256(path, timeout_ms)` gives `Result[List[Int]]`: the 32 bytes of
  the SHA-256 digest of the whole file, in the same order and form as
  `Crypto.sha256` returns them (compose with hex yourself). It streams the
  file in fixed 64 KiB chunks with O(chunk) memory, so unlike the whole-text
  helpers it has no 1 MiB cap. Only regular files are hashed, read from the
  first byte through a private descriptor that closes on every path;
  symlinks are followed as `File.stat` follows them, and a missing path, a
  directory, a path that reopens a pipe the VM made for itself, and (before
  any blocking read) a FIFO, pipe, socket or device give
  `error("filesystem: path does not refer to a regular file")`, the same
  error `File.read_text` gives them. `timeout_ms` covers the whole call and
  must be positive, otherwise `error("filesystem: timeout must be
  positive milliseconds")`; expiry gives `error("filesystem: operation
  timed out")`, while a hash already running on the pool runs to its end
  and its result is dropped, as with the other whole-file calls (there is no
  handle to close). A cancelled task detaches the same way, and a task that
  ends owns nothing. There is no snapshot: bytes are hashed in read order,
  so a concurrent writer changes the digest; to verify an archive, write it
  to a temporary name first, hash it, then `Path.rename` it into place.
- `Zlib` compresses and decompresses bytes, files and streams, with the
  opaque `ZlibEncoder` and `ZlibDecoder` handles and the
  `ZlibProgress(output, consumed, finished, needs_input)` record; all three
  names are reserved. `deflate`/`inflate` are the zlib wrapper (RFC 1950,
  the Ruby and Python default), `gzip`/`gunzip` are gzip (RFC 1952), and
  the streaming `deflate_init`/`inflate_init` take `window_bits` 15 (zlib),
  -15 (raw deflate, RFC 1951) or 31 (gzip). There is no auto-detect, no
  dictionary and no metadata option. Signatures are in
  [`library/text-and-data/zlib.md`][agentica-link-5].
- `Zlib.deflate(data, level, max_out_bytes)` and `Zlib.gzip(data, level,
  max_out_bytes)` give `Result[List[Int]]` with `level` 0 to 9; empty input
  is valid and gives the empty stream or member. `Zlib.inflate(data,
  max_out_bytes)` and `Zlib.gunzip(data, max_out_bytes)` give
  `Result[List[Int]]`: one stream or member only, with its checksum (zlib)
  or CRC and size (gzip) checked. Empty compressed input fails, and any
  unused or trailing bytes after the single stream or member (a second
  member or zeros alike) are an error, on purpose: unlike Python's
  `gzip.decompress`, concatenated members never decode. One-shot `data` is
  at most 1048576 bytes and `max_out_bytes` is 1 to 1048576, otherwise a
  contract error; output past the cap is an error.
- `Zlib.crc32(data, seed = 0)` gives `Result[Int]`, the CRC32 (RFC 1952) of
  `data` chained after `seed`: leave the seed out first, then pass each next
  chunk the previous result. Empty input returns `seed` unchanged. `data` is at
  most 1048576 bytes and `seed` is 0 to 4294967295, otherwise a contract error.
- `Zlib.deflate_file(src, dst, level, max_out_bytes, timeout_ms)` and
  `Zlib.gzip_file(src, dst, level, max_out_bytes, timeout_ms)` compress a
  file and give `Result[Int]`, the bytes written; `Zlib.inflate_file(src,
  dst, max_out_bytes, timeout_ms)` and `Zlib.gunzip_file(src, dst,
  max_out_bytes, timeout_ms)` decompress one stream or member the same way.
  The raw input of compression never exceeds 1073741824 bytes and the
  compressed input of decompression never exceeds 268435456 bytes, enforced
  while reading even when the source grows; `max_out_bytes` is 1 to
  1073741824, and output past it is cut while streaming so a partial file
  never grows past it and is kept on error (never removed). The source is
  read like `File.sha256` reads it (regular files only) and the destination
  opens like `create_private` (an existing path, a dangling link included,
  is an error and stays intact). `timeout_ms` covers the whole call; expiry
  or a cancel detaches like the other whole-file calls, while work already
  running runs to its end and its result is dropped. Only the file
  functions carry the filesystem effect, so `--deny-fs` turns off only
  them; the bytes and streaming calls run in any compute context.
- `Zlib.deflate_init(window_bits, level, max_total_in, max_total_out)` gives
  `Result[ZlibEncoder]` and `Zlib.inflate_init(window_bits,
  max_total_in, max_total_out)` gives `Result[ZlibDecoder]`; each total cap
  is 1 to 1073741824, enforced before the output or state could exceed it.
  A call of `Zlib.deflate_next(enc, data, max_out)` or
  `Zlib.inflate_next(dec, data, max_out)` takes at most 65536 input bytes
  with room for `max_out` 1 to 65536 output bytes and gives
  `Result[ZlibProgress]`. `consumed` may be less than `data.size`; the
  caller owns the rest and presents it again, and trailing bytes after the
  stream end stay caller-owned through `consumed` and are never silently
  dropped. `needs_input` is true only when the call took all it was given
  and left room in the output without finishing: it asks for more input
  (or a finish), never for a spin. When it is false and bytes remain
  unconsumed, the caller presents the remainder again with fresh room
  first; when nothing remains, the caller drains with empty input and
  fresh room. A 0-consumed and 0-produced call is either finished or asks
  for input; an empty drain that asks for input never becomes a spin by
  retrying the same empty input. A refused encoder quantum changes
  nothing and may run again with a smaller positive `max_out`. A decoder
  at its exact output budget still completes a trailer that produces no
  bytes, while a true overflow fails without returning extra bytes.
  `Zlib.deflate_finish(enc, max_out)` drains the end of a stream; repeat it
  until `finished` is true, and new input after finishing starts is an
  error. `Zlib.inflate_finish(dec)` gives `Result[Void]`: `ok()` only once
  a whole checked stream end arrived, else a truncation error. Empty drains
  after `finished` answer finished again; nonempty input after `finished` is
  an error. `Zlib.encoder_close(enc)` and `Zlib.decoder_close(dec)` give
  `Result[Void]` and are idempotent; feeding or finishing a closed, failed
  or finished handle is an error. Both handles move across tasks with
  `Task.spawn_owning`, and a task that ends frees what it did not close.
- `File.close` flushes and is idempotent. Timeouts are positive milliseconds and
  include the lock wait. A timeout during active I/O closes the handle; a
  timeout while waiting for the lock keeps it open.
- `File.stat` follows symlinks and gives `FileInfo(kind, size_bytes,
  modified_seconds, mode, user_id, group_id)`; `mode` is the permission bits
  with setuid, setgid and sticky (`st_mode & 07777`) as an `Int`. Windows has
  no Unix permission bits and no Unix owner ids: there `mode` carries only the
  read-only attribute (0666 for an object that is writable, 0444 when the
  attribute is set, and no `setuid`, `setgid` or sticky bit either way), and
  `user_id` and `group_id` are always 0. A 0 there is not the owner, and `mode`
  says nothing about the object's ACL or DACL. `File.lstat` gives the same
  record without following a final symlink: `kind` is `"link"` and the other
  fields describe the link itself. `Dir.list` gives immediate entry
  names, sorted. `Dir.mkdir` creates parents.
  `Dir.mkdir_private(path, timeout_ms)` creates exactly one directory for the
  host user alone and fails when the path exists or the parent is missing: mode
  0700 on Unix, less where the umask clears bits; on Windows the same
  owner-and-DACL rule as `create_private`, with no mode.
  `Path.remove(path, timeout_ms)` deletes what is at the path without following
  symlinks: a file, a symlink itself, or a directory with everything
  in it, where a link in the tree is removed as a link and its target is
  untouched. A missing path is `ok()`. A path whose last
  part is a separator, `.` or `..` (also as `dir/..`) is refused, a tree deeper
  than 128 levels is an error, and a trailing separator on a symlink is an
  error. A path under a file (`file/child`) is an error too (`Not a directory`),
  on purpose: `link/` gives the same error and must never report `ok()`. A
  failure inside the tree names the entry that failed in the error, and what was
  removed before it stays removed. Unix removal crosses mount points; on
  Windows, reparse-point entries (junctions, volume mount points and unknown
  third-party tags alike) are unlinked when supported, never traversed.
  Windows drive and UNC paths use native syntax, with drive and
  share roots refused. To avoid Win32 path aliases, Windows also refuses input
  paths with alternate-data-stream syntax or a component ending in a dot or
  space. A timeout returns the error but does not stop a removal that is
  running. `Path.rename(from, to, timeout_ms)` renames a file, a symlink (moved
  as a link) or a directory to a path that does not exist, in one step: an
  existing target, even an empty directory, is an error and is never replaced.
  Linux uses `renameat2` with `RENAME_NOREPLACE`; macOS uses `renameatx_np` with
  `RENAME_EXCL`; Windows uses `MoveFileExW` with no flags, so it neither
  replaces a target nor copies across volumes. There is no copy/delete
  fallback across volumes. `Path.resolve` is lexical and does not
  resolve symlinks.
- `Path.real(path)` gives the absolute canonical path with every symlink
  resolved, as POSIX `realpath` does, so the path must exist. A missing path, a
  loop of links (or too long a chain of them), and a name that is not a
  directory are errors with the OS error text, like other filesystem errors; an
  empty path or one with NUL gives the same contract error as `File.stat`. A
  relative path starts at the working directory. `.`, `..` and repeated `/` are
  removed, and `..` after a link follows the link's target. The length of the
  path has no buffer limit in the VM; the system's own limit applies to the
  absolute form of the path (1024 bytes or more fail on macOS, and 260
  characters or more on Windows unless long paths are on). In the result, each
  byte that is not part of a valid UTF-8 sequence becomes U+FFFD, as in
  `Dir.list` names. The call has no timeout argument; it runs in the pool of
  file threads and does not stop other tasks.
  Where the systems differ, the difference is the system's:
  - macOS accepts a `/` after a file (`file/` gives the file); Linux and Windows
    give an error.
  - Windows removes `.` and `..` from the typed text before it follows any link,
    so `link/..` is the folder that holds the link, not the parent of its
    target, and `missing/..` is not an error. A name under a file gives
    ENOENT (Linux and macOS: ENOTDIR). The path starts with a drive letter
    (`/` is the drive of the working directory, such as `C:/`). The binary
    opts in to long paths in its manifest, so a path whose absolute form is
    260 characters or more works when the machine sets `LongPathsEnabled` to
    1; otherwise it is an error, and so is `Dir.mkdir` of one.

### Processes

`Process` is an opaque handle, with no constructor, fields, equality or JSON
encoding; `IO.inspect` prints `<Process>`. Signatures are in
[`library/io-and-system/process.md`][agentica-link-3].

- Starting a program needs no flag. With `agentica --deny-run file.agc` (or
  `--sandbox`, or `agentica run --deny-run`) every start returns an error that
  begins with `denied: --deny-run`, in every task, and extern blocks are refused
  as with `--deny-native`. The flag precedes the source file; later arguments
  reach `System.args`. Under `agentica test` a step program cannot start a
  program under test.
- A command without `/` is looked up in each `PATH` entry, in order. An empty
  entry is skipped, so `./name` runs a program in the working directory; a
  relative entry such as `.` resolves against it. A command with `/` is a path
  (on Windows `\` and a drive such as `C:` also make a path), relative to the
  working directory unless absolute. A name that is not found, or names a
  directory, is `executable is unavailable`. Arguments go straight to the
  program, with no shell. On Windows only `.exe` and `.com` run (no `PATHEXT`,
  no `.bat` or `.cmd`: that needs `cmd.exe`), and a name with a trailing dot or
  space, a `:` outside a drive, a `\\?\` or `\\.\` prefix, or ending in `.bat`
  or `.cmd`, is refused. The `.exe` suffix is tried before `.com` on purpose: a
  plain `tool` finds `tool.exe` first. A file that is found but cannot run is an
  error Result from `spawn`.
- Timeouts are positive milliseconds and include the lock wait. A timeout during
  stream I/O kills and closes the child; a timeout while waiting for the lock
  keeps it; a timed-out wait for exit does not terminate it.
- A send takes at most 1048576 UTF-8 bytes, or integers 0 to 255, and flushes.
  Invalid data consumes nothing. `read_bytes` takes 0 to 1048576 and waits for
  that many bytes or EOF. `read_line` takes at most 1 MiB, strips LF or CRLF,
  and decodes strictly. An empty EOF is an error, and an oversized line closes
  the child.
- `close_stdin` flushes and closes input, idempotently. `wait` returns the exit
  code, including nonzero codes, and can be repeated. A child blocks when its
  stdout pipe is full, so read it in a task while sending or waiting.
- `close` force-kills a running child, waits for it to exit (other tasks run
  meanwhile) and closes the ports it owns; it is idempotent. A timeout closes
  the child too, but does not wait for it. Return from `main`, `System.exit`, a
  diagnostic, a task failure, step exhaustion and an external interruption clean
  up the children started directly; their descendants are not covered.
  Operational failures are String error Results. A failed explicit cleanup is
  `RUNTIME-PROCESS-CLOSE` at the call. On Windows a stop is always immediate (no
  `SIGTERM` grace). Where libuv can assign its job object, the direct children
  of the VM die when the VM ends, and a child that is itself an Agentica
  program stops its own children the same way. Other descendants are not
  covered.
- `spawn_captured` works like `spawn`, with the same lookup, permission and
  cleanup, except that the child starts in `dir` (`"."` keeps the working
  directory; an empty, NUL or non-directory `dir` is an error) and its streams
  are read by the VM. The child never blocks on a full pipe. Stdout is read by
  `read_line` and `read_bytes`; stderr never reaches the program's stderr. Past
  1 MiB of unread stdout, or of stderr, that stream is truncated and later bytes
  are dropped; after a truncation every stdout read returns `error("process:
  output exceeds 1048576 bytes")`.
- `output` waits until both streams end and returns `ProcessOutput(stdout,
  stderr, truncated)`: the stdout not read yet, all of stderr (invalid UTF-8
  becomes U+FFFD), and whether a stream was truncated. It consumes nothing. A
  timeout is `error("network: operation timed out")` and keeps the child. On a
  `spawn` handle it is `error("process: output is not captured")`.
- Closing a captured child sends `SIGTERM`, then `SIGKILL` one second later, so
  a child that is itself an Agentica program can stop its own children first.
  `close` and a timeout never wait. At the end of a run a captured child gets
  about one second; a child from `spawn` is killed at once.
- `spawn_channel(command, args, dir, timeout_ms)` works like `spawn_captured`
  and also opens a channel to the child: a private channel (a socket pair; on
  Windows a pipe per direction), separate from its stdin, stdout and stderr,
  that carries text lines in both directions.
  The child finds it on descriptor 3, and its environment holds
  `AGENTICA_CHANNEL=3`. On Windows the channel is a pipe in each direction: the
  child reads descriptor 3 and writes descriptor 4, and the variable is
  `AGENTICA_CHANNEL=3,4`. `spawn` and `spawn_captured` remove that variable from
  the child's environment, even when the parent inherited it, so a program only
  ever sees a channel its own parent opened for it. The channel works on Linux,
  macOS and Windows, `agentica test` included.
- `channel_read_line(p, timeout_ms)` reads one line the child sent, with the
  rules of `read_line` (at most 1 MiB, LF or CRLF removed, strict UTF-8, an
  empty end is `error("process: end of input")`). When the child's stdout or
  stderr is cut (more than 1 MiB unread), a read that finds no complete line
  gives `error("process: output exceeds 1048576 bytes")` at once, without
  closing the channel. `channel_send(p, text, timeout_ms)` sends at most 1048576
  bytes and does not add a line end. `channel_close(p, timeout_ms)` closes the
  sending side, so the child reads the end of its input while the parent can
  still read; it is idempotent, also after the child has exited. A timeout in
  `channel_read_line` or `channel_send` closes the channel, not the process, and
  later channel calls return `error("process: channel is closed")`. On a child
  that has no channel they return `error("process: the child has no channel")`.
- `read_available(p, timeout_ms)` gives the captured stdout the VM has read
  since the last call and consumes it, without waiting for more; the timeout
  bounds only the wait for the reader lock. Output the child wrote before it
  wrote a channel line is in it once that line was read. One call takes at most
  2 MiB, and bytes that end in the middle of a UTF-8 character stay for the next
  call, unless the output has ended. After a truncation it returns
  `error("process: output exceeds 1048576 bytes")`. On a `spawn` handle it is
  `error("process: output is not captured")`.
- `Process.parent_read_line(timeout_ms)` and `Process.parent_send(text,
  timeout_ms)` are the child's side of the same channel, with the same rules and
  errors. A program that was not given a channel gets `error("process: no parent
  channel")`. The timeout must be positive, and a timeout closes the channel for
  good. The VM takes the channel at startup only when the marker is present with
  the value of its system and descriptor 3 is a socket, or a FIFO opened for
  reading and writing (on Windows: 3 a pipe that can be read and 4 one that can
  be written); a regular file, a device or a one-way FIFO there is left alone
  and the program has no channel.

### Native code

An `extern` block (section 5) declares C functions of a native library, which a
program then calls like any `def`. Pages for people:
[`library/io-and-system/native/_index.md`][agentica-link-4].

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
  pointer, below) and the resources and structs of the block (below); a result
  may also be `Void`. `C.Int` is `PARSE-EXTERN-TYPE`: write the width. A
  function takes at most 64 parameters (`PARSE-EXTERN-ARITY`). A `Float` passed
  as a `C.Float` is rounded to the nearest float, and one outside its range
  becomes an infinity.
- A signed integer result is sign-extended and an unsigned one zero-extended,
  so a `C.UInt32` above 2^31 is a positive `Int`. There is no unsigned 64-bit
  type: declare a `uint64_t` or `size_t` as `C.Int64` and an `unsigned long` as
  `C.Long`. The same bits cross, and a value above the signed maximum reads as
  negative, as `std/binary`'s `read_i64` reads it (`C.UInt64` and `C.ULong` are
  `PARSE-EXTERN-TYPE`).
- The library is a plain string literal: a name without `/`, which the system
  loader looks up, or an absolute path. Anything else is
  `PARSE-EXTERN-LIBRARY`. The library opens at the first call of one of its
  functions and stays open; a library, dependency or function that cannot be
  found is `RUNTIME-NATIVE-LOAD` at the extern function. The working directory
  is never searched. On Windows a name (`"ucrtbase.dll"`) is looked up in the
  folder of `agentica.exe` and the system folder, not in `PATH`; an absolute
  path is written with escaped backslashes (`"C:\\libs\\x.dll"`), and the DLLs
  it needs are searched in its folder and the default folders, never in `PATH`
  (a MinGW DLL that needs `libgcc_s_seh-1.dll` must have it next to it). A
  relative path there
  (`"lib\\x.dll"`, `"C:x.dll"`) is `RUNTIME-NATIVE-LOAD`. On macOS a name
  (`"libsqlite3.dylib"`) is looked up as `/usr/lib/NAME` (and in
  `DYLD_LIBRARY_PATH`), which finds the system libraries in the dyld shared
  cache (`"libSystem.B.dylib"` has libc and libm); any other library needs an
  absolute path. macOS drops `DYLD_*` variables when a protected program
  (`/usr/bin/env`, `/bin/sh`) starts agentica, so `DYLD_LIBRARY_PATH` does not
  pass through a shebang line or a shell.
- A package names its libraries in its manifest (`[native.NAME]`,
  05b-modules.md): `extern "NAME"` in a file of the package then opens the file
  it ships for the running system by its absolute path in `deps/`, or the
  system name it gives.
- An argument is checked before the call: an integer takes the bits of its type
  read as signed or as unsigned, as `put_int8` to `put_int32` do (a `C.UInt8` or
  `C.Int8` takes -128 to 255, a `C.Int32` or `C.UInt32` -2^31 to 2^32 - 1, a
  `C.Long` the same on Windows and any `Int` elsewhere), and C gets its low
  bits; one outside is `RUNTIME-INTEGER-OVERFLOW`. A `C.String` with a NUL
  character is `RUNTIME-INVALID-CHARACTER`. The C function gets a copy of each
  string, which it may read only during the call. A `C.String` result is copied;
  `NULL` reads as `""`, and bytes that are not UTF-8 become U+FFFD. A result
  that may be NULL is declared `-> C.Pointer` and read with `Native.get_string`.
- `C.Pointer` is a C pointer (`void *`), a builtin type that any code may hold.
  It may be NULL: `Native.null()` makes one and `Native.null?(p)` tests it.
  Pointers have no `==`. `IO.inspect` prints `<C.Pointer>`.
- `C.Bytes` is a parameter only (as a result it is `PARSE-EXTERN-TYPE`): a
  `List[Int]` whose items are bytes (an item outside 0 to 255 is
  `RUNTIME-INVALID-NUMBER`). C gets a `const uint8_t *` to a copy, valid only
  during the call; pass the length as a parameter of its own.
- Memory that C returns is read through its `C.Pointer`, from a byte offset
  past it: `Native.get_string(p, offset)` copies the NUL-terminated text,
  `Native.get_string(p, offset, length)` exactly `length` bytes (NUL bytes
  included), and `Native.get_bytes(p, offset, length)` gives the bytes as a
  `List[Int]` (Ruby ffi's `get_string` and `get_bytes`). Bytes that are not
  UTF-8 become U+FFFD. A NULL `p` with length 0 reads as empty (C's way
  to say empty: SQLite gives NULL for an empty blob); any other NULL `p` is
  `RUNTIME-NATIVE-NULL` at the pointer, checked first, and then a negative
  length is `RUNTIME-INVALID-COUNT` at the length. A pointer or a
  length that C does not own is undefined behavior, like a wrong signature, and
  is not checked. `Native.pointer(n)` is the `C.Pointer` with the integer value
  `n`, for sentinels such as `SQLITE_TRANSIENT` (`Native.pointer(-1)`).
- `Native.memory_pointer(size)` makes an owned buffer: `size` zeroed bytes that
  Agentica allocates, as a `C.Pointer` that goes wherever a `C.Pointer`
  parameter is (a negative size is `RUNTIME-INVALID-COUNT`). The calling task
  owns it like a resource: `Native.free(p)` frees it once (again does nothing),
  the owner's end frees it, and so does the end of the run, as for a resource
  (below). `Native.memory_pointer(size) do |p| ... end` gives a new buffer to
  the block, frees it when the block ends (also when it returns an error early
  with `try`) and has the block's value; a buffer that the block hands to
  another task is left to that owner. `Task.spawn_owning` hands it over
  (section 6c); a channel send or a task's result does not move it. A size the
  system cannot give, and any size above 256 TiB (2^48 bytes), is
  `RUNTIME-INVALID-COUNT`. A `compute def` call holds its buffer arguments as it
  holds resources: a free meanwhile runs when the call returns, and a read or
  write of the buffer meanwhile races with C. A freed buffer is
  `RUNTIME-NATIVE-CLOSED` in every later read, write or call; `Native.free` of a
  pointer that C gave is `RUNTIME-NATIVE-NOT-OWNED`. `put_pointer` stores an
  address that nothing tracks, so the buffer it names must outlive C's use.
  `IO.inspect` prints `<C.Pointer>`, and `Native.null?` is false.
- Typed memory, at a byte offset past any `C.Pointer` (alignment is not needed):
  `Native.get_int8`, `get_int16`, `get_int32`, `get_int64`, `get_uint8`,
  `get_uint16`, `get_uint32` (an `Int`), `get_float32`, `get_float64` (a
  `Float`) and `get_pointer` (a `C.Pointer`) take `(p, offset)`;
  `Native.put_int8` to `put_int64`, `put_float32`, `put_float64` and
  `put_pointer` take `(p, offset, value)`. A `put_intN` takes an `Int` that
  fits in N bits as signed or unsigned (`put_int8` takes -128 to 255), else
  `RUNTIME-INTEGER-OVERFLOW` at the value. `Native.put_string(p, offset, text)`
  writes the bytes of `text` and a NUL, a C string (a NUL in `text` is
  `RUNTIME-INVALID-CHARACTER`), and `Native.put_bytes(p, offset, bytes)` writes
  a `List[Int]` of bytes (one outside 0 to 255 is `RUNTIME-INTEGER-OVERFLOW`,
  every item checked first). In bulk, `Native.get_array_of_int32`,
  `get_array_of_int64`, `get_array_of_float32` and `get_array_of_float64` take
  `(p, offset, count)` and give a `List[Int]` or `List[Float]`; the
  `put_array_of_*` forms take `(p, offset, values)` and check every item before
  the first is written.
- An owned buffer knows its size: a read or write that starts before it or runs
  past its end is `RUNTIME-NATIVE-BOUNDS`, at the offset, or at the count, list
  or text that runs past; so is `Native.get_string` of a buffer with no NUL
  after the offset, or with a length past its end. Nothing outside the buffer is
  ever touched. A `C.Pointer` that C gave has no size: a NULL one is
  `RUNTIME-NATIVE-NULL` (unless the count is 0, as for `Native.get_bytes`) and a
  negative offset `RUNTIME-NATIVE-BOUNDS`; any other offset and count are
  trusted, and memory that C does not own is undefined behavior, like a wrong
  signature. Two tasks that read and write the same memory of C at once race, as
  in C; each read or write of an owned buffer holds a lock. A negative count is
  `RUNTIME-INVALID-COUNT`.
- `resource Db, free: db_close` declares a resource: a nominal type for the
  pointers that the block's functions return, freed by `void db_close(void *)`
  of the same library. A function declared `-> Db` gives a `Result[Db]`: a NULL
  result is `error("SYMBOL returned NULL")`, anything else is `ok` with a new
  resource that the calling task owns. A resource argument is always a live
  pointer: a call with a closed one is `RUNTIME-NATIVE-CLOSED`, before any
  argument is copied. `Native.close(r)` runs `free` once and marks the resource
  closed; closing it again does nothing. If the owning task ends first (return,
  crash or cancel), its end runs `free`, as for a handle (section 6c), and
  `Task.spawn_owning` hands a resource to another task. A `compute def` call
  holds its resource arguments until it returns: a close or the owner's end
  meanwhile marks them closed, and `free` runs when the call ends. When the run
  ends (`main` returns, `System.exit`, a crash of `main`, or the first
  `SIGINT`, `SIGTERM` or `SIGHUP`), child programs stop, files are written, and
  then every resource and owned buffer still open is freed, whatever task owns
  it, newest first; one that a running `compute def` call holds is freed when
  the call returns, and a queued compute call is never made. These frees and
  the file writes share one flush limit (`--flush-timeout`): a `free` that takes
  longer is left behind and stderr gets one warning line. A second stop signal
  ends the run at once. A resource and a `C.Pointer` do not convert into each
  other. Every resource result is a new
  pointer that the program owns: a function that returns a pointer it keeps (a
  borrowed one) must be declared `-> C.Pointer`, or its pointer is freed twice.
  A `def` of `db_close` in the same block is `PARSE-EXTERN-FREE`; the check
  stops at the block, so do not declare it in another one either. `IO.inspect`
  prints `<Db>`; `to_s` is `CHECK-TYPE-MISMATCH` and JSON `CHECK-NOT-ENCODABLE`,
  as for other handles.
- An `out` parameter (section 5) gets a pointer to a slot that is zeroed before
  the call: an `int *` for `C.Int32`, a `void **` for `C.Pointer` or a resource.
  The call returns the function's record, with the C result as `result` and
  each value C left in a slot as the field of its name:
  `opened = Raw.sqlite3_open(path)`, then `opened.result` and `opened.db`. An
  out resource that is not NULL is a new resource that the calling task owns,
  as for a resource result. A NULL one (C wrote NULL or left the slot alone)
  is a resource that is closed already: nothing ever frees it, `Native.close`
  does nothing, and a call that takes it is `RUNTIME-NATIVE-CLOSED`; check the
  C result before using it. In a `compute def` call C fills the slots on the
  pool thread; a cancel drops the record, and an out resource of a call that
  ran is freed once when it returns. `C.String` and `C.Bytes` cannot be out
  parameters (take a `char **` as an out `C.Pointer`).
- `Native.closed?(x)` is `true` when a call with `x` would be
  `RUNTIME-NATIVE-CLOSED`: a resource closed by `Native.close` (in any task) or
  by the end of its owning task (also the end of a task that returned it), a
  NULL out resource, and an owned buffer that `Native.free`, its block or its
  owner's end freed. A live resource or buffer is `false`, also while a
  `compute def` call holds it; one closed during that call is `true` at once,
  though `free` waits for the call. A `C.Pointer` of C is never closed (NULL
  included: `Native.null?` tests that). `true` is final; `false` can be out of
  date at once if another task may close `x`. It never stops the task and costs
  as little as a field read. Any other argument is `CHECK-TYPE-MISMATCH`.
- A `struct` of the block (section 5) is a C struct passed and returned by
  value, laid out as the C compiler of the system lays it out (libffi computes
  the offsets): Ruby ffi's `class P < FFI::Struct; layout ...`. The program sees
  a record, copied both ways. A struct result is a new record with each field
  read from C (a `C.Bool` field is true when its byte is not 0). A struct
  argument is copied into C memory for the call, each field checked as an
  argument is: an integer outside the bits of its type is
  `RUNTIME-INTEGER-OVERFLOW`, a `C.Float` is rounded, and a freed owned buffer
  in a `C.Pointer` field is `RUNTIME-NATIVE-CLOSED`, all before C runs. A field
  is changed with `.with` and the new record passed back (llama.cpp's params). A
  `C.Pointer` field is an address that nothing tracks, so the memory it names
  must outlive C's use; a `compute def` call holds the owned buffers in the
  fields of its struct arguments as it holds its buffer arguments. A struct with
  a fixed array field (`char name[16]`) cannot be declared yet.
- A C function whose address is known only at run time, such as a slot of a
  table of function pointers (onnxruntime's `OrtApi`), is declared with a
  first parameter `fn: C.Function` (section 5) and called with that address,
  read with `Native.get_pointer`; Ruby ffi's `FFI::Function.new(ret, params,
  pointer)`. Its other parameters, result, out parameters, resources and
  `compute def` work as for a function found by name. A NULL address is
  `RUNTIME-NATIVE-NULL` at the extern function and an owned buffer
  `RUNTIME-NATIVE-BOUNDS`, both before C runs; any other address is trusted,
  and one that is not a function of that signature is undefined behavior, like
  a wrong signature. `resource Session, free: C.Function` declares a resource
  freed through a function pointer (`api->ReleaseSession`): the call that makes
  one takes the address of its free function as its last parameter (a
  `C.Function`, also checked for NULL before C runs), and `Native.close`, the
  owner's end and a dropped compute result call that address, once. An
  extern block whose functions are all called through a pointer never opens
  its library, so a wrong library path is not reported.
- A `def` call blocks timers, I/O and other tasks until it returns, and the step
  limit cannot stop it in the middle. Native code must retry calls cut
  short by `EINTR`: GC signals can interrupt sleeps and polls.
- A `compute def` call runs on the VM's compute pool (one thread per
  scheduler, calls in the order they come), and the calling task waits while
  other tasks run. Its result is the plain C value, as for `def`. Nothing stops
  it in the middle: it has no timeout, and the step limit does not end it. For
  a limit, run the call in a task and use `Task.await(task, ms)`. A cancel
  skips a call that has not started; a running call runs on, the cancelled
  task stops waiting, and the result is dropped. A call that never returns
  holds a pool thread for the rest of the run, and once `--schedulers` such
  calls are stuck, every later compute call waits. The end of the run does not
  wait for a running call. The arguments are copied before the call, a
  `C.String` result is copied as it returns, and the function runs on another
  thread, so it must be safe to call from one.
- `Native.wait_readable(fd, timeout_ms)` and `Native.wait_writable(fd,
  timeout_ms)` give a `Result[Void]`: the task waits until the descriptor `fd`
  of native code (a socket, a pipe) can be read or written, while other tasks
  run. This is how a library in non-blocking mode (libpq, curl multi) waits:
  `try Native.wait_readable(Raw.PQsocket(conn), 5_000)`. The wait polls a
  new open of the file of `fd` (`/proc/self/fd`, `F_GETPATH` on macOS), so the
  native code keeps its descriptor and its flags, and two tasks may wait on one
  descriptor. A socket, a terminal master, or a file that cannot be opened
  again (an eventfd, a pipe on macOS), is polled through a duplicate instead,
  and its flags are put back after the poll starts. An error or a
  hang-up on the descriptor ends the wait with `ok` too, as in poll(2): the
  next native call reports it. After `timeout_ms` (positive) the result is
  `error("native: timed out")`. A timeout that is not positive, a negative
  `fd`, and a descriptor that is closed or cannot be polled (a regular file,
  `/dev/null` on Linux; macOS calls it always ready) give an error that starts
  with `native: `. A close of `fd`
  during a wait does not end it: it ends at its timeout unless the file
  becomes ready. A cancel stops the wait. On Windows only a socket can be waited
  on: `fd` is a Winsock `SOCKET` of the library, polled through a duplicate
  socket. That puts it in non-blocking mode, which is not put back (Winsock
  cannot read it). One socket handle takes one wait at a time: a second wait on
  the same handle value while one polls gives an error that starts with
  `native: `, and the value of a closed socket may stay busy until its wait
  ends. Any other value (a C runtime descriptor, a file or pipe handle) gives
  such an error too, and so does a closed socket, usually (Windows reuses
  handle values).
- Native code is allowed by default and can start programs itself.
  `agentica --deny-native file.agc` (and `agentica run --deny-native`, or any
  `--deny-*` flag, or `--sandbox`) refuses
  a program that declares any extern function or calls a `Native.*` builtin
  before anything runs: `RUNTIME-NATIVE-DENIED`, exit 2. Under `agentica
  test` such a test file is a file error with that code.
- Native calls work on Linux x86_64, Windows x64 and macOS (x86_64 and
  arm64), and waits on Linux x86_64, macOS and Windows (sockets only).
  Elsewhere such a program is refused at load with
  `RUNTIME-NATIVE-UNSUPPORTED`, exit 2.
  `check`, `compile` and the queries work on every system.
- A variadic C function is declared with `...` before its variadic part and
  the C type of each argument the call passes (section 5); the C name after
  `=` lets one function have several shapes:

  ```ruby
  extern "libc.so.6"
    def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
    def fcntl_get(fd: C.Int32, cmd: C.Int32, ...) -> C.Int32 = "fcntl"
    def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  end
  ```

  The call follows the variadic rules of the system's C ABI (libffi's
  `ffi_prep_cif_var`): on Apple arm64 the variadic arguments go on the stack,
  and on Windows x64 a variadic `double` goes in an integer register too. A
  `def` without `...` for a variadic C function is a wrong signature.
- The VM trusts the signature: a wrong one is undefined behavior in C, and
  native code runs with the rights of the program.

[agentica-link-1]: ../../site/content/library/io-and-system/network.md
[agentica-link-2]: ../../site/content/library/io-and-system/files.md
[agentica-link-3]: ../../site/content/library/io-and-system/process.md
[agentica-link-4]: ../../site/content/library/io-and-system/native/_index.md
[agentica-link-5]: ../../site/content/library/text-and-data/zlib.md
