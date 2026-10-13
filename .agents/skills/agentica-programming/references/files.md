# Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
reject directories and special files.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
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

Modes are `read`, `write` and `append`: read requires an existing regular
file; write creates or truncates; append creates or appends. Text is strict
UTF-8. Whole-text helpers and each stream read/write are limited to 1 MiB;
`read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF. `read_line`
removes LF or CRLF, accepts a final unterminated line, and returns an error
for EOF before any line or invalid UTF-8. Byte values are 0..255. Close
flushes output and is idempotent. Explicit flush and close return Results.
`File.close` on a handle that is already closing (its owner task crashed)
returns `ok()` at once; the run still waits for that close's flush.

Timeouts are positive milliseconds and include the serialized handle lock
wait. Timing out active I/O closes that handle (later calls say the handle is
closed); timing out while waiting for its lock leaves it open. Output is
buffered (4096 bytes per handle) until it overflows, `File.flush`,
`File.close` or the end of the run, so a write error may show there. At the
end of the run the VM closes every open file and waits for the writes, with
no limit by default; `agentica --flush-timeout MS` (non-negative, bad values
exit 2) waits at most MS ms, then ends the run with the same exit code and
one stderr line, `agentica: file data may not be written: ...`, or
`{"flush_timeout_ms": MS, "warning": "file data may not be written"}` with
`--json` (not a diagnostic). `SIGINT`, `SIGTERM` and `SIGHUP` take the
same end: children stop, files are written, then the VM ends by the
signal; a second signal ends it at once. A path that reopens one of the
VM's own pipes (`/proc/self/fd/N` or `/dev/fd/N` above 2) is refused as not
a regular file; standard input, output and error stay readable. FIFOs
and devices count as files, but the VM reads and writes them with blocking
calls: a FIFO with no peer may give EOF or an error instead of a timeout,
and a stuck call keeps one of libuv's pool threads. File calls, stdin
reads, DNS lookups and TLS certificate loading share that one pool per
process: 4 threads by default. Set `UV_THREADPOOL_SIZE` (up to 1024) in the
environment before starting the program to raise it, when many file calls
run at once or may block; changing it later has no effect. Errors are Results. `File.stat` follows symlinks and
returns `FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`;
directory sizes are zero. `Dir.list` returns immediate entry names sorted by
name. `Dir.mkdir` creates parents and succeeds when the directory exists.
`Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path
without resolving symlinks.
