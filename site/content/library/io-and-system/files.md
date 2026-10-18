---
title: File, Dir and Path
weight: 2
description: Read and write files, list and create directories, and build paths.
---

Every file function takes a timeout in milliseconds and returns a `Result`.
Text is UTF-8. One call reads or writes at most 1 MiB. Programs use the file
permissions of the user who runs them.

Calls on regular files run on a pool of threads, 4 by default, which DNS lookups and loading TLS certificates share. When a program keeps many file calls going at once in several tasks, later calls wait for a free thread. To raise the size, set the `UV_THREADPOOL_SIZE` environment variable (at most 1024) when you start the program, for example `UV_THREADPOOL_SIZE=16 agentica app.agc`; setting it later has no effect. Calls on pipes, FIFOs and terminals do not use the pool: they wait on the program's event loop, so their timeout always ends the wait, and `File.read_text` of a pipe reads until the writer closes it.

The examples on this page touch the disk, so they are checked but not run
here, except the one of `Path.real`.

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

Gives a `FileInfo` with `kind` (`"file"` or `"directory"`), `size_bytes`, `modified_seconds`, `mode` and the owner as `user_id` and `group_id`. A symbolic link is followed. `mode` is the permission bits as an `Int`, with the setuid, setgid and sticky bits included: a file with mode `rw-------` has `mode` 384 (octal 600).

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

Like `File.stat`, but a symbolic link is not followed: its `kind` is `"link"`, `size_bytes` is the length of the text of the link, and the other fields are the link's own. Use it to tell a link from the file or directory it names, then `File.stat` to see what it names. VM only.

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

Opens a file for streaming. The mode is `"read"`, `"write"` (create or empty the file), `"append"` or `"create_private"` (VM only). `"create_private"` makes a new file that only you can read and write (mode 0600, less where the umask clears bits) and opens it for writing; it fails when the path already exists, including a link that points nowhere, and it never follows a link, so another user cannot make it write somewhere else. `close` writes pending data; closing twice is fine. A file belongs to the task that opened it, and it is closed, with its data written, when that task ends, and `Task.await` of that task returns after the data of a regular file is written, so a parent that awaits a helper reads everything the helper wrote to one. The await does not wait for a flush to a FIFO or a pipe. A file that a helper task opens and returns through `Task.await` is closed when the helper ends. A `close` on a file that is being closed because its task ended waits for that close and returns its result.

Open files are closed when the program ends, and the run waits until their pending data is written. It also waits until the output of `puts` and `IO.warn` has reached the pipe or file, so a slow reader gets everything. The wait is always limited, to 30 seconds by default. `agentica --flush-timeout MS app.agc` or the environment variable `AGENTICA_FLUSH_TIMEOUT_MS` sets it, and the flag wins over the variable. When time runs out, the run ends with the same exit code and prints one line on stderr saying that file data may not be written, so a write to a FIFO that nobody reads cannot keep the program from ending for ever. The same happens when the program is stopped with `SIGINT`, `SIGTERM` or `SIGHUP`: running child programs are stopped first, then the files are written, then the program ends by that signal. After a signal the run does not wait for a reader of standard output or standard error. A second signal ends it at once, once the child programs are stopped. Under `agentica`, Ctrl-C reaches the program directly; `agentica` waits 2 seconds for it to end before it sends `SIGTERM`, and 2 more before it kills it.

A path that reopens one of the program's own internal pipes, or the descriptor the program writes standard output or error through, such as `/proc/self/fd/5`, gives `error("filesystem: path does not refer to a regular file")`. Pipes the program got when it started can still be opened by path: standard input, output and error, and a pipe from the shell such as `bash`'s `<(...)`.

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

Takes an exclusive lock on the open file without waiting: `ok(true)` when it is yours (also when you already had it on this handle), and `ok(false)` when another handle or another process holds it. The lock belongs to the open file, so it ends when the handle is closed, when the task that opened it ends, or when the program ends, even if it is killed. A program started with `Process.spawn` does not keep it. On Unix the lock is advisory (`flock`): it stops only code that also asks for it. On Windows it locks the whole byte range with `LockFileEx`, and the OS also rejects reads and writes through other handles while it is held. Any handle mode works, and a read handle can lock too. Only a regular file can be locked: a pipe, a FIFO or a device (such as `/dev/null`) is an error. There is no unlock call: close the handle. VM only.

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

Reads one line without its line ending. At the end of the file it gives an
error Result.

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

Reads a file one line at a time and calls the block with each line, without its line ending. The file is never read whole, so a file much larger than memory works. The block returns a `Result[Void]`: `ok()` goes on to the next line, and an `error(...)` stops the loop and is the result of `each_line`. `try` works inside the block, and `return error(...)` stops early from inside an `if` or a loop in the block.

`buffer_bytes` is the longest line the call accepts, counting the line ending, from 1024 to 16777216. A longer line ends the call with `error("filesystem: line exceeds buffer_bytes")`. A value outside the range stops the program with `RUNTIME-INVALID-COUNT` at that argument, before the file is opened. `timeout_ms` limits each read, the open and the close, not the whole call, so a pipe or FIFO that stays silent for that long ends the call with an error, and it must be positive.

LF and CRLF are removed, and a last line without a line ending is passed too. The text is strict UTF-8: invalid bytes end the call with an error. The file is closed on every way out, including an error from the block. Like the other file calls, it also works on FIFOs and pipes, waiting on the event loop for each read.

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

Bytes are `Int` values from 0 to 255. `read_bytes` gives `ok([])` at the end
of the file.

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

Creates one directory that only you can enter (mode 0700, less where the umask clears bits). Unlike `Dir.mkdir` it makes no parents, and a path that already exists is an error, so a success means the directory is new and yours. Use it for a scratch directory in a shared place such as `/tmp`. VM only.

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

`cwd` gives the current directory. `resolve` makes an absolute path, without
following links.

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

Gives the absolute path with every symbolic link resolved, `.` and `..` removed and repeated separators collapsed, as POSIX `realpath` does. Unlike `resolve`, it reads the disk, so the path must exist: a missing path, a loop of links and a name that is not a directory are errors. A relative path starts at the current directory. In the result, each byte that is not part of a valid UTF-8 sequence becomes U+FFFD. The call has no timeout argument; it runs in the file thread pool and does not stop other tasks.

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

Deletes what is at the path: a file, a symbolic link, or a directory with everything in it. It never follows a symbolic link. A link given as the path is deleted itself, a link inside a directory is deleted as a link, and what it names is left alone. A path that is not there is `ok()`. It refuses `/`, `.` and `..` (and a path that ends in one of them, such as `dir/..`), and a tree more than 128 levels deep, which it leaves partly deleted. A link with a trailing slash (`"link/"`) is an error, and so is a path under a file (`"file/child"`): both are `Not a directory`, on purpose, so that `"link/"` never reports `ok()`. When a call fails, what it already deleted stays deleted, and the error names the path or, for a failure inside the tree, the entry that failed, with the system error. It deletes across mount points, as `rm -rf` does. A timeout gives an error but does not stop a removal that has started: it runs on until it ends. VM only.

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

Renames a file, a symbolic link or a directory to a path that does not exist yet, in one step. It never replaces anything: when `to` exists, even as an empty directory, the call is an error and nothing changes, so two programs that race for a name have exactly one winner. A symbolic link is moved as a link, and what it names is left alone. Both paths must be on the same file system; there is no copy/delete fallback across volumes. Linux, macOS and Windows use native no-replace operations. VM only.

```agentica {mode="check"}
def main() -> Void
  made = Dir.mkdir_private("/tmp/job-new", 1000)
  claimed = Path.rename("/tmp/job-new", "/tmp/job", 1000)
  puts(claimed.ok?)
end
```
