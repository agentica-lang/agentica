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

Timeouts are positive milliseconds and include the serialized handle lock
wait. Timing out active I/O closes that handle (later calls say the handle is
closed); timing out while waiting for its lock leaves it open. Output is
buffered (4096 bytes per handle) until it overflows, `File.flush`,
`File.close` or the end of the run, so a write error may show there. FIFOs
and devices count as files, but the VM reads and writes them with blocking
calls: a FIFO with no peer may give EOF or an error instead of a timeout,
and a stuck call keeps one of libuv's 4 pool threads. Errors are Results. `File.stat` follows symlinks and
returns `FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`;
directory sizes are zero. `Dir.list` returns immediate entry names sorted by
name. `Dir.mkdir` creates parents and succeeds when the directory exists.
`Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path
without resolving symlinks.
