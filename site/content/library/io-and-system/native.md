---
title: Native code
weight: 7
description: Call C functions of a native library with an extern block.
---

An `extern` block names a native library and declares the C functions your program calls from it. Each line is a signature with C types and no body; the function is then called like any other.

```agentica {mode="check"}
extern "libm.so.6"
  ## The cosine of x, in radians.
  export def cos(x: C.Double) -> C.Double

  def labs(n: C.Int64) -> C.Int64
end

def main() -> Void
  puts(cos(0.0))
  puts(labs(-5))
end
```

- Native calls and waits work on Linux x86_64 for now. On other systems a program that declares an extern function or calls a `Native.*` builtin is refused before it runs (`RUNTIME-NATIVE-UNSUPPORTED`, exit 2); `check` and `compile` work everywhere.
- Native code runs with your program's rights, and a wrong signature is undefined behavior in C: declare each function exactly as its C header does.
- Put `##` docs on the `def` lines inside the block.

## Types

| C type | C | In Agentica |
|---|---|---|
| `C.Int` | `int` (32 bits) | `Int` |
| `C.Int64` | `int64_t` | `Int` |
| `C.Double` | `double` | `Float` |
| `C.Bool` | `bool` | `Bool` |
| `C.String` | `const char *` | `String` |
| `C.Pointer` | `void *` | `C.Pointer` |
| `C.Bytes` | `const uint8_t *` (parameters only) | `List[Int]` |

A result may also be `Void`, and a block may declare resources (below). A function takes at most 64 parameters (`PARSE-EXTERN-ARITY`).

- A `C.Int` argument outside 32 bits fails with `RUNTIME-INTEGER-OVERFLOW`, and a `C.String` with a NUL character with `RUNTIME-INVALID-CHARACTER`.
- The C function gets a copy of each string, valid only during the call. A `C.String` result is copied; `NULL` gives `""` for now, and bytes that are not UTF-8 become U+FFFD.
- A `C.Bytes` argument is a list of bytes: C gets a copy, valid only during the call, and an item outside 0 to 255 fails with `RUNTIME-INVALID-NUMBER`. Pass the length as a parameter of its own. A `C.Bytes` result is `PARSE-EXTERN-TYPE`.
- A `C.Pointer` is a C pointer that your program passes back to C. It may be NULL: `Native.null()` makes one and `Native.null?(p)` tests it. Pointers have no `==`, and `IO.inspect` prints `<C.Pointer>`.

## Resources

A resource is a C pointer that your program owns, such as an open stream or a database connection. `resource Name, free: c_function` in the block declares its type and the C function, in the same library, that frees it, as `void c_function(void *)`.

```agentica {mode="check"}
extern "libc.so.6"
  ## A C stream.
  resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int
end

def main() -> Void
  stream = fopen("/tmp/agentica-native.txt", "w").unwrap!
  fputs("hello\n", stream)
  Native.close(stream)
  IO.inspect(fopen("/no/such/dir/file", "r"))   # error("fopen returned NULL")
end
```

- A function declared `-> Stream` gives a `Result[Stream]`: a NULL result is `error("fopen returned NULL")`, anything else is `ok` with a resource that the calling task owns.
- `Native.close(stream)` runs the free function once and closes the resource; closing it again does nothing. A call that takes a closed resource fails with `RUNTIME-NATIVE-CLOSED`.
- A resource the task did not close is freed when the task ends (return, crash or cancel), like a file. `Task.spawn_owning(&work, stream)` hands it to the new task. When `main` returns, the program ends without freeing what is still open.
- A `compute def` call keeps its resource arguments until it returns: if the resource is closed meanwhile, or its task is cancelled, the free runs when the call ends.
- Every resource result is a new pointer that your program owns. A function that returns a pointer its library keeps (a borrowed one) must be declared `-> C.Pointer`, or the pointer is freed twice. The free function cannot also be declared with `def` in its block (`PARSE-EXTERN-FREE`).
- A resource is a type: `export resource` makes it importable, and its lines come before the functions that use it. Resources and `C.Pointer` do not convert into each other. `IO.inspect` prints `<Stream>`; a resource has no `to_s` and no JSON.

## The block

- The library is a plain string: a name without `/` (`"libm.so.6"`), which the system looks up, or an absolute path (`"/opt/tool/libtool.so"`). Anything else is `PARSE-EXTERN-LIBRARY`.
- The library opens at the first call of one of its functions and stays open. A library, dependency or function that is not found fails that call with `RUNTIME-NATIVE-LOAD`.
- Names are C names, without `?` or `!` (`PARSE-EXTERN-NAME`); parameters take no default (`PARSE-EXTERN-DEFAULT`); only the types above and the block's resources cross (`PARSE-EXTERN-TYPE`).
- `export def` makes a function importable from other files. The functions take the place of `def` functions in the declaration order, and resources the place of types.
- `extern` is a keyword only at the start of a top-level declaration, and `resource` only at the start of a line of the block; elsewhere they are ordinary names.

## Running

- A `def` call blocks timers, I/O and other tasks until it returns, so keep such calls short, and use `compute def` for the long ones. `--max-steps` cannot stop a call in the middle.
- Native code must retry calls cut short by `EINTR`: GC signals can interrupt sleeps and polls.
- Native code is allowed by default and can start programs itself. `agentica --deny-native file.agc` (or any `--deny-*` flag) refuses a program that declares any extern function or calls a `Native.*` builtin before anything runs (`RUNTIME-NATIVE-DENIED`, exit 2). Under `agentica test`, such a test file is a file error with that code.

## Compute calls

A function declared with `compute def` runs on the VM's compute pool, one thread per scheduler, and the calling task waits while the other tasks go on. Use it for a call that may take long: a query, a compression, a model step.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  ## Sleeps for ms milliseconds off the scheduler.
  compute def sqlite3_sleep(ms: C.Int) -> C.Int
end

def main() -> Void
  sleeper = Task.spawn(&sqlite3_sleep, 200)
  puts("main goes on")
  puts(Task.await(sleeper))
end
```

- The result is the plain C value, as for `def`. Write `export compute def` to export one.
- Nothing stops a compute call in the middle: it has no timeout, and `--max-steps` does not end it. For a limit, run the call in a task and use `Task.await(task, ms)`. A cancel skips a call that has not started; a running call runs on, the cancelled task stops waiting at once, and the result is dropped. The program does not wait for a running call at the end.
- A call that never returns holds a pool thread for the rest of the run. Once `--schedulers` such calls are stuck, every later compute call waits.
- The arguments are copied before the call and a `C.String` result as it returns. The function runs on another thread, so it must be safe to call from one.

## Waiting on a descriptor

Many C network libraries (libpq, curl multi, hiredis) have a non-blocking mode: the library says which socket it waits for, and your program waits. `Native.wait_readable(fd, timeout_ms)` and `Native.wait_writable(fd, timeout_ms)` park the task until the descriptor can be read or written, while the other tasks go on. Both give a `Result[Void]`.

```agentica {mode="check"}
extern "libc.so.6"
  def eventfd(initval: C.Int, flags: C.Int) -> C.Int
  def eventfd_write(fd: C.Int, value: C.Int64) -> C.Int
end

def ring(fd: Int) -> Int
  Task.sleep(50)
  return eventfd_write(fd, 1)
end

def main() -> Void
  fd = eventfd(0, 0)
  bell = Task.spawn(&ring, fd)
  puts(Native.wait_readable(fd, 1_000))   # ok() once the other task writes
  puts(Task.await(bell))
end
```

A library's connect loop waits the same way, with `try Native.wait_readable(socket, 5_000)` between its polls.

- After `timeout_ms` (positive) the result is `error("native: timed out")`. A timeout that is not positive, a negative descriptor, and one that cannot be polled (closed, a regular file, `/dev/null`) give an error that starts with `native: `.
- An error or a hang-up on the descriptor ends the wait with `ok`, as `poll(2)` does: the library's next call reports it.
- The wait watches a new open of the descriptor's file, so the library keeps its descriptor and its flags, and two tasks may wait on one descriptor. A socket, or a file that cannot be opened again (an eventfd), is watched through a duplicate, which puts the descriptor in non-blocking mode.
- If the library closes the descriptor during a wait, the wait goes on and ends at its timeout (`native: timed out`) unless the file becomes ready.
- A cancel stops the wait; the end of the program does not wait for it.
- `--deny-native` refuses a program that calls them, as it refuses extern functions: a descriptor comes from native code.
