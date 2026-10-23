---
title: Wrapping a C library
weight: 5
description: Hide the C habits of a library (return codes, out pointers, varargs) behind a normal Agentica API, and ship it in a package.
---

A C library is shaped by C. It has return codes, pointers that C fills, handles with a free function and variadic functions. A good wrapper hides all of that. The `extern` block is the raw layer. The public functions on top of it look like the rest of Agentica. [SQLite](/library/io-and-system/native/sqlite/) is a whole library done this way. This page gives the rules. The examples name the Linux libraries (`libc.so.6`, `libm.so.6`).

## Two layers

The raw layer is one `extern` block per library. Copy each signature from the C header and keep the C names. A name has no `?` or `!` (`PARSE-EXTERN-NAME`). The raw layer is not part of your API. The public layer is plain Agentica. A `String` with a NUL character stops the program when it crosses to C (`RUNTIME-INVALID-CHARACTER`), so a wrapper that must not stop checks its `String` inputs first; the examples skip that check.

| In C | In the public API |
|---|---|
| A return code or a NULL | `Result[T]`, with an error text that names the bad value |
| A handle and the function that frees it | a [resource](/library/io-and-system/native/types/#resources), returned in a `Result` |
| An `int` that answers yes or no | a function named `name?` that returns `Bool` |
| A pointer that C fills | an [`out` parameter](/library/io-and-system/native/types/#out-parameters), turned into the fields of your own struct |
| A call that may take long | a [`compute def`](/library/io-and-system/native/compute/) in the raw layer, so the other tasks keep running; the wrapper calls it like any function |
| A variadic function | functions of a normal shape (see Variadic functions below) |

A block with a resource must come before every function of the file. Exported functions must come before private ones (`CHECK-DECL-ORDER`). So the wrapper cannot sit in the same file as such a block. Put the block in its own file, `raw.agc`, and export its names. The public file imports it. The public file does not re-export the raw layer: it exports only the wrapper. One file would work if the block's functions were `export def`, but then they would be part of its API. A block without resources can stay private at the end of the public file, as in the examples after this one.

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

export type Stream = Raw.Stream

## Opens a file for appending, or says which path failed.
export def open_append(path: String) -> Result[Stream]
  case Raw.fopen(path, "a")
    Result.Ok(stream) -> return ok(stream)
    Result.Err(_) -> return error("cannot open #{path}")
  end
end

## Writes one line.
export def write_line(stream: Stream, text: String) -> Result[Void]
  if Raw.fputs("#{text}\n", stream) < 0
    return error("cannot write to the stream")
  end
  return ok()
end

## Pushes the buffered text to the file.
export def flush(stream: Stream) -> Result[Void]
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

`fopen` is declared `-> Stream`, so the raw call already gives a `Result[Stream]`. The wrapper only replaces its message with one that names the path. The alias `Stream` lets callers name the type without importing `raw.agc`. Callers close the stream with `Native.close`, or the task that owns it frees it when it ends. `fflush` is a `compute def` in the raw layer, and `flush` calls it like any function.

## Out parameters

An `out` parameter stays in the raw layer: the wrapper copies the record fields into a struct of its own.

```agentica {mode="check"}
export struct Split
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
- A struct, when there are many options. Export the struct and give its fields default values. The caller names only the fields that differ: `OpenOptions(create: true)`, or `OpenOptions()` for all the defaults.
- A `List[T]`, when the count of arguments changes. The wrapper picks the shape from the length of the list and returns an `error` for a length it has no shape for.

```agentica {mode="check"}
O_WRONLY = 1
O_CREAT = 64   # the Linux value; macOS uses 0x200
F_SETFD = 2
FD_CLOEXEC = 1

## Read only by default, and mode 0600 when the file is created.
export struct OpenOptions
  write: Bool = false
  create: Bool = false
  mode: Int = 384
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

`open_file` gives a descriptor; the example leaves out a function that closes it. `write_fields` never lets its caller choose the format. The format is a constant of the wrapper, and the caller's text goes in as `%s` arguments, so a `%` in a field is only text.

## Shipping it in a package

A package names the library for each system in `[native.NAME]` of its `agentica.toml`. Its `raw.agc` then opens it with `extern "NAME"`. See [Packages](/tour/modules/#packages) for the form, the lock and the error codes. Document the wrapper file as the API of the package.
