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

## File.write_text

```text
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

## File.append_text

```text
File.append_text(path: String, text: String, timeout_ms: Int = 30000) -> Result[Void]
```

Adds text at the end of a file. It creates the file when it is missing.

## File.read_text

```text
File.read_text(path: String, timeout_ms: Int = 30000) -> Result[String]
```

Reads a whole file as text.

```agentica {mode="check"}
def main() -> Void
  case File.read_text("notes.txt", 1000)
    ok(text) -> puts("#{text.trim.split("\n").size} lines")
    error(message) -> IO.warn("cannot read: #{message}")
  end
end
```

## File.sha256

```text
File.sha256(path: String, timeout_ms: Int = 30000) -> Result[Bytes]
```

Hashes a whole file with SHA-256 and returns the 32 digest bytes as a [`Bytes`](/library/data-structures/bytes/), the same bytes `Digest.sha256` gives for the same content; `Digest.hexencode` writes them as hex. It streams the file in 64 KiB chunks, so a file far over the 1 MiB text cap still hashes.

```agentica {mode="check"}
def main() -> Void
  case File.sha256("notes.txt", 1000)
    ok(digest) -> puts(Digest.hexencode(digest))
    error(message) -> IO.warn("cannot hash: #{message}")
  end
end
```

- Only regular files are hashed; symbolic links are followed. A missing path, a directory, a FIFO, pipe or device give `error("filesystem: path does not refer to a regular file")`, as `File.read_text` does.
- `timeout_ms` covers the whole call. When it runs out the call returns `error("filesystem: operation timed out")` and a running hash is dropped. A cancelled task detaches the same way.
- There is no snapshot: a concurrent writer changes the digest. To verify a download, write it to a temporary name, hash it, then `Path.rename` it into place.

## File.stat

```text
File.stat(path: String, timeout_ms: Int = 30000) -> Result[FileInfo]
```

Gives a `FileInfo`: `kind` (`"file"` or `"directory"`), `size_bytes`, `modified_seconds`, `mode`, `user_id`, `group_id`. A symbolic link is followed.

- `mode` is the permission bits as an `Int`, with setuid, setgid and sticky: `rw-------` is 384 (octal 600).
- Windows has no Unix bits or owner ids: `mode` is only the read-only attribute (438 writable, 292 read-only; it says nothing about the ACL), and `user_id` and `group_id` are always 0, which is not the owner.

```agentica {mode="check"}
def main() -> Void
  info = File.stat("notes.txt", 1000).unwrap!
  puts("#{info.kind}: #{info.size_bytes} bytes, mode #{info.mode}")
end
```

## File.lstat

```text
File.lstat(path: String, timeout_ms: Int = 30000) -> Result[FileInfo]
```

Like `File.stat`, but a symbolic link is not followed: `kind` is `"link"`, `size_bytes` is the length of the link text, the other fields are the link's own.

## File.open and File.close

```text
File.open(path: String, mode: String = "read", timeout_ms: Int = 30000) -> Result[FileHandle]
File.close(handle: FileHandle, timeout_ms: Int = 30000) -> Result[Void]
```

Opens a file for streaming.

| Mode | Meaning |
|---|---|
| `"read"` | read an existing file |
| `"write"` | create the file, or empty it |
| `"append"` | write at the end of the file |
| `"create_private"` | a new file that only you can read and write |

`"create_private"` fails when the path exists (a dangling link too) and never follows a link, so another user cannot redirect the write. Unix: mode 0600, less where the umask clears bits. Windows: a protected DACL that grants only the current user; creation fails unless the opened object has that owner and DACL.

`close` writes pending data. Closing twice is fine.

- A file belongs to the task that opened it and closes, with its data written, when that task ends. `Task.await` of that task returns after a regular file's data is written (not a flush to a FIFO or a pipe), so a parent that awaits a helper reads everything it wrote. A `close` on a file already closing waits for that close.
- At program end the run waits for open files to be written and for `puts` and `IO.warn` output to reach its pipe or file, at most 30 seconds (`--flush-timeout MS` or `AGENTICA_FLUSH_TIMEOUT_MS`; the flag wins). When time runs out the exit code stays and stderr gets one line saying file data may not be written.
- On `SIGINT`, `SIGTERM` or `SIGHUP`: child programs stop first, then files are written, then the program ends by that signal. A second signal ends it at once, once the children have stopped. Under `agentica`, Ctrl-C reaches the program directly; `agentica` waits 2 seconds, sends `SIGTERM`, waits 2 more, then kills it.
- A path that reopens one of the program's own internal pipes, or the descriptor behind stdout or stderr (`/proc/self/fd/5`), gives `error("filesystem: path does not refer to a regular file")`. Pipes the program got at start (stdin, stdout, stderr, a shell `<(...)`) open by path.
- Windows: file calls accept only regular files (and folders where a folder is meant); a named pipe or a device is refused at once.

```agentica {mode="check"}
def main() -> Void
  file = File.open("out.txt", "write", 1000).unwrap!
  r = File.write(file, "hello\n", 1000)
  closed = File.close(file, 1000)
  puts(closed.ok?)
end
```

## File.write and File.flush

```text
File.write(handle: FileHandle, text: String, timeout_ms: Int = 30000) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int = 30000) -> Result[Void]
```

`write` adds text to an open file. `flush` sends what is buffered to the disk.

```agentica {mode="check"}
def save_lines(path: String, lines: List[String]) -> Result[Void]
  file = try File.open(path, "write", 1000)
  for line in lines
    try File.write(file, line + "\n", 1000)
  end
  try File.flush(file, 1000)
  return File.close(file, 1000)
end

def main() -> Void
  puts(save_lines("list.txt", ["a", "b"]))
end
```

## File.try_lock

```text
File.try_lock(handle: FileHandle, timeout_ms: Int = 30000) -> Result[Bool]
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
  closed = File.close(file, 1000)
end
```

## File.read_line

```text
File.read_line(handle: FileHandle, timeout_ms: Int = 30000) -> Result[String]
```

Reads one line without its line ending. At the end of the file it gives an error result. Loop with `while line.ok?`, or use `File.each_line`.

## File.each_line

```text
File.each_line(path: String, buffer_bytes: Int = 65536, timeout_ms: Int = 30000) do |line| ... end -> Result[Void]
```

Calls the block with each line, without its line ending (LF and CRLF; a last line without one is passed too). The file is never read whole, so a file larger than memory works, and so do FIFOs and pipes. The file closes on every way out.

- The block returns a `Result[Void]`: `ok()` goes on, an `error(...)` stops and is the result. `try` and `return error(...)` work in the block.
- `buffer_bytes` is the longest line, counting its ending: 1024 to 16777216, else `RUNTIME-INVALID-COUNT` before the file opens. A longer line ends the call with `error("filesystem: line exceeds buffer_bytes")`.
- `timeout_ms` (positive) limits each read, the open and the close, not the whole call. A silent pipe ends the call with an error.
- The text is strict UTF-8: invalid bytes end the call with an error.
- For a chain of steps over the lines (`select`, `map`, `first(n)` ...), use [`File.foreach`](/library/data-structures/lazy/#fileforeach), a `Lazy[String]` with the same reads. To write the lines of a `Lazy[String]` to a file, use [`write_lines`](/library/data-structures/lazy/#write_lines).

```agentica {mode="check"}
def main() -> Void
  r = File.each_line("notes.txt", 4096, 1000) do |line|
    if line.starts_with?("#")
      return error("comment found: #{line}")
    end
    ok()
  end
  puts(r)
end
```

## File.read_bytes and File.write_bytes

```text
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int = 30000) -> Result[Bytes]
File.write_bytes(handle: FileHandle, bytes: Bytes, timeout_ms: Int = 30000) -> Result[Void]
```

Both take and give a [`Bytes`](/library/data-structures/bytes/). `read_bytes` reads 1 to 1048576 bytes and gives empty bytes at the end of the file; `write_bytes` writes at most 1048576 bytes per call.

```agentica {mode="check"}
def main() -> Void
  out = File.open("data.bin", "write", 1000).unwrap!
  w = File.write_bytes(out, Bytes.from_list([0, 1, 255]).unwrap!, 1000)
  c = File.close(out, 1000)
  input = File.open("data.bin", "read", 1000).unwrap!
  puts(File.read_bytes(input, 16, 1000).unwrap!.to_a)
end
```

```text
[0, 1, 255]
```

## Dir.list

```text
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

```text
Dir.mkdir(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Creates a directory and any missing parents. An existing directory is fine.

## Dir.mkdir_private

```text
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

```text
Path.join(parts: List[String]) -> Result[String]
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

```text
Path.cwd() -> Result[String]
Path.resolve(path: String) -> Result[String]
```

`cwd` gives the current directory. `resolve` makes an absolute path, without following links.

## Path.real

```text
Path.real(path: String) -> Result[String]
```

Like POSIX `realpath`: the absolute path with every symbolic link resolved and `.`, `..` and repeated separators removed. Unlike `resolve`, it reads the disk, so the path must exist (a missing path, a link loop or a non-directory is an error). Invalid UTF-8 bytes become U+FFFD. It has no timeout; it runs in the file pool and does not stop other tasks.

The system's own rules show through:

- macOS fails a path of 1024 bytes or more, and accepts a `/` after a file (`file/` gives the file); Linux and Windows give an error for it.
- Windows removes `.` and `..` from the typed text before it follows a link, so `link/..` is the folder that holds the link and `missing/..` is not an error. The result starts with a drive letter (`/` is the drive of the working directory, such as `C:/`). A path of 260 characters or more works only when the machine sets `LongPathsEnabled` to 1; otherwise it is an error, as is `Dir.mkdir` of one.

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

```text
Path.remove(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Deletes a file, a symbolic link, or a directory with everything in it. A missing path gives `ok()`.

- It never follows a link: a link is deleted itself, and what it names is left alone.
- It refuses a filesystem root, a trailing separator, `.` and `..` (also as the end of `dir/..`), and a tree more than 128 levels deep (left partly deleted).
- A failed call keeps what it already deleted; the error names the failing entry with the system error. A timeout gives an error but the started removal runs to its end.
- Unix crosses mount points, as `rm -rf` does. Windows removes junctions and other reparse points themselves without traversing them, refuses drive or share roots, alternate-data-stream syntax and components ending in a dot or space.

```agentica {mode="check"}
def main() -> Void
  puts(Path.remove("build", 5000))
  puts(Path.remove("old.log", 1000))
end
```

## Path.rename

```text
Path.rename(from: String, to: String, timeout_ms: Int = 30000) -> Result[Void]
```

Renames a file, a symbolic link or a directory to a path that does not exist yet, in one step.

- It never replaces anything: when `to` exists (even an empty directory) the call fails and nothing changes, so two programs racing for a name have exactly one winner.
- A symbolic link moves as a link.
- Both paths must be on one file system; there is no copy fallback. It uses native no-replace operations on Linux, macOS and Windows.

```agentica {mode="check"}
def main() -> Void
  made = Dir.mkdir_private("/tmp/job-new", 1000)
  claimed = Path.rename("/tmp/job-new", "/tmp/job", 1000)
  puts(claimed.ok?)
end
```
