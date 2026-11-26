---
title: File, Dir and Path
weight: 2
description: Read and write files, list and create directories, and build paths.
---

Every file function takes a timeout in milliseconds and returns a `Result`. It defaults to 30000 and may be left out. `File.open` also defaults its mode to `"read"`, and `File.each_line` and `File.foreach` default `buffer_bytes` to 65536.

- Text is UTF-8. One text call reads or writes at most 1 MiB (`File.sha256` streams bytes and has no cap). Files have the permissions of the user who runs the program.
- With `--deny-fs` (or `--sandbox`), every call on this page except `Path.join`, and `Lazy.write_lines` and `Lazy.write_bytes`, returns an error that begins with `denied: --deny-fs`.
- Regular files use a pool of 4 threads, shared with DNS lookups and TLS certificate loading, so calls wait for a free thread when many run. Raise it (at most 1024) before the program starts: `UV_THREADPOOL_SIZE=16 agentica app.agc`.
- Pipes, FIFOs and terminals skip the pool and wait on the event loop, so their timeout always ends the wait. `File.read_text` of a pipe reads until the writer closes it.
- File calls accept regular files and symbolic links to them, and also FIFOs, pipes and devices that can wait. They reject directories, a missing path for a read, and a path that reopens a pipe the VM made for itself. `File` is a reserved name, with the members `File.Handle` and `File.Info`; a file handle is opaque.

## File.write_text

```signature
File.write_text(path: String, text: String, timeout_ms: Int = 30000) -> Result[Void]
```

Creates or replaces a file with the text.

```agentica {mode="check"}
def main() -> Void
  r = File.write_text("notes.txt", "first line\n", 1000)
  puts(r)
end
```

```text
ok()
```

## File.replace

```signature
File.replace(path: String, data: Bytes, timeout_ms: Int = 30000) -> Result[Void]
```

Replaces an existing regular file with at most 16 MiB of bytes in one step, so a reader sees the old file or the new one, never a part or no file. Use it to save a file that people edit, as `agentica fmt` does.

```agentica {mode="check"}
def main() -> Void
  r = File.replace("notes.txt", "second draft\n".bytes, 1000)
  puts(r)
end
```

- The bytes go to a new file in the same folder, which only the owner can read while it is written; it then takes the old file's permission bits, is flushed to the disk and is renamed over it. A failure removes the new file and leaves the old one as it was. A process killed during the write can leave a hidden `.agc-PID-N.tmp` file in the folder. Writing needs write permission on the folder.
- A symbolic link is followed and stays a link: the file it points to is replaced. The new file belongs to the user who runs the program, and a hard link to the old file keeps the old bytes.
- The file must exist and be a regular file: a missing path is `error("filesystem: cannot resolve path ...")`, a directory or a FIFO `error("filesystem: path does not refer to a regular file")`. Use `File.write_text` to create a file.
- On Windows a read-only file is an error, and nothing is written. Of the old file's attributes only the read-only bit is kept: the access list comes from the folder, and the hidden and system attributes are dropped.

## File.append_text

```signature
File.append_text(path: String, text: String, timeout_ms: Int = 30000) -> Result[Void]
```

Adds text at the end of a file. It creates the file when it is missing.

## File.read_text

```signature
File.read_text(path: String, timeout_ms: Int = 30000) -> Result[String]
```

Reads a whole file as text.

```agentica {mode="check"}
def main() -> Void
  case File.read_text("notes.txt", 1000)
    ok(text) -> puts("#{text.strip.split("\n").size} lines")
    error(message) -> IO.warn("cannot read: #{message}")
  end
end
```

## File.sha256

```signature
File.sha256(path: String, timeout_ms: Int = 30000) -> Result[Bytes]
```

Hashes a whole file with SHA-256 and returns the 32 digest bytes as a [`Bytes`](/library/data-structures/bytes/), the same bytes `OpenSSL.Digest.sha256` gives for the same content; `OpenSSL.Digest.hexencode` writes them as hex. It streams the file in 64 KiB chunks, so a file far over the 1 MiB text cap still hashes.

```agentica {mode="check"}
def main() -> Void
  case File.sha256("notes.txt", 1000)
    ok(digest) -> puts(OpenSSL.Digest.hexencode(digest))
    error(message) -> IO.warn("cannot hash: #{message}")
  end
end
```

- Only regular files are hashed; symbolic links are followed. A missing path, a directory, a FIFO, pipe or device give `error("filesystem: path does not refer to a regular file")`, as `File.read_text` does.
- `timeout_ms` covers the whole call and must be positive, otherwise `error("filesystem: timeout must be positive milliseconds")`. When it runs out the call returns `error("filesystem: operation timed out")` and a running hash is dropped. A cancelled task detaches the same way.
- There is no snapshot: a concurrent writer changes the digest. To verify a download, write it to a temporary name, hash it, then `Path.rename` or `Path.replace` it into place.

## File.stat

```signature
File.stat(path: String, timeout_ms: Int = 30000) -> Result[File.Info]
```

Gives a `File.Info`: `kind`, `size_bytes`, `modified_seconds`, `mode`, `user_id`, `group_id`. A symbolic link is followed.

- `kind` is Ruby's `File::Stat#ftype` name: `"file"` (a regular file only), `"directory"`, `"fifo"`, `"socket"`, `"characterSpecial"` (such as `/dev/null`), `"blockSpecial"` or `"unknown"`. Windows gives `"file"`, `"directory"`, `"link"` (`File.lstat` of a reparse point) and `"characterSpecial"` for `NUL`. Check `kind == "file"` before reading a path you did not make: a read of a FIFO can wait for a writer.

- `mode` is the permission bits as an `Int`, with setuid, setgid and sticky: `rw-------` is 384 (octal 600).
- Windows has no Unix bits or owner ids: `mode` is only the read-only attribute (438 writable, 292 read-only; it says nothing about the ACL), and `user_id` and `group_id` are always 0, which is not the owner.

```agentica {mode="check"}
def main() -> Void
  info = File.stat("notes.txt", 1000).unwrap!
  puts("#{info.kind}: #{info.size_bytes} bytes, mode #{info.mode}")
end
```

## File.lstat

```signature
File.lstat(path: String, timeout_ms: Int = 30000) -> Result[File.Info]
```

Like `File.stat`, but a symbolic link is not followed: `kind` is `"link"`, `size_bytes` is the length of the link text, the other fields are the link's own.

## File.chmod

```signature
File.chmod(path: String, mode: Int, timeout_ms: Int = 30000) -> Result[Void]
```

Sets the permission bits of the file or directory at `path`, in the form `File.stat` reads them: `File.chmod(path, 0o755)` makes a file executable. `mode` is octal, so write `0o755` (`755` is `0o1363`). It is 0 to 4095 (octal 7777, setuid, setgid and sticky included); another value gives an `argument` error, and a missing path gives `io.not_found`.

- A symbolic link is followed, so its target changes.
- Unix: the bits go to `chmod(2)` as given, and the umask does not apply. The system may clear setgid when you are not in the file's group.
- Windows has no Unix bits: for a file only the owner write bit counts. With it set the file is writable (`File.stat` gives 438), with it clear the file is read-only (292). The other bits are ignored. A directory gets the same attribute, which Windows does not enforce, so the files inside stay writable.
- A timeout gives an error, but the started change runs to its end.

```agentica {mode="check"}
def main() -> Void
  File.write_text("tool.sh", "echo hi\n", 1000).unwrap!
  File.chmod("tool.sh", 0o755, 1000).unwrap!
  puts(File.stat("tool.sh", 1000).unwrap!.mode)
end
```

## File.symlink

```signature
File.symlink(target: String, link: String, timeout_ms: Int = 30000) -> Result[Void]
```

Makes the symbolic link `link` whose text is `target`, as Ruby's `File.symlink` does (the target first, the link second).

- The text is kept as given, and `target` need not exist: a link to a missing path (a dangling link) is made, and it works once the target appears. A relative `target` is read from the folder of `link`, not from the working directory, so `File.symlink("a.txt", "dir/b.txt")` links `dir/b.txt` to `dir/a.txt`.
- It never replaces anything: when `link` exists (a file, a folder or another link, dangling or not), the call fails with `io.exists` and nothing changes. A missing folder in `link` is `io.not_found`. An empty `target` or `link`, one with a NUL, and on Windows one that starts with `\\.\` or `\\?\` give an `argument` error. The `details` of an error hold the `link` as given under `"path"` and the `target` under `"to"`.
- Windows makes the link with `CreateSymbolicLinkW` and the flag that lets a user without the privilege make it (it needs Developer Mode on; an administrator needs nothing). When the system refuses for want of that right, or answers `ENOTSUP`, the error has the kind `io.unsupported`. A `/` in `target` becomes `\`. A `target` that is a folder when the call is made gives a folder link, and one that does not exist yet gives a file link, so make the folder first.
- A timeout gives an error, but the started call runs to its end.

```agentica {mode="check"}
def main() -> Void
  File.write_text("model-v2.gguf", "weights", 1000).unwrap!
  File.symlink("model-v2.gguf", "model.gguf", 1000).unwrap!
  puts(File.readlink("model.gguf", 1000).unwrap!)
end
```

## File.readlink

```signature
File.readlink(path: String, timeout_ms: Int = 30000) -> Result[String]
```

Gives the text of the symbolic link at `path` as it was made, with no check that it names anything, so a dangling link reads fine. A `path` that is not a link is an `io.failed` error, and a missing one is `io.not_found`. The text must be UTF-8: a link made by another program with other bytes is a `text.encoding` error, never a changed text. The last name of `path` is not followed, but a link in a folder above it is.

- To tell a link from other files, `File.lstat(path).unwrap!.kind == "link"` (a missing `path` is an error there).
- Windows gives `/` for each `\` of the text, which `File.symlink` writes back as `\`: `File.symlink(File.readlink(a).unwrap!, b)` makes a link with the same text on every system.

```agentica {mode="check"}
def main() -> Void
  case File.readlink("model.gguf", 1000)
    ok(text) -> puts("model.gguf -> #{text}")
    error(e) -> puts(e.kind)
  end
end
```

## File.open and File.close

```signature
File.open(path: String, mode: String = "read", timeout_ms: Int = 30000) -> Result[File.Handle]
File.close(handle: File.Handle, timeout_ms: Int = 30000) -> Result[Void]
```

Opens a file for streaming.

| Mode | Meaning |
|---|---|
| `"read"` | read an existing file |
| `"write"` | create the file, or empty it |
| `"append"` | write at the end of the file |
| `"create_private"` | a new file that only you can read and write |

`"create_private"` fails when the path exists (a dangling link too) and never follows a link, so another user cannot redirect the write. Unix: mode 0600, less where the umask clears bits. Windows: a protected DACL that grants only the current user; creation fails unless the opened object has that owner and DACL.

`close` writes pending data. Closing twice is fine. Timeouts are positive milliseconds and include the wait for the handle's lock: a timeout during active I/O closes the handle, and a timeout while waiting for the lock keeps it open.

- A file belongs to the task that opened it and closes, with its data written, when that task ends. `Task.await` of that task returns after a regular file's data is written (not a flush to a FIFO or a pipe), so a parent that awaits a helper reads everything it wrote. A `close` on a file already closing waits for that close.
- At program end the run waits for open files to be written and for `puts` and `IO.warn` output to reach its pipe or file, at most 30 seconds (`--flush-timeout MS` or `AGENTICA_FLUSH_TIMEOUT_MS`; the flag wins). When time runs out the exit code stays and stderr gets one line saying file data may not be written.
- On `SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1` or `SIGUSR2` that the program has not subscribed to ([`System.subscribe`](/library/io-and-system/system/#systemsubscribe)): child programs stop first, then files are written, then the program ends by that signal. `SIGQUIT` does the same and exits with 131, without a core dump. A second signal ends it at once, once the children have stopped. Under `agentica`, Ctrl-C reaches the program directly; `agentica` waits 2 seconds, sends `SIGTERM`, waits 2 more, then kills it.
- A path that reopens one of the program's own internal pipes, or the descriptor behind stdout or stderr (`/proc/self/fd/5`), gives `error("filesystem: path does not refer to a regular file")`. Pipes the program got at start (stdin, stdout, stderr, a shell `<(...)`) open by path.
- Windows: file calls accept only regular files (and folders where a folder is meant); a named pipe or a device is refused at once with `io.unsupported`.

```agentica {mode="check"}
def main() -> Void
  file = File.open("out.txt", "write", 1000).unwrap!
  _ = File.write(file, "hello\n", 1000)
  closed = File.close(file, 1000)
  puts(closed.ok?)
end
```

## File.open with a block

```signature
File.open(path: String, mode: String = "read", timeout_ms: Int = 30000) do |file| ... end -> Result[T]
```

Opens the file, calls the block with the handle, closes the handle with `File.close(file, timeout_ms)` when the block ends, and gives the block's `Result`. Use it to read or write a file through a handle; open and close a handle by hand only when it must outlive one block, such as one shared with tasks.

```agentica {mode="check"}
def main() -> Void
  r = File.open("out.txt", "write", 1000) do |file|
    try File.write(file, "hello\n")
    try File.write(file, "world\n")
    ok(2)
  end

  puts(r)
end
```

- The block gives a `Result[T]`, and `try` works in it. `T` comes from the expected type of the call (`r: Result[List[String]] = File.open(...) do ...`), or else from the block. A block that never gives `ok` (it only gives `error(...)`) fixes no `T`, and the `error(...)` in the block is `CHECK-RESULT-TYPE` until the variable has a type: `r: Result[Int] = File.open(...) do ... end`.
- `timeout_ms` limits the open and the close, each on its own; it does not limit the block, so the whole call can take longer than `timeout_ms`. Calls inside the block take their own timeouts.
- If the open fails, the block does not run and the call gives the open error.
- The handle is closed whether the block gives `ok` or `error`, an early `return` and a failed `try` included. After `ok(value)` the call gives `ok(value)`, or the close error if the close fails: the close writes pending data, so its error matters. After an error the call gives the block's error and drops a close error.
- A runtime error in the block ends the task, and the handle closes with the task, as above. A handle kept after the block (returned in the `Result`) is closed: a call on it gives `error("filesystem: file handle is closed")`.

## File.write and File.flush

```signature
File.write(handle: File.Handle, text: String, timeout_ms: Int = 30000) -> Result[Void]
File.flush(handle: File.Handle, timeout_ms: Int = 30000) -> Result[Void]
```

`write` adds text to an open file. `flush` sends what is buffered to the disk.

```agentica {mode="check"}
def save_lines(path: String, lines: List[String]) -> Result[Void]
  file = try File.open(path, "write", 1000)
  for line in lines
    try File.write(file, line + "\n", 1000)
  end

  try File.flush(file, 1000)
  File.close(file, 1000)
end

def main() -> Void
  puts(save_lines("list.txt", ["a", "b"]))
end
```

## File.try_lock

```signature
File.try_lock(handle: File.Handle, timeout_ms: Int = 30000) -> Result[Bool]
```

Takes an exclusive lock on the open file, without waiting. `ok(true)` means it is yours (also if this handle already holds it), `ok(false)` that another handle or process holds it.

- It ends when the handle closes, the opening task ends, or the program ends, even if killed. A `Process.spawn` child does not keep it. There is no unlock call.
- Unix: advisory (`flock`), so it stops only code that asks too. Windows: `LockFileEx` on the whole range, and the OS rejects reads and writes through other handles.
- Any handle mode works. Only a regular file can be locked (a pipe, FIFO or `/dev/null` is an error).

```agentica {mode="check"}
def main() -> Void
  file = File.open("app.lock", "append", 1000).unwrap!
  if File.try_lock(file, 1000).unwrap!
    puts("running alone")
  else
    puts("another copy is running")
  end

  _ = File.close(file, 1000)
end
```

## File.read_line

```signature
File.read_line(handle: File.Handle, timeout_ms: Int = 30000) -> Result[String]
```

Reads one line without its line ending (LF or CRLF; a final line without one counts). The text is strict UTF-8. At the end of the file, or on invalid UTF-8, it gives an error result. Loop with `while line.ok?`, or use `File.each_line`.

## File.each_line

```signature
File.each_line(path: String, buffer_bytes: Int = 65536, timeout_ms: Int = 30000) do |line| ... end -> Result[Void]
```

Calls the block with each line, without its line ending (LF and CRLF; a last line without one is passed too). The file is never read whole, so a file larger than memory works, and so do FIFOs and pipes. The file closes on every way out.

- The block returns a `Result[Void]`: `ok()` goes on, an `error(...)` stops and is the result. `try` and `return error(...)` work in the block.
- `buffer_bytes` is the longest line, counting its ending: 1024 to 16777216, else `RUNTIME-INVALID-COUNT` before the file opens. A longer line ends the call with `error("filesystem: line exceeds buffer_bytes")`.
- `timeout_ms` limits each read, the open and the close, not the whole call. It must be positive, otherwise `error("filesystem: timeout must be positive milliseconds")`. A silent pipe ends the call with an error.
- The text is strict UTF-8: invalid bytes end the call with an error.
- For a chain of steps over the lines (`select`, `map`, `first(n)` ...), use [`File.foreach`](/library/data-structures/lazy/#fileforeach), a `Lazy[String]` with the same reads. To write the lines of a `Lazy[String]` to a file, use [`write_lines`](/library/data-structures/lazy/#write_lines).

```agentica {mode="check"}
def main() -> Void
  r = File.each_line("notes.txt", 4096, 1000) do |line|
    return error("comment found: #{line}") if line.start_with?("#")

    ok()
  end

  puts(r)
end
```

## File.read_bytes and File.write_bytes

```signature
File.read_bytes(handle: File.Handle, max_bytes: Int, timeout_ms: Int = 30000) -> Result[Bytes]
File.write_bytes(handle: File.Handle, bytes: Bytes, timeout_ms: Int = 30000) -> Result[Void]
```

Both take and give a [`Bytes`](/library/data-structures/bytes/). `read_bytes` reads 1 to 1048576 bytes and gives empty bytes at the end of the file; `write_bytes` writes at most 1048576 bytes per call.

```agentica {mode="check"}
def main() -> Void
  out = File.open("data.bin", "write", 1000).unwrap!
  _ = File.write_bytes(out, Bytes.from_list([0, 1, 255]).unwrap!, 1000)
  _ = File.close(out, 1000)
  input = File.open("data.bin", "read", 1000).unwrap!
  puts(File.read_bytes(input, 16, 1000).unwrap!.to_a)
end
```

```text
[0, 1, 255]
```

## File.seek

```signature
File.seek(handle: File.Handle, offset: Int, timeout_ms: Int = 30000) -> Result[Void]
```

Moves a read handle to `offset` bytes from the start of the file, so the next `read_bytes` or `read_line` starts there. Use it to read one part of a large file, such as one tensor of a checkpoint, without reading what comes before.

```agentica {mode="check"}
def main() -> Void
  input = File.open("data.bin", "read", 1000).unwrap!
  File.seek(input, 2, 1000).unwrap!
  puts(File.read_bytes(input, 16, 1000).unwrap!.to_a)
end
```

- An offset past the end is fine: the next `read_bytes` gives empty bytes, as at the end of the file.
- A negative offset stops the program with `RUNTIME-INDEX-OUT-OF-RANGE` at the offset.
- Only a handle opened with `"read"` can seek; any other handle gives `error("filesystem: file handle is not open for reading")`. A pipe, FIFO or terminal gives `error("filesystem: cannot seek a pipe, FIFO or terminal")`.

## Dir.list

```signature
Dir.list(path: String, timeout_ms: Int = 30000) -> Result[List[String]]
```

Gives the names in a directory, sorted.

```agentica {mode="check"}
def main() -> Void
  for name in Dir.list(".", 1000).unwrap!
    puts(name)
  end
end
```

## Dir.mkdir

```signature
Dir.mkdir(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Creates a directory and any missing parents. An existing directory is fine.

## Dir.mkdir_private

```signature
Dir.mkdir_private(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Creates one directory that only you can enter, for a scratch directory in a shared place such as `/tmp`. It makes no parents, and an existing path is an error, so success means the directory is new and yours. Unix: mode 0700, less where the umask clears bits. Windows: the owner-and-DACL check of `File.open`.

```agentica {mode="check"}
def main() -> Void
  name = "/tmp/app-#{Random.int(0, 999999999)}"
  case Dir.mkdir_private(name, 1000)
    ok(_) -> puts("made #{name}")
    error(message) -> IO.warn("cannot make it: #{message}")
  end
end
```

## Path.join

```signature
Path.join(list: List[String]) -> Result[String]
```

Joins parts with the separator of the system.

```agentica
def main() -> Void
  puts(Path.join(["build", "reports", "a.txt"]))
end
```

```output
ok("build/reports/a.txt")
```

## Path.cwd and Path.resolve

```signature
Path.cwd() -> Result[String]
Path.resolve(path: String) -> Result[String]
```

`cwd` gives the current directory. `resolve` makes an absolute path, without following links. Neither ends in `/` except at a root; `resolve` keeps a trailing `/` only when the path ends in one.

## Path.real

```signature
Path.real(path: String) -> Result[String]
```

Like POSIX `realpath`: the absolute path with every symbolic link resolved and `.`, `..` and repeated separators removed. Unlike `resolve`, it reads the disk, so the path must exist (a missing path, a link loop or a non-directory is an error). A relative path starts at the working directory, and `..` after a link follows the link's target. An empty path or one with NUL is the same `filesystem: invalid path` error as `File.stat`. The VM puts no buffer limit on the path; the system's own limit applies to its absolute form. Invalid UTF-8 bytes become U+FFFD. It has no timeout; it runs in the file pool and does not stop other tasks.

The system's own rules show through:

- macOS fails a path of 1024 bytes or more, and accepts a `/` after a file (`file/` gives the file); Linux and Windows give an error for it.
- Windows removes `.` and `..` from the typed text before it follows a link, so `link/..` is the folder that holds the link and `missing/..` is not an error. A name under a file gives ENOENT (Linux and macOS: ENOTDIR). The result starts with a drive letter (`/` is the drive of the working directory, such as `C:/`). The binary opts in to long paths in its manifest. A path of 260 characters or more works only when the machine sets `LongPathsEnabled` to 1; otherwise it is an error, as is `Dir.mkdir` of one.

```agentica
def main() -> Void
  puts(Path.real("/"))
  puts(Path.real("/does/not/exist").ok?)
end
```

```output
ok("/")
false
```

## Path.remove

```signature
Path.remove(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Deletes a file, a symbolic link, or a directory with everything in it. A missing path gives `ok()`.

- It never follows a link: a link is deleted itself, and what it names is left alone.
- It refuses a filesystem root, a trailing separator, `.` and `..` (also as the end of `dir/..`), and a tree more than 128 levels deep (left partly deleted).
- A failed call keeps what it already deleted; the error names the failing entry with the system error. A timeout gives an error but the started removal runs to its end.
- A path under a file (`file/child`) is an error (`Not a directory`), and so is a trailing separator on a symbolic link: `link/` must never report `ok()`. A failure inside the tree names the entry that failed.
- Unix crosses mount points, as `rm -rf` does. Windows removes junctions and other reparse points themselves without traversing them, refuses drive or share roots, alternate-data-stream syntax and components ending in a dot or space.

```agentica {mode="check"}
def main() -> Void
  puts(Path.remove("build", 5000))
  puts(Path.remove("old.log", 1000))
end
```

## Path.rename

```signature
Path.rename(from: String, to: String, timeout_ms: Int = 30000) -> Result[Void]
```

Renames a file, a symbolic link or a directory to a path that does not exist yet, in one step.

- It never replaces anything: when `to` exists (even an empty directory) the call fails and nothing changes, so two programs racing for a name have exactly one winner.
- A symbolic link moves as a link.
- Both paths must be on one file system; there is no copy fallback. Linux uses `renameat2` with `RENAME_NOREPLACE`, macOS `renameatx_np` with `RENAME_EXCL`, and Windows `MoveFileExW` with no flags, so it neither replaces a target nor copies across volumes.

```agentica {mode="check"}
def main() -> Void
  _ = Dir.mkdir_private("/tmp/job-new", 1000)
  claimed = Path.rename("/tmp/job-new", "/tmp/job", 1000)
  puts(claimed.ok?)
end
```

## Path.replace

```signature
Path.replace(from: String, to: String, timeout_ms: Int = 30000) -> Result[Void]
```

Renames the regular file `from` to `to` in one step, replacing what is at `to`, as Ruby's `File.rename` does. A reader of `to` sees the old file or the new one, never neither, so it is the last step of writing a file whole: write a new file beside `to`, then replace.

- A file at `to` is replaced, and so is a symbolic link: the link itself, never its target (unlike `File.replace`, which writes through a link). A missing `to` is made.
- A directory at `to` is an `io.is_directory` error and stays as it was. A directory `from` is `io.is_directory` too, and a `from` that is a symbolic link or another file that is not regular is `io.failed`.
- `from` is synced to the disk before the rename. On POSIX the folder is flushed after it, so a power loss leaves the old file or the whole new one; Windows has no folder flush.
- The new file keeps its own permission bits and owner. Both paths must be on one file system; there is no copy fallback. POSIX uses `rename`, Windows `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`.
- On Windows `from` is opened for writing to flush it, so a read-only `from`, or one that another program holds open without write sharing, is `io.permission`. A read-only `to`, a `to` that another program holds open without `FILE_SHARE_DELETE`, and a directory link or junction at `to` are refused too.
- A timeout gives an error but does not stop a rename in progress, which then still happens whole.

```agentica {mode="check"}
def main() -> Void
  _ = File.write_text("/tmp/settings.json.new", "{}", 1000)
  puts(Path.replace("/tmp/settings.json.new", "/tmp/settings.json", 1000).ok?)
end
```
