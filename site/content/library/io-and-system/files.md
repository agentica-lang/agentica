---
title: File, Dir and Path
weight: 2
description: Read and write files, list and create directories, and build paths.
---

Every file function takes a timeout in milliseconds and returns a `Result`.

- Text is UTF-8. One call reads or writes at most 1 MiB.
- Programs use the file permissions of the user who runs them.
- Regular files use a pool of 4 threads, shared with DNS lookups and TLS certificate loading. Later calls wait for a free thread when many run at once.
- To raise the pool size (at most 1024), set `UV_THREADPOOL_SIZE` before the program starts, as in `UV_THREADPOOL_SIZE=16 agentica app.agc`. Setting it later has no effect.
- Pipes, FIFOs and terminals skip the pool. They wait on the event loop, so their timeout always ends the wait. `File.read_text` of a pipe reads until the writer closes it.

The examples on this page touch the disk, so they are checked but not run here, except the one of `Path.real`.

## File.write_text

```text
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
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
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
```

Adds text at the end of a file. It creates the file when it is missing.

```agentica {mode="check"}
def main() -> Void
  r = File.append_text("log.txt", "started\n", 1000)
  puts(r.ok?)
end
```

## File.read_text

```text
File.read_text(path: String, timeout_ms: Int) -> Result[String]
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

## File.stat

```text
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
```

Gives a `FileInfo` with `kind` (`"file"` or `"directory"`), `size_bytes`, `modified_seconds`, `mode`, and the owner as `user_id` and `group_id`. A symbolic link is followed.

- `mode` is the permission bits as an `Int`, with the setuid, setgid and sticky bits. A file with mode `rw-------` has `mode` 384 (octal 600).
- On Windows there are no Unix permission bits and no Unix owner ids:
  - `mode` carries only the read-only attribute: 438 (octal 666) for a writable object, 292 (octal 444) when the attribute is set. No setuid, setgid or sticky bit appears.
  - `user_id` and `group_id` are always 0. A 0 is not the owner.
  - `mode` says nothing about the ACL or DACL. Use the file's own security settings for that.

```agentica {mode="check"}
def main() -> Void
  info = File.stat("notes.txt", 1000).unwrap!
  puts("#{info.kind}: #{info.size_bytes} bytes, mode #{info.mode}")
end
```

## File.lstat

```text
File.lstat(path: String, timeout_ms: Int) -> Result[FileInfo]
```

Like `File.stat`, but a symbolic link is not followed. Its `kind` is `"link"`, its `size_bytes` is the length of the link text, and the other fields are the link's own. Use it to tell a link from what it names. VM only.

```agentica {mode="check"}
def main() -> Void
  info = File.lstat("current", 1000).unwrap!
  if info.kind == "link"
    target = File.stat("current", 1000).unwrap!
    puts("a link to a #{target.kind}")
  end
end
```

## File.open and File.close

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
```

Opens a file for streaming.

| Mode | Meaning |
|---|---|
| `"read"` | read an existing file |
| `"write"` | create the file, or empty it |
| `"append"` | write at the end of the file |
| `"create_private"` | VM only: a new file that only you can read and write |

`"create_private"` opens a new file for writing. It fails when the path exists, including a link that points nowhere. It never follows a link, so another user cannot make it write somewhere else.

- Unix: mode 0600, less where the umask clears bits.
- Windows: no mode. The file gets a protected DACL that grants only the current user. Creation fails unless the opened object has that owner and DACL.

`close` writes pending data. Closing twice is fine.

Tasks:

- A file belongs to the task that opened it. It closes, with its data written, when that task ends.
- `Task.await` of that task returns after a regular file's data is written. So a parent that awaits a helper reads everything the helper wrote. The await does not wait for a flush to a FIFO or a pipe.
- A file that a helper opens and returns through `Task.await` closes when the helper ends.
- A `close` on a file that is closing because its task ended waits for that close, and returns its result.

Program end:

- Open files close when the program ends. The run waits until their data is written, and until the output of `puts` and `IO.warn` reaches the pipe or file.
- The wait is limited. The default is 30 seconds. Set it with `agentica --flush-timeout MS app.agc`, or the environment variable `AGENTICA_FLUSH_TIMEOUT_MS`. The flag wins.
- When time runs out, the run ends with the same exit code, and stderr gets one line saying file data may not be written. So a write to a FIFO that nobody reads cannot block the end of the program.

Signals:

- On `SIGINT`, `SIGTERM` or `SIGHUP`, running child programs stop first, then files are written, then the program ends by that signal.
- After a signal, the run does not wait for a reader of standard output or standard error. A second signal ends it at once, once the children have stopped.
- Under `agentica`, Ctrl-C reaches the program directly. `agentica` waits 2 seconds, then sends `SIGTERM`. It waits 2 more seconds, then kills the program.

Paths:

- A path that reopens one of the program's own internal pipes gives `error("filesystem: path does not refer to a regular file")`. The same goes for the descriptor that standard output or error goes through, such as `/proc/self/fd/5`.
- Pipes the program got at start can be opened by path: standard input, output and error, and a shell pipe such as `bash`'s `<(...)`.

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
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
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
File.try_lock(handle: FileHandle, timeout_ms: Int) -> Result[Bool]
```

Takes an exclusive lock on the open file, without waiting. It gives `ok(true)` when the lock is yours, also when you already hold it on this handle. It gives `ok(false)` when another handle or process holds it.

- The lock ends when the handle closes, when the task that opened it ends, or when the program ends, even if killed. A program started with `Process.spawn` does not keep it.
- Unix: advisory (`flock`). It stops only code that also asks for it.
- Windows: `LockFileEx` on the whole byte range. The OS also rejects reads and writes through other handles while it is held.
- Any handle mode works, and a read handle can lock too.
- Only a regular file can be locked. A pipe, a FIFO or a device such as `/dev/null` is an error.
- There is no unlock call. Close the handle. VM only.

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
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
```

Reads one line without its line ending. At the end of the file it gives an error result.

```agentica {mode="check"}
def main() -> Void
  file = File.open("notes.txt", "read", 1000).unwrap!
  line = File.read_line(file, 1000)
  while line.ok?
    puts(line.unwrap!)
    line = File.read_line(file, 1000)
  end
  closed = File.close(file, 1000)
end
```

## File.each_line

```text
File.each_line(path: String, buffer_bytes: Int, timeout_ms: Int) do |line| ... end -> Result[Void]
```

Reads a file one line at a time, and calls the block with each line, without its line ending. The file is never read whole, so a file larger than memory works.

- The block returns a `Result[Void]`. `ok()` goes on to the next line. An `error(...)` stops the loop, and is the result of `each_line`.
- `try` works inside the block. `return error(...)` stops early from an `if` or a loop in the block.
- `buffer_bytes` is the longest line the call accepts, counting the line ending. The range is 1024 to 16777216. A longer line ends the call with `error("filesystem: line exceeds buffer_bytes")`.
- A value outside the range stops the program with `RUNTIME-INVALID-COUNT` at that argument, before the file opens.
- `timeout_ms` limits each read, the open and the close, not the whole call. A pipe or FIFO that stays silent for that long ends the call with an error. It must be positive.
- LF and CRLF are removed. A last line without a line ending is passed too.
- The text is strict UTF-8. Invalid bytes end the call with an error.
- The file closes on every way out, including an error from the block. It works on FIFOs and pipes too.

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
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
```

Bytes are `Int` values from 0 to 255. `read_bytes` gives `ok([])` at the end of the file.

```agentica {mode="check"}
def main() -> Void
  out = File.open("data.bin", "write", 1000).unwrap!
  w = File.write_bytes(out, [0, 1, 255], 1000)
  c = File.close(out, 1000)
  input = File.open("data.bin", "read", 1000).unwrap!
  puts(File.read_bytes(input, 16, 1000))
end
```

```text
ok([0, 1, 255])
```

## Dir.list

```text
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
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
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Void]
```

Creates a directory and any missing parents. An existing directory is fine.

```agentica {mode="check"}
def main() -> Void
  puts(Dir.mkdir("build/reports", 1000))
end
```

## Dir.mkdir_private

```text
Dir.mkdir_private(path: String, timeout_ms: Int) -> Result[Void]
```

Creates one directory that only you can enter. Use it for a scratch directory in a shared place such as `/tmp`.

- Unlike `Dir.mkdir`, it makes no parents.
- A path that already exists is an error. So success means the directory is new and yours.
- Unix: mode 0700, less where the umask clears bits. Windows: the owner-and-DACL check of `File.open` applies, with no mode.
- VM only.

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

```agentica {mode="check"}
def main() -> Void
  puts(Path.cwd())
  puts(Path.resolve("notes.txt"))
end
```

## Path.real

```text
Path.real(path: String) -> Result[String]
```

Gives the absolute path, with every symbolic link resolved, `.` and `..` removed, and repeated separators collapsed, as POSIX `realpath` does.

- Unlike `resolve`, it reads the disk. The path must exist. A missing path, a loop of links, and a name that is not a directory are errors.
- A relative path starts at the current directory.
- Each byte that is not part of a valid UTF-8 sequence becomes U+FFFD in the result.
- It has no timeout argument. It runs in the file thread pool, and does not stop other tasks.

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
Path.remove(path: String, timeout_ms: Int) -> Result[Void]
```

Deletes what is at the path: a file, a symbolic link, or a directory with everything in it. A path that is not there gives `ok()`.

- It never follows a symbolic link. A link given as the path is deleted itself. A link inside a directory is deleted as a link, and what it names is left alone.
- It refuses a filesystem root, a trailing separator, `.`, and `..` (also as the final part of `dir/..`).
- It refuses a tree more than 128 levels deep. That tree is left partly deleted.
- `"link/"` (a link with a trailing separator) and `"file/child"` (a path under a file) are errors. Both give `Not a directory`, on purpose, so `"link/"` never reports `ok()`.
- A failed call keeps what it already deleted. The error names the path, or the entry that failed inside the tree, with the system error.
- A timeout gives an error, but does not stop a removal that has started. The removal runs until it ends.
- Unix: crosses mount points, as `rm -rf` does.
- Windows: removes reparse-point entries such as junctions themselves, without traversing them. Drive and UNC paths use native syntax, and drive or share roots are refused. Paths with alternate-data-stream syntax, or a component that ends in a dot or a space, are refused to avoid Win32 aliases.
- VM only.

```agentica {mode="check"}
def main() -> Void
  puts(Path.remove("build", 5000))
  puts(Path.remove("old.log", 1000))
end
```

## Path.rename

```text
Path.rename(from: String, to: String, timeout_ms: Int) -> Result[Void]
```

Renames a file, a symbolic link or a directory to a path that does not exist yet, in one step.

- It never replaces anything. When `to` exists, even as an empty directory, the call fails and nothing changes. So two programs that race for a name have exactly one winner.
- A symbolic link moves as a link. What it names is left alone.
- Both paths must be on the same file system. There is no copy and delete fallback across volumes.
- Linux, macOS and Windows use native no-replace operations. VM only.

```agentica {mode="check"}
def main() -> Void
  made = Dir.mkdir_private("/tmp/job-new", 1000)
  claimed = Path.rename("/tmp/job-new", "/tmp/job", 1000)
  puts(claimed.ok?)
end
```
