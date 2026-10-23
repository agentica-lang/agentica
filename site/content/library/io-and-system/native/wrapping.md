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
| Memory that the caller gives and C fills | a `String` or a `List` copied out of a `Native.memory_pointer` block (see Buffers and block forms below) |
| A call that may take long | a [`compute def`](/library/io-and-system/native/compute/) in the raw layer, so the other tasks keep running; the wrapper calls it like any function |
| A variadic function | functions of a normal shape (see Variadic functions below) |
| A struct of options passed by value, with a function that gives the defaults | a struct of your own with the options the caller may set, copied into the [C struct](/library/io-and-system/native/types/#c-structs) by the wrapper (see Structs of options below) |
| A table of function pointers (`api->CreateEnv(...)`) | [`C.Function`](/library/io-and-system/native/types/#function-pointers) calls in the raw layer, with the slots as constants of the wrapper (see Tables of function pointers below) |

A block with a resource sits with the types of the file, at the top and before every function, and its `def`s do not count as functions in the declaration order (`CHECK-DECL-ORDER`). So the wrapper can sit in the same file as the block. Export the resource, so that callers can name the type, and keep the `def`s private: the file exports only the wrapper. A block without a resource has no such rule. Its `def`s count as functions, so it stays at the end of the file, as in the examples after this one.

```agentica {mode="check"}
extern "libc.so.6"
  export resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
  compute def fflush(stream: Stream) -> C.Int32
  def isatty(fd: C.Int32) -> C.Int32
end

## Opens a file for appending, or says which path failed.
export def open_append(path: String) -> Result[Stream]
  case fopen(path, "a")
    Result.Ok(stream) -> return ok(stream)
    Result.Err(_) -> return error("cannot open #{path}")
  end
end

## Writes one line.
export def write_line(stream: Stream, text: String) -> Result[Void]
  if fputs("#{text}\n", stream) < 0
    return error("cannot write to the stream")
  end
  return ok()
end

## Pushes the buffered text to the file.
export def flush(stream: Stream) -> Result[Void]
  if fflush(stream) != 0
    return error("cannot flush the stream")
  end
  return ok()
end

## True when the descriptor is a terminal.
export def tty?(fd: Int) -> Bool
  return isatty(fd) == 1
end
```

`fopen` is declared `-> Stream`, so the raw call already gives a `Result[Stream]`. The wrapper only replaces its message with one that names the path. `Stream` is exported, so callers can name the type. Callers close the stream with `Native.close`, or the task that owns it frees it when it ends. `fflush` is a `compute def` in the raw layer, and `flush` calls it like any function.

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

## Buffers and block forms

A C function that fills memory its caller gives it, such as `getcwd`, gets an [owned buffer](/library/io-and-system/native/types/#owned-buffers-and-typed-memory). The wrapper makes it with the block form, `Native.memory_pointer(size) do |buf| ... end`, which frees the buffer when the block ends, also when the block returns an error early, and returns the block's value. The block copies out what C wrote, so the caller gets a `String` or a `List` and never sees the buffer.

```agentica {mode="check"}
## The working directory, or an error when it is longer than 4095 bytes.
export def cwd() -> Result[String]
  return Native.memory_pointer(4096) do |buf|
    if Native.null?(getcwd(buf, 4096))
      return error("the working directory is longer than 4095 bytes")
    end
    ok(Native.get_string(buf, 0))
  end
end

extern "libc.so.6"
  def getcwd(buf: C.Pointer, size: C.Int64) -> C.Pointer
end
```

A wrapper may give a resource a block form of its own, as Ruby's `File.open` does: it opens the resource, gives it to the block, closes it when the block ends and returns what the block returned, so the caller cannot forget the close. If the block stops with a runtime error, the end of the task frees the resource.

```agentica {mode="check"}
extern "libc.so.6"
  export resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
end

## Opens a file for appending, gives the stream to the block and closes it when the block ends.
export def append_to(path: String, f: Fn[Stream, Result[Void]]) -> Result[Void]
  stream = try fopen(path, "a")
  done = f.call(stream)
  Native.close(stream)
  return done
end

def main() -> Void
  written = append_to("/tmp/agentica-log.txt") do |stream|
    if fputs("started\n", stream) < 0
      return error("cannot write the log")
    end
    ok()
  end
  IO.inspect(written)
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

## Structs of options

Some libraries take their options as a struct by value, with a function that gives the defaults: llama.cpp has `llama_context_default_params()` and `llama_init_from_model(model, params)`. The raw layer declares the C struct in the block, every field in the order of the header ([C structs](/library/io-and-system/native/types/#c-structs)). The wrapper takes the defaults, sets the fields that the caller chose with `.with`, and passes the record on. The caller sees only a struct of its own, with the options it may set.

```agentica {mode="check"}
export struct ContextOptions
  size: Int = 4096
  threads: Int = 4
end

extern "/opt/infer/libinfer.so"
  export resource Model, free: infer_model_free
  export resource Context, free: infer_free
  struct ContextParams
    n_ctx: C.Int32
    n_batch: C.Int32
    n_threads: C.Int32
    rope_freq_base: C.Float
    embeddings: C.Bool
    offload: C.Bool
    callback_data: C.Pointer
  end
  def infer_context_default_params() -> ContextParams
  compute def infer_init_from_model(model: Model, params: ContextParams) -> Context
end

## A context of the model with the caller's options; the other parameters keep the library's defaults.
export def context(model: Model, options: ContextOptions) -> Result[Context]
  params = infer_context_default_params().with(n_ctx: options.size, n_threads: options.threads)
  case infer_init_from_model(model, params)
    Result.Ok(made) -> return ok(made)
    Result.Err(_) -> return error("cannot make a context of #{options.size} tokens")
  end
end
```

A size that does not fit in a `C.Int32` stops the program at the call (`RUNTIME-INTEGER-OVERFLOW`), so a wrapper that must not stop checks the options first; the example skips that check.

## Tables of function pointers

A library whose API is a struct of function pointers, such as onnxruntime, is wrapped the same way. The raw layer declares each slot that the wrapper uses as a `def` whose first parameter is `fn: C.Function`, and each handle as `resource Name, free: C.Function`, freed through the release slot of the table. The wrapper gets the table once, keeps the slot numbers as constants in the order of the C header, and passes `Native.get_pointer(api, slot * 8)` to the raw `def`s, so the caller never sees a function pointer. A slot number from another version of the header is undefined behavior, like a wrong signature: ask for the version the slots come from, as onnxruntime's `GetApi(version)` does, and turn its NULL into an `error`.

## Shipping it in a package

A package names the library for each system in `[native.NAME]` of its `agentica.toml`. Its `extern` block then opens it with `extern "NAME"`. See [Packages](/tour/modules/#packages) for the form, the lock and the error codes. Document the wrapper file as the API of the package.
