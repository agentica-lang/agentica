# Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
also FIFOs, pipes and devices that can wait (their calls wait on the event
loop); they reject directories, a missing path for a read, and a path that
reopens a pipe the VM made for itself.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.each_line(path: String, buffer_bytes: Int, timeout_ms: Int) do |line| ... end -> Result[Void]
File.read_text(path: String, timeout_ms: Int) -> Result[String]
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Void]
Path.cwd() -> Result[String]
Path.join(parts: List[String]) -> Result[String]
Path.resolve(path: String) -> Result[String]
```

Modes are `read`, `write` and `append`: read requires an existing path that is
not a directory; write creates or truncates; append creates or appends. Text
is strict UTF-8. Whole-text helpers and each stream read/write are limited to
1 MiB; `read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF.
`read_line` removes LF or CRLF, accepts a final unterminated line, and returns
an error for EOF before any line or invalid UTF-8. Byte values are 0..255.
Close flushes output and is idempotent. Explicit flush and close return
Results. A file belongs to the task that opened it and is closed, with its
output flushed, when that task ends (return, crash or cancel), so a file
opened in a helper task and returned through `Task.await` is closed when the
helper ends (see `tasks.md`). `File.close` on a handle that is already
closing (its owner task ended) returns `ok()` at once; the run still waits for
that close's flush.

`File.each_line` opens `path`, reads it one line at a time and calls the block
with each line, never reading the whole file. The block returns
`Result[Void]`: `ok()` goes on, an `error(...)` stops and becomes the result;
`try` and `return error(...)` work in it. A line is at most `buffer_bytes`
bytes counting its terminator (1024..16777216, else `RUNTIME-INVALID-COUNT` at
that argument, before the file opens); a longer line gives
`error("filesystem: line exceeds buffer_bytes")`. `timeout_ms` bounds each
read, the open and the close, not the whole call, and must be positive (else
an error Result). LF and CRLF are removed, a final unterminated line is
passed, invalid UTF-8 ends the call with an error, and the file is closed on
every return path. Pipes, FIFOs and devices that can wait are read on the
event loop.

Timeouts are positive milliseconds and include the serialized handle lock
wait. Timing out active I/O closes that handle (later calls say the handle is
closed); timing out while waiting for its lock leaves it open. Output is
buffered (4096 bytes per handle) until it overflows, `File.flush`,
`File.close` or the end of the run, so a write error may show there. At the
end of the run the VM closes every open file and waits for the writes, and
for the buffered output of stdout and stderr (a slow pipe reader gets all of
it), at most 30000 ms; `agentica --flush-timeout MS` or the variable
`AGENTICA_FLUSH_TIMEOUT_MS` (0 to 86400000, bad values exit 2, the flag wins,
no way to turn the limit off) sets the wait. When time runs out the VM ends the run with the same exit code and
one stderr line, `agentica: file data may not be written: ...`, or
`{"flush_timeout_ms": MS, "warning": "file data may not be written"}` with
`--json` (not a diagnostic). `SIGINT`, `SIGTERM` and `SIGHUP` take the
same end: children stop, files are written, then the VM ends by the
signal; a second signal ends it at once (after the children are
stopped). A path that reopens a pipe the VM made itself (`/proc/self/fd/N`
or `/dev/fd/N`) is refused as not a regular file; pipes the VM got at
start (standard input, output and error, `bash <(...)`) stay readable, by
`/dev/stdout`, `/proc/self/fd/1` and the like; only the number of the
descriptor the VM itself writes standard output or error through is
refused. FIFOs
and devices count as files: a FIFO with no writer gives EOF, and opening
one for writing with no reader is an error. Calls on pipes, FIFOs and
terminals (stdin too, when `/proc` lets the VM reopen it) wait on the VM's event loop, not in the thread pool,
so a timeout really ends the wait; `File.read_text` of a pipe reads to EOF.
Calls on regular files, DNS lookups and TLS certificate loading share one
thread pool per process: 4 threads by default. Set `UV_THREADPOOL_SIZE`
(up to 1024) in the environment before starting the program to raise it,
when many file calls run at once; changing it later has no effect. Errors are Results. `File.stat` follows symlinks and
returns `FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`;
directory sizes are zero. `Dir.list` returns immediate entry names sorted by
name. `Dir.mkdir` creates parents and succeeds when the directory exists.
`Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path
without resolving symlinks.
