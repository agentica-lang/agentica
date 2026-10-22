# Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. The
interpreter uses the host user's filesystem permissions. With `--deny-fs` (or
`--sandbox`) every call here but `Path.join` and `Lazy.write_lines` returns an
error starting `denied: --deny-fs`.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.each_line(path: String, buffer_bytes: Int, timeout_ms: Int) do |line| ... end -> Result[Void]
File.foreach(path: String, buffer_bytes: Int, timeout_ms: Int) -> Lazy[String]   # lazy.md
Lazy.write_lines(lazy: Lazy[String], path: String, timeout_ms: Int) -> Result[Void]   # lazy.md
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

- Calls accept regular files, symlinks to them, and FIFOs, pipes and devices
  that can wait (their calls wait on the event loop). They reject directories, a
  missing path for a read, and a path that reopens a pipe the VM made for itself
  (`/proc/self/fd/N`, `/dev/fd/N`); pipes the VM received at start (stdin,
  stdout, stderr, `bash <(...)`) stay readable through `/dev/stdout`,
  `/proc/self/fd/1` and the like, and only the descriptor the VM writes its own
  stdout or stderr through is refused. On Windows no File call waits on a
  stream: they accept only regular files (and folders where a folder is meant),
  and a named pipe or device is refused at once; streams that can wait reach the
  program there as stdin, stdout, stderr, process pipes and sockets.
- Modes: `read` needs an existing non-directory; `write` creates or truncates;
  `append` creates or appends; `create_private` creates a new write-only file
  only you can use and fails if the path exists (a dangling link too; it never
  follows a link). Unix: mode 0600. Windows: a protected DACL granting only the
  current user, checked on the opened object.
- Text is strict UTF-8. Whole-text helpers and each stream read or write are
  limited to 1 MiB. `read_bytes` takes 1..1048576 bytes and returns `ok([])` at
  EOF. Bytes are 0..255.
- `read_line` removes LF or CRLF and accepts a final unterminated line. EOF
  before any line, or invalid UTF-8, is an error.
- `File.stat` follows symlinks and returns `FileInfo(kind: String, size_bytes:
  Int, modified_seconds: Int, mode: Int, user_id: Int, group_id: Int)`;
  directory sizes are zero; `mode` is the permission bits with setuid, setgid
  and sticky (384 is `rw-------`). On Windows `mode` is only the read-only
  attribute (438 = octal 666 writable, 292 = octal 444 read-only) and `user_id`
  and `group_id` are always 0 (not the owner; nothing about the ACL).
  `File.lstat` does not follow a final symlink: `kind` is `"link"`.
- `Dir.list` returns immediate entry names sorted by name. `Dir.mkdir` creates
  parents and succeeds if the directory exists. `Dir.mkdir_private` makes one
  directory only you can use and fails if the path exists or the parent is
  missing (Unix: mode 0700; Windows: the owner-and-DACL check of
  `create_private`).
- `File.try_lock(handle, ms)` takes an exclusive lock on an open regular file
  without waiting: `ok(true)` if taken, `ok(false)` if another handle or process
  holds it (a pipe, FIFO or device such as `/dev/null` is an error). It ends
  when the handle closes or the program ends; children do not keep it; there is
  no unlock; repeat calls on the same handle succeed. Unix locks are advisory
  (`flock`); Windows locks cover the whole byte range (`LockFileEx`) and the OS
  also rejects reads and writes through other handles while it is held.
- `Path.remove` deletes a file, a symlink itself, or a directory with all it
  holds, never following a symlink (a link inside is removed as a link). A
  missing path is `ok()`. It refuses a filesystem root, a trailing separator,
  `.` or `..` as the final component, and trees deeper than 128 levels.
  `"link/"` and `"file/child"` are errors (`Not a directory`) on purpose. A
  failure inside the tree names the entry that failed; what went before stays
  removed. Unix removal crosses mount points like `rm -rf`; Windows removes
  reparse points, junctions included, without traversing them, accepts native
  drive and UNC paths but refuses drive and share roots, and refuses
  alternate-data-stream syntax or a component ending in a dot or space. A
  timeout gives an error but does not stop a removal in progress.
- `Path.rename(from, to, ms)` moves a file, a symlink (as a link) or a directory
  to a path that does not exist, atomically: an existing target, even an empty
  directory, is an error and never replaced, so racing programs get one winner.
  Both paths must be on one file system; Windows uses `MoveFileW` with no
  copy/delete fallback.
- `Path.join` uses host path rules. `Path.resolve` makes a lexical absolute path
  without resolving symlinks. `Path.real` resolves every symlink like POSIX
  `realpath`: the path must exist, a relative path starts at the current
  directory, and it has no timeout argument. Windows drops `..` from the text
  before it follows a link (`link/..` is the link's folder), answers the working
  directory's drive for `/`, and fails when the absolute path is 260 characters
  or more (`Dir.mkdir` too) unless the machine sets `LongPathsEnabled` to 1;
  macOS fails at 1024 bytes or more and accepts `file/`.
- `File.read_text` of a pipe reads to EOF. A FIFO with no writer gives EOF;
  opening one for writing with no reader is an error.

## Streaming lines

`File.each_line` opens `path` and calls the block once per line without reading
the whole file. The block returns `Result[Void]`: `ok()` continues; an
`error(...)` stops the call and becomes its result. `try` and `return
error(...)` work inside it.

- A line with its terminator is at most `buffer_bytes` (1024..16777216), else
  `RUNTIME-INVALID-COUNT` at that argument before the file opens. A longer line
  gives `error("filesystem: line exceeds buffer_bytes")`.
- `timeout_ms` bounds each read, the open and the close, not the whole call; it
  must be positive, else an error Result.
- LF and CRLF are removed and a final unterminated line is passed. Invalid UTF-8
  ends the call with an error. The file closes on every return path.
- For steps over the lines use `File.foreach` (`lazy.md`).

## Ownership and closing

- A file belongs to the task that opened it. The VM closes it, flushing its
  output, when that task returns, crashes or is cancelled. `Task.await` of that
  task returns after a regular file is flushed, so a parent awaiting a helper
  reads everything the helper wrote (`tasks.md`).
- `close` flushes and is idempotent. `flush` and `close` return Results.
  `File.close` on a handle whose owner is closing waits for that close and
  returns its result.
- Output is buffered (4096 bytes per handle) until it overflows, `File.flush`,
  `File.close` or the end of the run, so a write error may show up late.

## Timeouts

- Timeouts are positive milliseconds and include waiting for the handle's lock.
- A timeout during active I/O closes that handle (later calls say it is closed);
  a timeout only waiting for the lock leaves it open.
- Calls on regular files, DNS lookups and TLS certificate loading share one
  thread pool per process: 4 threads by default. Set `UV_THREADPOOL_SIZE` (up to
  1024) in the environment before the program starts; later changes have no
  effect.
- Calls on pipes, FIFOs and terminals (stdin too, when `/proc` lets the VM
  reopen it) wait on the event loop, so a timeout really ends the wait.

## End of run and signals

At the end of a run the VM closes every open file and waits for pending writes
and the stdout and stderr buffers, at most 30000 ms. `--flush-timeout MS`, or
`AGENTICA_FLUSH_TIMEOUT_MS` (0 to 86400000; a bad value exits 2; the flag wins),
sets that wait; it cannot be turned off. When time runs out the run ends with
the same exit code and one stderr line, `agentica: file data may not be
written: ...` (`--json`: `{"flush_timeout_ms": MS, "warning": "file data may not
be written"}`), a warning, not a diagnostic. `SIGINT`, `SIGTERM` and `SIGHUP`
end the same way: files are written, then the VM ends by the signal
(`processes.md`).
