---
title: File, Dir and Path
weight: 10
description: Read and write files, list and create directories, and build paths.
---

Every file function takes a timeout in milliseconds and returns a `Result`.
Text is UTF-8. One call reads or writes at most 1 MiB. Programs use the file
permissions of the user who runs them.

The examples on this page touch the disk, so they are checked but not run
here.

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

Gives a `FileInfo` with `kind` (such as `"file"` or `"directory"`),
`size_bytes` and `modified_seconds`.

```agentica {mode="check"}
def main() -> Void
  info = File.stat("notes.txt", 1000).unwrap!
  puts("#{info.kind}: #{info.size_bytes} bytes")
end
```

## File.open and File.close

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
```

Opens a file for streaming. The mode is `"read"`, `"write"` (create or empty
the file) or `"append"`. `close` writes pending data; closing twice is fine.
Open files are closed when the program ends.

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
