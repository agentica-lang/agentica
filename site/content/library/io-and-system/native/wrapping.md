---
title: Wrapping a C library
weight: 5
description: Hide the C habits of a library (return codes, out pointers, varargs) behind a normal Agentica API, and ship it in a package.
---

A C library is shaped by C: return codes, pointers that C fills, handles with a free function, variadic functions. A good wrapper keeps that out of sight. The `extern` block is the raw layer, and the public functions on top of it look like the rest of Agentica. For a whole library done this way, read [SQLite](/library/io-and-system/native/sqlite/); this page gives the rules. The examples name the Linux libraries (`libc.so.6`, `libm.so.6`).

## Two layers

The raw layer is one `extern` block per library, with each signature copied from the C header, the C names as they are, and no `?` or `!` (`PARSE-EXTERN-NAME`). It is not part of your API. The public layer is plain Agentica:

| In C | In the public API |
|---|---|
| A return code or a NULL | `Result[T]`, with an error text that names the bad value |
| A handle and the function that frees it | a [resource](/library/io-and-system/native/types/#resources), returned in a `Result` |
| An `int` that answers yes or no | a function named `name?` that returns `Bool` |
| A pointer that C fills | an [`out` parameter](/library/io-and-system/native/types/#out-parameters), turned into the fields of your own struct |
| A call that may take long | a [`compute def`](/library/io-and-system/native/compute/) in the raw layer, so the other tasks keep running; the wrapper calls it like any function |
| A variadic function | functions of a normal shape (see Variadic functions below) |

Exported functions come before private ones, and a resource comes before the functions that use it (`CHECK-DECL-ORDER`). A block with a resource therefore goes in a file of its own, `raw.agc`, that only your own files import; the public file wraps it. A block without resources can stay private at the end of the public file, as in the examples after this one.

```agentica {file="raw.agc"}
extern "libc.so.6"
  export resource Stream, free: fclose
  export def fopen(path: C.String, mode: C.String) -> Stream
  export def fputs(text: C.String, stream: Stream) -> C.Int32
  export compute def fflush(stream: Stream) -> C.Int32
  export def isatty(fd: C.Int32) -> C.Int32
end
```

```agentica {mode="check"}
import Raw from "raw"

## Opens a file for appending, or says which path failed.
export def open_append(path: String) -> Result[Raw.Stream]
  case Raw.fopen(path, "a")
    Result.Ok(stream) -> return ok(stream)
    Result.Err(_) -> return error("cannot open #{path}")
  end
end

## Writes one line.
export def write_line(stream: Raw.Stream, text: String) -> Result[Void]
  if Raw.fputs("#{text}\n", stream) < 0
    return error("cannot write to the stream")
  end
  return ok()
end

## Pushes the buffered text to the file.
export def flush(stream: Raw.Stream) -> Result[Void]
  if Raw.fflush(stream) != 0
    return error("cannot flush the stream")
  end
  return ok()
end

## True when the descriptor is a terminal.
export def tty?(fd: Int) -> Bool
  return Raw.isatty(fd) == 1
end
```

`fopen` is declared `-> Stream`, so the raw call already gives a `Result[Stream]`; the wrapper only replaces its message with one that names the path. Callers close the stream with `Native.close`, or the task that owns it frees it when it ends.

## Out parameters

An `out` parameter does not reach the public API. The raw call returns a record with the C result as `result` and one field per out parameter; the wrapper copies them into a struct whose fields say what they are.

```agentica {mode="check"}
struct Split
  whole: Float
  fraction: Float
end

## Splits x into its whole part and its fraction, both with the sign of x.
export def split(x: Float) -> Split
  parts = modf(x)
  return Split(whole: parts.whole, fraction: parts.result)
end

extern "libm.so.6"
  def modf(x: C.Double, out whole: C.Double) -> C.Double
end
```

## Variadic functions

Agentica functions have no variadic parameters, and a wrapper does not add any. Declare the C function once for each [shape](/library/io-and-system/native/types/#variadic-functions-and-c-names) that your wrapper needs, with `...` and `= "symbol"`, and keep the shapes private. The public function takes a normal parameter instead:

- Parameters with defaults, when an argument is optional (`on: Bool = true`).
- A struct, when there are many options. Export a constant with the default values and let the caller change a field with `with`: `OPEN_DEFAULTS.with(create: true)`.
- A `List[T]`, when the count of arguments changes. The wrapper picks the shape from the length of the list and returns an `error` for a length it has no shape for.

```agentica {mode="check"}
O_WRONLY = 1
O_CREAT = 64
F_SETFD = 2
FD_CLOEXEC = 1

## Read only, and mode 0600 when the file is created.
export OPEN_DEFAULTS = OpenOptions(write: false, create: false, mode: 384)

struct OpenOptions
  write: Bool
  create: Bool
  mode: Int
end

## Opens a file and gives its descriptor.
export def open_file(path: String, options: OpenOptions) -> Result[Int]
  flags = 0
  if options.write
    flags = flags + O_WRONLY
  end
  if options.create
    flags = flags + O_CREAT
  end
  fd = open(path, flags, options.mode)
  if fd < 0
    return error("cannot open #{path}")
  end
  return ok(fd)
end

## Sets or clears close-on-exec.
export def set_close_on_exec(fd: Int, on: Bool = true) -> Result[Void]
  flag = 0
  if on
    flag = FD_CLOEXEC
  end
  if fcntl_set(fd, F_SETFD, flag) < 0
    return error("cannot set close-on-exec on #{fd}")
  end
  return ok()
end

## Writes one or two fields to fd, separated by a tab and ended by a newline.
export def write_fields(fd: Int, fields: List[String]) -> Result[Void]
  written = -1
  if fields.length == 1
    written = dprintf1(fd, "%s\n", fields[0])
  elsif fields.length == 2
    written = dprintf2(fd, "%s\t%s\n", fields[0], fields[1])
  end
  if written < 0
    return error("cannot write #{fields.length} fields to #{fd}")
  end
  return ok()
end

extern "libc.so.6"
  def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
  def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  def dprintf1(fd: C.Int32, format: C.String, ..., a: C.String) -> C.Int32 = "dprintf"
  def dprintf2(fd: C.Int32, format: C.String, ..., a: C.String, b: C.String) -> C.Int32 = "dprintf"
end
```

`write_fields` never lets its caller choose the format. The format is a constant of the wrapper, and the caller's text goes in as `%s` arguments, so a `%` in a field is only text.

## Shipping it in a package

A package that wraps a library names the library for each system in its `agentica.toml`, as `[native.NAME]` with a `system` name or a `file` of its `native/` folder, and its `raw.agc` opens it with `extern "NAME"`:

```toml
[native.sqlite3]
linux = { system = "libsqlite3.so.0" }
macos = { system = "libsqlite3.dylib" }
windows = { file = "native/windows/sqlite3.dll" }
```

The lock covers the files of `native/`, and a system without an entry is a diagnostic where a file uses the library. See [Packages](/tour/modules/) for the rules and the codes. Document the wrapper file as the API of the package.
