# Files and paths

`File`, `Dir`, `Path`, `FileHandle`, and `FileInfo` are reserved. The
interpreter uses the host user's filesystem permissions. With `--deny-fs` (or
`--sandbox`) every call here but `Path.join`, and `Lazy.write_lines`, returns
an error starting `denied: --deny-fs`.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.each_line(path: String, buffer_bytes: Int, timeout_ms: Int) do |line| ... end -> Result[Void]
File.foreach(path: String, buffer_bytes: Int, timeout_ms: Int) -> Lazy[String]   # references/lazy.md
Lazy.write_lines(lazy: Lazy[String], path: String, timeout_ms: Int) -> Result[Void]   # references/lazy.md
File.read_text(path: String, timeout_ms: Int) -> Result[String]
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
File.lstat(path: String, timeout_ms: Int) -> Result[FileInfo]
File.try_lock(handle: FileHandle, timeout_ms: Int) -> Result[Bool]
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Void]
Dir.mkdir_private(path: String, timeout_ms: Int) -> Result[Void]
Path.cwd() -> Result[String]
Path.join(parts: List[String]) -> Result[String]
Path.resolve(path: String) -> Result[String]
Path.real(path: String) -> Result[String]
Path.remove(path: String, timeout_ms: Int) -> Result[Void]
Path.rename(from: String, to: String, timeout_ms: Int) -> Result[Void]
```

## Opening and reading

- Operations accept regular files, symlinks to them, and FIFOs, pipes, and
  devices that can wait (their calls wait on the event loop). They reject
  directories, a missing path for a read, and a path that reopens a pipe the VM
  made for itself (`/proc/self/fd/N`, `/dev/fd/N`). Pipes the VM received at
  start (stdin, stdout, stderr, or `bash <(...)`) stay readable through
  `/dev/stdout`, `/proc/self/fd/1`, and the like; only the descriptor the VM
  writes its own stdout or stderr through is refused. On Windows no File call
  waits on a stream: they accept only regular files (and folders where a folder
  is meant), and a named pipe or a device is refused at once with an error.
  Streams that can wait reach the program there as stdin, stdout, stderr,
  process pipes and sockets.
- Modes: `read` needs an existing path that is not a directory; `write` creates
  or truncates; `append` creates or appends; `create_private` creates a new
  write-only file that only you can use and fails if the path exists (a dangling
  link too; it never follows a link). Unix: mode 0600. Windows: no mode, a
  protected DACL that grants only the current user, checked on the opened
  object.
- Text is strict UTF-8. Whole-text helpers and each stream read or write are
  limited to 1 MiB. `read_bytes` takes 1..1048576 bytes and returns `ok([])` at
  EOF. Bytes are 0..255.
- `read_line` removes LF or CRLF and accepts a final unterminated line. EOF
  before any line, or invalid UTF-8, is an error.
- `File.stat` follows symlinks and returns `FileInfo(kind: String, size_bytes:
  Int, modified_seconds: Int, mode: Int, user_id: Int, group_id: Int)`;
  directory sizes are zero; `mode` is the permission bits with setuid, setgid
  and sticky (384 is `rw-------`). On Windows there are no permission bits and
  no owner ids: `mode` is only the read-only attribute (438 octal 666 writable,
  292 octal 444 read-only) and `user_id` and `group_id` are always 0, which is
  not the owner and says nothing about the ACL or DACL. `File.lstat` is the same
  without following a final symlink: `kind` is `"link"`.
- `Dir.list` returns immediate entry names sorted by name. `Dir.mkdir` creates
  parents and succeeds if the directory exists. `Dir.mkdir_private` makes one
  directory only you can use and fails if the path exists or the parent is
  missing (Unix: mode 0700; Windows: the same owner-and-DACL check as
  `create_private`).
- `File.try_lock(handle, ms)` takes an exclusive lock on an open file without
  waiting: `ok(true)` if taken, `ok(false)` if another handle or process holds
  it. Only a regular file can be locked (a pipe, FIFO or device such as
  `/dev/null` is an error). It ends when the handle is closed or the program
  ends; children do not keep it. There is no unlock call. Repeat calls on the
  same handle succeed. Unix locks are advisory (`flock`); Windows locks cover
  the whole byte range (`LockFileEx`) and the OS also rejects reads and writes
  through other handles while the lock is held.
- `Path.remove` deletes a file, a symlink itself, or a directory with all it
  holds, never following a symlink (a link inside is removed as a link). A
  missing path is `ok()`. It refuses a filesystem root, a trailing separator,
  `.` or `..` as the final component, and trees deeper than 128 levels.
  `"link/"` and `"file/child"` are errors (`Not a directory`) on purpose, so
  `"link/"` never reports `ok()`. A failure inside the tree names the entry that
  failed, and what went before stays removed. Unix removal crosses mount points
  like `rm -rf`; Windows removes reparse points, including junctions, without
  traversing them. Windows accepts native drive and UNC paths, but refuses drive
  and share roots. To avoid Win32 path aliases, it also refuses input paths with
  alternate-data-stream syntax or a component ending in a dot or space. A
  timeout gives an error but does not stop a removal that is running.
- `Path.rename(from, to, ms)` moves a file, a symlink (as a link) or a directory
  to a path that does not exist, atomically: an existing target, even an empty
  directory, is an error and is never replaced, so racing programs get one
  winner. Both paths must be on one file system; Windows uses `MoveFileW` with
  no copy/delete fallback.
- `Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path
  without resolving symlinks. `Path.real` resolves every symlink like POSIX
  `realpath`: the path must exist (else an error), a relative path starts at the
  current directory, and it has no timeout argument. Windows drops `..` from
  the text before it follows a link (`link/..` is the link's folder), answers
  the working directory's drive for `/`, and fails when the absolute path is
  260 characters or more (`Dir.mkdir` too); macOS fails at 1024 bytes or more
  and accepts `file/`.
- `File.read_text` of a pipe reads to EOF. A FIFO with no writer gives EOF;
  opening one for writing with no reader is an error.

## Streaming lines

`File.each_line` opens `path` and calls the block once per line, never reading
the whole file. The block returns `Result[Void]`: `ok()` continues; an
`error(...)` stops the call and becomes its result. `try` and `return
error(...)` work inside it.

- A line, with its terminator, is at most `buffer_bytes` (1024..16777216).
  Otherwise the call gives `RUNTIME-INVALID-COUNT` at that argument, before the
  file opens. A longer line gives `error("filesystem: line exceeds
  buffer_bytes")`.
- `timeout_ms` bounds each read, the open, and the close, not the whole call. It
  must be positive, else an error Result.
- LF and CRLF are removed, and a final unterminated line is passed. Invalid
  UTF-8 ends the call with an error. The file is closed on every return path.
- For steps over the lines, use `File.foreach` (a `Lazy[String]`, `lazy.md`).

## Ownership and closing

- A file belongs to the task that opened it. The VM closes it, flushing its
  output, when that task ends by return, crash, or cancel. `Task.await` of that
  task returns after a regular file is flushed, so a parent that awaits a helper
  reads everything the helper wrote (see `tasks.md` for the ownership rules).
- `close` flushes output and is idempotent. `flush` and `close` return Results.
  `File.close` on a handle whose owner is closing waits for that close and
  returns its result.
- Output is buffered (4096 bytes per handle) until it overflows, `File.flush`,
  `File.close`, or the end of the run, so a write error may show up late.

## Timeouts

- Timeouts are positive milliseconds and include waiting for the handle's lock.
- A timeout during active I/O closes that handle; later calls say it is closed.
  A timeout while only waiting for the lock leaves it open.
- Calls on regular files, DNS lookups, and TLS certificate loading share one
  thread pool per process: 4 threads by default. Set `UV_THREADPOOL_SIZE` (up to
  1024) in the environment before starting the program to raise it; changing it
  later has no effect.
- Calls on pipes, FIFOs, and terminals (stdin too, when `/proc` lets the VM
  reopen it) wait on the event loop, so a timeout really ends the wait.

## End of run and signals

At the end of a run the VM closes every open file and waits for pending writes
and the stdout and stderr buffers, for at most 30000 ms. `agentica
--flush-timeout MS`, or the variable `AGENTICA_FLUSH_TIMEOUT_MS` (0 to 86400000;
a bad value exits 2; the flag wins), sets that wait. There is no way to turn the
limit off.

When time runs out, the run ends with the same exit code and one stderr line,
`agentica: file data may not be written: ...`. With `--json` it is
`{"flush_timeout_ms": MS, "warning": "file data may not be written"}`. That is a
warning, not a diagnostic.

`SIGINT`, `SIGTERM`, and `SIGHUP` take the same end (see `processes.md`): files
are written, then the VM ends by the signal.
