# Files and paths

`File`, `Dir`, `Path`, `FileHandle`, and `FileInfo` are reserved. The interpreter uses the host user's filesystem permissions; there is no permission flag.

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

## Opening and reading

- Operations accept regular files, symlinks to them, and FIFOs, pipes, and devices that can wait (their calls wait on the event loop). They reject directories, a missing path for a read, and a path that reopens a pipe the VM made for itself (`/proc/self/fd/N`, `/dev/fd/N`). Pipes the VM received at start (stdin, stdout, stderr, or `bash <(...)`) stay readable through `/dev/stdout`, `/proc/self/fd/1`, and the like; only the descriptor the VM writes its own stdout or stderr through is refused.
- Modes: `read` needs an existing path that is not a directory; `write` creates or truncates; `append` creates or appends.
- Text is strict UTF-8. Whole-text helpers and each stream read or write are limited to 1 MiB. `read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF. Bytes are 0..255.
- `read_line` removes LF or CRLF and accepts a final unterminated line. EOF before any line, or invalid UTF-8, is an error.
- `File.stat` follows symlinks and returns `FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`; directory sizes are zero.
- `Dir.list` returns immediate entry names sorted by name. `Dir.mkdir` creates parents and succeeds if the directory exists.
- `Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path without resolving symlinks.
- `File.read_text` of a pipe reads to EOF. A FIFO with no writer gives EOF; opening one for writing with no reader is an error.

## Streaming lines

`File.each_line` opens `path` and calls the block once per line, never reading the whole file. The block returns `Result[Void]`: `ok()` continues; an `error(...)` stops the call and becomes its result. `try` and `return error(...)` work inside it.

- A line, with its terminator, is at most `buffer_bytes` (1024..16777216). Otherwise the call gives `RUNTIME-INVALID-COUNT` at that argument, before the file opens. A longer line gives `error("filesystem: line exceeds buffer_bytes")`.
- `timeout_ms` bounds each read, the open, and the close, not the whole call. It must be positive, else an error Result.
- LF and CRLF are removed, and a final unterminated line is passed. Invalid UTF-8 ends the call with an error. The file is closed on every return path.

## Ownership and closing

- A file belongs to the task that opened it. The VM closes it, flushing its output, when that task ends by return, crash, or cancel. `Task.await` of that task returns after a regular file is flushed, so a parent that awaits a helper reads everything the helper wrote (the await does not wait for a flush to a FIFO or pipe). A file a helper returns through `Task.await` is closed when the helper ends (see `tasks.md`).
- `close` flushes output and is idempotent. `flush` and `close` return Results. `File.close` on a handle whose owner is closing waits for that close and returns its result.
- Output is buffered (4096 bytes per handle) until it overflows, `File.flush`, `File.close`, or the end of the run, so a write error may show up late.

## Timeouts

- Timeouts are positive milliseconds and include waiting for the handle's lock.
- A timeout during active I/O closes that handle; later calls say it is closed. A timeout while only waiting for the lock leaves it open.
- Calls on regular files, DNS lookups, and TLS certificate loading share one thread pool per process: 4 threads by default. Set `UV_THREADPOOL_SIZE` (up to 1024) in the environment before starting the program to raise it; changing it later has no effect.
- Calls on pipes, FIFOs, and terminals (stdin too, when `/proc` lets the VM reopen it) wait on the event loop, so a timeout really ends the wait.

## End of run and signals

At the end of a run the VM closes every open file and waits for pending writes and the stdout and stderr buffers, for at most 30000 ms. `agentica --flush-timeout MS`, or the variable `AGENTICA_FLUSH_TIMEOUT_MS` (0 to 86400000; a bad value exits 2; the flag wins), sets that wait. There is no way to turn the limit off.

When time runs out, the run ends with the same exit code and one stderr line, `agentica: file data may not be written: ...`. With `--json` it is `{"flush_timeout_ms": MS, "warning": "file data may not be written"}`. That is a warning, not a diagnostic.

`SIGINT`, `SIGTERM`, and `SIGHUP` take the same end: children stop, files are written, then the VM ends by the signal. A second signal ends it at once, after the children are stopped.
