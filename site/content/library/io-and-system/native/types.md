---
title: Types and resources
weight: 1
description: The C types of an extern block, variadic functions, reading memory that C returns, owned buffers and typed memory, resources that own a C pointer, out parameters, calls through C function pointers, callbacks that C calls, and C structs passed by value or through a pointer.
---

## Types

| C type | C | In Agentica |
|---|---|---|
| `C.Int8`, `C.Int16`, `C.Int32`, `C.Int64` | `int8_t` to `int64_t` (`signed char`, `short`, `int`, a 64-bit integer) | `Int` |
| `C.UInt8`, `C.UInt16`, `C.UInt32` | `uint8_t` to `uint32_t` (`unsigned char`, `unsigned short`, `unsigned int`) | `Int`, never negative |
| `C.Long` | `long`: 32 bits on Windows, 64 on Linux and macOS | `Int` |
| `C.Double` | `double` | `Float` |
| `C.Float` | `float` (32 bits) | `Float` |
| `C.Bool` | `bool` | `Bool` |
| `C.String` | `const char *` | `String` |
| `C.Pointer` | `void *` | `C.Pointer` |
| `C.Bytes` | `const uint8_t *` (parameters only) | `Bytes` |
| `C.Function` | a function pointer (the first or the last parameter only, [below](#function-pointers)) | `C.Pointer` |
| a `struct` of the block | a struct passed by value ([below](#c-structs)) | that struct |

`C.Int` is `PARSE-EXTERN-TYPE`: write the width (`C.Int32` or `C.Int64`), or `C.Long` for a C `long`. A result may be `Void`, a block may declare resources, and a parameter may be an out parameter (below). A function takes at most 64 parameters (`PARSE-EXTERN-ARITY`).

- An integer argument takes the bits of its type, read as signed or unsigned, as `Native.put_int8` to `put_int32` do: a `C.Int8` or `C.UInt8` takes -128 to 255, a `C.Int32` or `C.UInt32` -2^31 to 2^32 - 1 (a `C.Long` the same on Windows, any `Int` elsewhere). C gets the low bits, so `-1` is the `C.UInt32` 4294967295. A value outside fails with `RUNTIME-INTEGER-OVERFLOW`, and a `C.String` with a NUL character with `RUNTIME-INVALID-CHARACTER`. For text with a NUL or a known length, use `Native.from_string` and `bytesize` (below).
- A signed integer result is sign-extended and an unsigned one zero-extended: a `C.UInt32` above 2^31 is a positive `Int`. There is no unsigned 64-bit type: declare `uint64_t` or `size_t` as `C.Int64`, and `unsigned long` as `C.Long`. The same bits cross, so a value above the signed maximum reads as negative, as `std/binary`'s `read_i64` reads it.
- A `C.Float` argument is rounded to the nearest 32-bit float (one outside its range becomes an infinity). A `C.Float` result is widened to a `Float` (`0.1` comes back as `0.10000000149011612`).
- C gets a copy of each string, valid only during the call. A `C.String` result is copied; `NULL` gives `""`, and bytes that are not UTF-8 become U+FFFD. When NULL matters, declare the result `-> C.Pointer` and read it with `Native.get_string` (below).
- A `C.Bytes` argument is a `Bytes`: C gets a copy, valid only during the call. Pass the length (`b.size`) as a parameter of its own. A `C.Bytes` result is `PARSE-EXTERN-TYPE`.
- A `C.Pointer` is a C pointer that your program passes back to C. It may be NULL: `Native.null()` makes one and `Native.null?(p)` tests it. Pointers have no `==`, and `IO.inspect` prints `<C.Pointer>`.

## Variadic functions and C names

A variadic C function, such as `int open(const char *path, int flags, ...)`, is declared with `...` where its variadic part starts, followed by the C type of each argument your calls pass. A string after the result gives the C name when it differs from the `def` name, so one C function can be declared in several shapes:

```agentica {mode="check"}
extern "libc.so.6"
  def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
  def fcntl_get(fd: C.Int32, cmd: C.Int32, ...) -> C.Int32 = "fcntl"
  def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  def close(fd: C.Int32) -> C.Int32
end

def main() -> Void
  fd = open("/tmp/agentica-native.txt", 65, 384)   # O_WRONLY | O_CREAT on Linux, mode 0600
  fcntl_set(fd, 2, 1)                                # F_SETFD, FD_CLOEXEC
  puts(fcntl_get(fd, 1))                             # F_GETFD: 1
  close(fd)
end
```

- `...` comes after at least one C parameter, not counting a `C.Function` (`PARSE-EXTERN-VARIADIC-FIXED`). It appears once, and only in an extern block (`PARSE-EXTERN-VARIADIC`). The variadic part may be empty; the 64 parameters count both parts.
- A variadic parameter is `C.Int32`, `C.Int64`, `C.UInt32`, `C.Long`, `C.Double`, `C.String`, `C.Pointer`, `C.Bytes` or a resource. `C.Bool`, `C.Int8`, `C.Int16`, `C.UInt8`, `C.UInt16` and `C.Float` are `PARSE-EXTERN-VARIADIC-TYPE`, as C promotes them to `int` and `double`: write `C.Int32` or `C.Double`. An out parameter there is `PARSE-EXTERN-VARIADIC-TYPE` too.
- The C name is a plain string of letters, digits and `_` (`PARSE-EXTERN-SYMBOL`).
- The call follows each system's variadic C ABI, which differs from a fixed signature: on Apple arm64 the variadic arguments go on the stack, and on Windows x64 a variadic `double` goes in an integer register too (libffi's `ffi_prep_cif_var`). Declare a variadic function with `...`, never as a fixed one.

## Reading memory that C returns

A function that returns a pointer and a length, or text that may be NULL, is declared `-> C.Pointer`, and your program copies the memory:

- `Native.get_string(p, offset)` copies the NUL-terminated text that starts `offset` bytes past `p`. `Native.get_string(p, offset, length)` copies exactly `length` bytes, NUL bytes included. Bytes that are not UTF-8 become U+FFFD.
- `Native.get_bytes(p, offset, length)` copies `length` bytes into a `Bytes`.
- A NULL `p` with length 0 reads as `""` or `[]`, as C means it (SQLite gives NULL for an empty blob). Any other NULL `p` fails with `RUNTIME-NATIVE-NULL`, so test it with `Native.null?(p)` first. A negative length fails with `RUNTIME-INVALID-COUNT`, after the pointer is checked. A length past the memory C owns is undefined behavior, like a wrong signature: Agentica does not check it.
- `Native.pointer(n)` is the pointer with the integer value `n`, for sentinels such as `SQLITE_TRANSIENT`, which is `Native.pointer(-1)`.
- `Native.address(p)` is the integer value of `p`. Pointers have no `==`, so compare addresses, or subtract two pointers into one block for the bytes between them: SQLite's `pzTail` minus the SQL text is how much it read. The address of a freed buffer fails with `RUNTIME-NATIVE-CLOSED`.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_exec(db: Db, sql: C.String, callback: C.Pointer, arg: C.Pointer, out errmsg: C.Pointer) -> C.Int32
  def sqlite3_free(p: C.Pointer) -> Void
end

def main() -> Void
  db = sqlite3_open(":memory:").db
  failed = sqlite3_exec(db, "select from nowhere", Native.null(), Native.null())
  if !Native.null?(failed.errmsg)
    puts(Native.get_string(failed.errmsg, 0))   # near "from": syntax error
    sqlite3_free(failed.errmsg)
  end

  Native.close(db)
end
```

## Owned buffers and typed memory

A C function that writes into memory the caller gives it, such as `char *getcwd(char *buf, size_t size)`, or that reads an array of floats, gets an owned buffer. `Native.memory_pointer(size)` allocates `size` zeroed bytes and gives them as a `C.Pointer`, so the buffer goes wherever a `C.Pointer` parameter is:

```agentica {mode="check"}
extern "libc.so.6"
  def getcwd(buf: C.Pointer, size: C.Int64) -> C.Pointer
end

def main() -> Void
  Native.memory_pointer(4096) do |buf|
    if !Native.null?(getcwd(buf, 4096))
      puts(Native.get_string(buf, 0))
    end
  end
end
```

- The block form, `Native.memory_pointer(size) do |buf| ... end`, gives the buffer to the block and frees it when the block ends, also when the block ends early with an error that `try` returns. The call returns the block's value. A runtime error in the block stops the task, and the task's end frees the buffer. A buffer that the block hands to another task with `Task.spawn_owning` is not freed at the block's end: its new owner frees it.
- The plain form, `buf = Native.memory_pointer(size)`, is for a buffer that outlives one block, such as one that C keeps between calls. A buffer that is never freed lives until its task ends, so a loop that makes buffers without freeing them grows. Free each one when C is done with it.
- The calling task owns a plain buffer like a resource: `Native.free(buf)` frees it once (freeing it again does nothing), and the task's end frees what it did not free. `free` ends a buffer as `Native.close` ends a resource. The end of the run frees a buffer still open, as it frees a resource (below).
- `Task.spawn_owning(&work, buf)` hands the buffer to the new task, whose end then frees it. Sending it on a channel or returning it from a task does not move it: it is still freed when its owner ends. A negative size, a size the system cannot give and any size above 256 TiB (2^48 bytes) fail with `RUNTIME-INVALID-COUNT`.
- A `compute def` call keeps its buffer arguments until it returns, so a free meanwhile waits for the call. Reading or writing the buffer while such a call runs races with C: wait for the call first.
- A freed buffer fails every later read, write or call with `RUNTIME-NATIVE-CLOSED`, and `Native.closed?(buf)` is `true`. A `C.Pointer` that C gave is never closed (NULL included: test it with `Native.null?`). `Native.free` of a pointer that C gave fails with `RUNTIME-NATIVE-NOT-OWNED`: free it with its library's function.
- The names follow the Ruby `ffi` gem (`FFI::MemoryPointer.new(size)` and its block form, `MemoryPointer.from_string(text)`, `get_int32(offset)`, `get_string(offset)`, `put_array_of_float32(offset, values)`), as `Native.*` functions that take the pointer first.

A C function that takes text with its length, such as `sqlite3_bind_text`, `PQexecParams` or `mysql_real_query`, gets a buffer of `Native.from_string(text)` (Ruby ffi's `MemoryPointer.from_string`) and `text.bytesize`. The buffer holds the UTF-8 bytes of the text and a NUL after them, so its size is `text.bytesize + 1`. A NUL inside the text is copied like any other byte, which a `C.String` refuses. A pointer that C returns into the text, such as SQLite's `pzTail`, stays valid while the buffer lives: `Native.address(tail) - Native.address(buf)` is how many bytes C read. It is an owned buffer like the others, with the same block form and rules.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_prepare_v2(db: Db, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt, out tail: C.Pointer) -> C.Int32
end

def main() -> Void
  db = sqlite3_open(":memory:").db
  sql = "SELECT 1; SELECT 2"
  Native.from_string(sql) do |buf|
    prepared = sqlite3_prepare_v2(db, buf, sql.bytesize)
    puts(Native.address(prepared.tail) - Native.address(buf))
    Native.close(prepared.stmt)
  end

  Native.close(db)
end
```

Typed reads and writes take a byte offset past any `C.Pointer`, a buffer or one that C returned. The offset need not be aligned:

| Read | Write | Item |
|---|---|---|
| `Native.get_int8(p, offset)`, `get_int16`, `get_int32`, `get_int64` | `Native.put_int8(p, offset, value)`, `put_int16`, `put_int32`, `put_int64` | signed integer, `Int` |
| `Native.get_uint8(p, offset)`, `get_uint16`, `get_uint32` | the `put_int` forms | unsigned integer, `Int` |
| `Native.get_float32(p, offset)`, `get_float64` | `Native.put_float32(p, offset, value)`, `put_float64` | `float` or `double`, `Float` |
| `Native.get_pointer(p, offset)` | `Native.put_pointer(p, offset, value)` | `void *`, `C.Pointer` |
| `Native.get_array_of_int32(p, offset, count)`, `_int64`, `_float32`, `_float64` | `Native.put_array_of_int32(p, offset, values)`, `_int64`, `_float32`, `_float64` | a `List[Int]` or `List[Float]` |
| `Native.get_string(p, offset)` (above) | `Native.put_string(p, offset, text)` | text and a NUL, a C string |
| `Native.get_bytes(p, offset, length)` (above) | `Native.put_bytes(p, offset, bytes)` | a `Bytes` |

- A `put_int` form takes a value that fits its bits, read as signed or unsigned: `put_int8` takes -128 to 255. Any other value fails with `RUNTIME-INTEGER-OVERFLOW`. A `put_array_of_*` checks every item before it writes the first.
- `put_string` writes the bytes of the text and a NUL after them; a NUL in the text fails with `RUNTIME-INVALID-CHARACTER`. Owned C strings and an array of pointers to them (`const char *const *`) are buffers too. `put_pointer` stores an address that nothing tracks: keep the buffer it points to unfreed while C uses it.

```agentica {mode="check"}
extern "/opt/model/libmodel.so"
  def model_inputs(names: C.Pointer, count: C.Int64, data: C.Pointer) -> C.Int32
end

def main() -> Void
  name = Native.memory_pointer(6)
  Native.put_string(name, 0, "input")
  names = Native.memory_pointer(8)
  Native.put_pointer(names, 0, name)
  data = Native.memory_pointer(4 * 3)
  Native.put_array_of_float32(data, 0, [0.5, 1.5, 2.5])
  puts(model_inputs(names, 1, data))
  puts(Native.get_array_of_float32(data, 0, 3))
end
```

- A buffer knows its size: a read or write that starts before it or runs past its end fails with `RUNTIME-NATIVE-BOUNDS`, and so does `Native.get_string` of a buffer with no NUL after the offset. Nothing outside the buffer is ever read or written.
- A pointer that C returned has no size. A NULL one fails with `RUNTIME-NATIVE-NULL` (an array or `get_bytes` of count 0 is empty), and a negative offset with `RUNTIME-NATIVE-BOUNDS`. Any other offset is trusted. Memory past what C owns is undefined behavior, like a wrong signature: take the size from the library. Two tasks that read and write the same memory of C at once race, as in C; each read or write of an owned buffer holds a lock.
- A negative count or size fails with `RUNTIME-INVALID-COUNT`.

`Native.offset(p, n)` is the pointer `n` bytes past `p`, for C structs whose fields point into one block, such as the `length`, `is_null` and `buffer` cells of a MySQL bind:

- For a pointer that C returned it is the plain sum (wrapping on overflow), trusted like `p`.
- For an owned buffer it is a view of the same memory from byte `n` to the buffer's end. `n` outside 0 to the size fails with `RUNTIME-NATIVE-BOUNDS`, and reads and writes through the view are checked against its range. A view of a view takes its offset from the view and ends where the buffer ends.
- The view belongs to its buffer: freeing the buffer closes it (`RUNTIME-NATIVE-CLOSED`, `Native.closed?` is `true`). A `compute def` call that takes the view keeps the buffer until it returns. `Native.free` of a view fails with `RUNTIME-NATIVE-NOT-OWNED`, and `Task.spawn_owning` hands over the buffer, not a view.

```agentica {mode="check"}
extern "/opt/db/libdb.so"
  def db_bind(length: C.Pointer, is_null: C.Pointer, data: C.Pointer) -> C.Int32
end

def main() -> Void
  Native.memory_pointer(16 + 8) do |bind|
    Native.put_int64(bind, 0, 5)
    Native.put_string(bind, 16, "hello")
    puts(db_bind(bind, Native.offset(bind, 8), Native.offset(bind, 16)))
  end
end
```

## Resources

A resource is a C pointer that your program owns, such as an open stream or a database connection. `resource Name, free: c_function` in the block declares its type and the C function, in the same library, that frees it, as `void c_function(void *)`. On Windows `GetProcAddress` searches only the exports of that DLL, so `free: free` (a function of a dependency such as the C runtime) is `RUNTIME-NATIVE-LOAD` there, although Linux and macOS find it: declare the free function from the library that exports it. The name is as in C and may start with a capital letter, such as `PQfinish` or `SSL_free`; only the dotted `C.Function` (below) is read as a type.

`resource Name, free_ref: c_function` declares a resource whose free function takes a reference to the pointer (its address, as Ruby's `Fiddle::Pointer#ref` gives), as `void c_function(void **)`. `duckdb_close` and `duckdb_disconnect` are such functions. Each free passes that address, once, and the function may write NULL there. A resource has one free function: `free:` and `free_ref:` together are `PARSE-EXTERN-FREE`.

```agentica {mode="check"}
extern "libc.so.6"
  ## A C stream.
  resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
end

def main() -> Void
  stream = fopen("/tmp/agentica-native.txt", "w").unwrap!
  fputs("hello\n", stream)
  Native.close(stream)
  IO.inspect(fopen("/no/such/dir/file", "r"))   # error("fopen returned NULL")
end
```

- A function declared `-> Stream` gives a `Result[Stream]`: a NULL result is `error("fopen returned NULL")`, anything else is `ok` with a resource that the calling task owns.
- `Native.close(stream)` runs the free function once and closes the resource; closing it again does nothing. A call that takes a closed resource fails with `RUNTIME-NATIVE-CLOSED`, before any argument is copied.
- `Native.closed?(stream)` never stops the task, so a wrapper can return an `error` instead. It is `true` after `Native.close` (in any task), after the end of the task that owned the resource (also a task that returned it), and for a NULL out resource. It is `false` for a live one, also while a `compute def` call holds it; closed during that call, it is `true` at once. `true` is final; `false` can be out of date at once if another task may close the resource.
- A resource the task did not close is freed when the task ends (return, crash or cancel), like a file. `Task.spawn_owning(&work, stream)` hands it to the new task.
- A `compute def` call keeps its resource arguments until it returns: if the resource is closed meanwhile, or its task is cancelled, the free runs when the call ends.
- Any task may pass a resource or an owned buffer to C, for instance one it got through a closure or a channel: nothing checks who owns it. Only the owner's end frees it, and `Native.close` or `Native.free` by any task closes it for all. Two tasks inside C on the same object at once race, as in C; `sqlite3_interrupt` or `duckdb_interrupt` from another task is the intended use.
- A free function that blocks (`mysql_close`, a `duckdb_close` that checkpoints) runs on the scheduler at `Native.close` or at the owner's end, like a `def` call, and stalls the other tasks.
- Each owner frees its resources newest first. A parent handed to another task with `Task.spawn_owning` may be freed before its children: close the children first, or keep a parent and its children in one task.
- When the run ends (`main` returns, `System.exit`, a crash of `main`, the step limit, or the first `SIGINT`, `SIGTERM` or `SIGHUP`), a compute call that has not started is never made, child programs stop, files are written, and the run waits for the running `compute def` calls that hold a resource. Then every resource and buffer still open is freed, newest first (the reverse of opening), whatever task owns it. The frees stop at the first resource that a running call still holds and never skip past it, so that one and all older ones stay unfreed. So `stream` above keeps what `fputs` wrote even without `Native.close`. A resource that such a call returns at that point is never freed.
- After a signal the run does not wait for those calls, and what they hold is not freed. The wait and the frees share the file flush limit (30 seconds, `--flush-timeout MS`): a call or a free function that takes longer is left behind, the exit code stays, and stderr gets one line saying native resources may not be freed. With `--flush-timeout 0` nothing is freed. A second signal ends the run at once.
- Every resource result is a new pointer that your program owns. A function that returns a pointer its library keeps (a borrowed one) must be declared `-> C.Pointer`, or the pointer is freed twice. The free function cannot also be declared with `def` in its block (`PARSE-EXTERN-FREE`); the check is per block, so do not declare it in another block either.
- A resource is a type: `export resource` makes it importable, and its lines come before the functions that use it. Resources and `C.Pointer` do not convert into each other. `IO.inspect` prints `<Stream>`; a resource has no `to_s` and no JSON.

## Out parameters

A C function that gives a value through a pointer, such as `int sqlite3_open(const char *filename, sqlite3 **db)`, declares that parameter with `out`. The caller does not pass it: C writes into a slot that is zeroed before the call, and the call returns a record with the C result as `result` and one field per out parameter, named after it.

- The record is a struct named after the function in CamelCase (`sqlite3_open` gives `Sqlite3Open`), exported with its function. A `Void` function's record has no `result`.
- An out parameter is an integer type, `C.Double`, `C.Float`, `C.Bool`, `C.Pointer` or a resource of the block; anything else is `PARSE-EXTERN-OUT`. For a `char **`, use an out `C.Pointer`.
- An out resource is the resource itself, not a `Result`. When C wrote a pointer, the calling task owns it, as for a resource result. When C wrote NULL or left the slot alone, it is a resource that is closed already: nothing frees it, `Native.close` does nothing, and a call with it fails with `RUNTIME-NATIVE-CLOSED`. Check `result` before you use it, or `Native.closed?`: `sqlite3_prepare_v2` gives `SQLITE_OK` and a NULL statement for SQL that is only a comment.
- A cancelled `compute def` call drops its record; an out resource that C made is freed when the call returns.

## Function pointers

Some libraries give their functions as a table of C function pointers, not by name: onnxruntime's `OrtGetApiBase()->GetApi(version)` gives the `OrtApi` struct, and every call is `api->CreateEnv(...)`. A `def` whose first parameter is `fn: C.Function` calls the function at that address, with the signature the `def` declares (Ruby ffi's `FFI::Function.new(ret, params, pointer)`). Read the address from the table with `Native.get_pointer`. A pointer is 8 bytes on every system with native calls.

```agentica {mode="check"}
# The slots of struct plugin_api in plugin.h, in order.
OPEN = 0
READ = 1
CLOSE = 2

extern "/opt/plugin/libplugin.so"
  ## A handle that the close slot of the table frees.
  resource Handle, free: C.Function
  def plugin_api(version: C.Int32) -> C.Pointer
  def open(fn: C.Function, path: C.String, out handle: Handle, free: C.Function) -> C.Int32
  compute def read(fn: C.Function, handle: Handle, buf: C.Pointer, size: C.Int64) -> C.Int64
end

def slot(api: C.Pointer, index: Int) -> C.Pointer
  return Native.get_pointer(api, index * 8)
end

def main() -> Void
  api = plugin_api(1)
  opened = open(slot(api, OPEN), "/tmp/data", slot(api, CLOSE))
  if opened.result == 0
    Native.memory_pointer(64) do |buf|
      puts(read(slot(api, READ), opened.handle, buf, 64))
    end

    Native.close(opened.handle)   # calls the close slot once
  end
end
```

- The other parameters, the result, out parameters, resources and `compute def` work as for a function found by name. The `def` has no C name: `= "symbol"` is `PARSE-EXTERN-FUNCTION`.
- `resource Name, free: C.Function` declares a resource whose free function is a function pointer too, such as `api->ReleaseSession`. The `def` that makes one, as its result or an out parameter, takes that address as its last parameter, after any `out` parameters: `free: C.Function`. A sole `C.Function` parameter of a `def` that returns such a resource is its free function, not the function to call: `def thing_new(free: C.Function) -> Thing` calls `thing_new` by name (a call through a pointer that makes one takes two `C.Function` parameters). `Native.close`, the end of the owning task and a dropped `compute def` result call it once, as for a free function found by name. One call makes one such resource at most.
- A `C.Function` is the first parameter (the function to call) or the last (the free function). Anywhere else it is `PARSE-EXTERN-FUNCTION`. It is never a result, an out parameter or a variadic parameter. The program sees it as a `C.Pointer`. The parameter names are free: `fn` and `free` are a convention.
- A NULL address fails the call with `RUNTIME-NATIVE-NULL` before C runs, and an owned buffer with `RUNTIME-NATIVE-BOUNDS`. Any other address is trusted: one that is not a function of the declared signature is undefined behavior, like a wrong signature.
- An extern block whose functions are all called through a pointer never opens its library, so a wrong library path is not reported.

## Callbacks

Some C functions take a function of yours that they call back: `qsort` a comparison, SQLite a collation or an update hook. `callback Name(params) -> result` in the block declares the C type of that function pointer (Ruby ffi's `callback`), and `Native.callback(Name, &function)` makes one from a function of your program:

```agentica {mode="check"}
extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  callback Compare(arg: C.Pointer, a_len: C.Int32, a: C.Pointer, b_len: C.Int32, b: C.Pointer) -> C.Int32
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_create_collation(db: Db, name: C.String, enc: C.Int32, arg: C.Pointer, cmp: Compare) -> C.Int32
end

def by_length(arg: C.Pointer, a_len: Int, a: C.Pointer, b_len: Int, b: C.Pointer) -> Int
  return a_len - b_len
end

def main() -> Void
  db = sqlite3_open(":memory:").db
  cmp = Native.callback(Compare, &by_length)
  puts(sqlite3_create_collation(db, "by_length", 1, Native.null(), cmp))
  Native.close(db)
  Native.close(cmp)
end
```

- A callback takes an integer type, `C.Double`, `C.Float`, `C.Bool`, `C.String` or `C.Pointer`, and returns one of them but `C.String`, or `Void`. Anything else is `PARSE-EXTERN-TYPE`: take a struct, an array or bytes as a `C.Pointer` and read it with `Native.get_*`. It has no default, no `out` parameter and no `...`.
- The function is named with `&` and takes and returns the Agentica types of the callback (`C.Int32` is `Int`); anything else is `CHECK-TYPE-MISMATCH`. An `Fn` value is `CHECK-NATIVE-CALLBACK`, and a block is refused too, because they may hold values of their scope. Pass the context through the `void *` user data argument that C libraries give for it.
- The callback is a resource of its type: `Native.close`, `Native.closed?` and `Task.spawn_owning` take it, and it does not convert to or from a `C.Pointer`.
- A `def` of the block takes the callback as a parameter of its type, also in the variadic part. It is not a result or an `out` parameter. For a function pointer that may be NULL, such as the step function of a scalar SQLite function, declare the C function a second time under another name with a `C.Pointer` parameter there, and pass `Native.null()`.
- The VM does not make callbacks yet: a program that calls `Native.callback` is refused at load with `RUNTIME-NATIVE-UNSUPPORTED`, exit 2, on every system. `check` and `compile` accept it.

## C structs

A C function that takes or returns a struct by value, such as llama.cpp's `llama_context_default_params()`, needs the struct declared with `struct` inside the block, its fields in the order of the C header (Ruby ffi's `FFI::Struct` with `layout`). Your program sees an ordinary struct: build one, read its fields, change one with `.with`. A call copies it into C memory, and a struct result is copied back into a new record.

```agentica {mode="check"}
extern "/opt/geo/libgeo.so"
  struct Point
    x: C.Double
    y: C.Double
  end

  struct Shape
    origin: Point
    sides: C.Int32
    scale: C.Float = 1.0
    filled: C.Bool
    tag: C.Pointer
  end

  def geo_default_shape() -> Shape
  def geo_area(shape: Shape) -> C.Double
  compute def geo_grow(shape: Shape, by: C.Double) -> Shape
end

def main() -> Void
  shape = geo_default_shape()
  bigger = shape.with(sides: 6, origin: shape.origin.with(x: 2.5))
  puts(geo_area(bigger))
  puts(geo_grow(bigger, 2.0).scale)
  puts(geo_area(Shape(origin: Point(x: 0.0, y: 0.0), sides: 3, filled: true, tag: Native.null())))
end
```

- A field is an integer type, `C.Double`, `C.Float`, `C.Bool`, `C.Pointer` or a struct declared above in the same block. Your program sees `Int`, `Float`, `Bool`, `C.Pointer` or that struct. Anything else is `PARSE-EXTERN-TYPE`: `C.String`, `C.Bytes`, `C.Function` and resources would not survive the copy. Declare a `char *` field as `C.Pointer` and read its text with `Native.get_string`. A fixed array field (`char name[16]`) cannot be declared yet.
- The struct is laid out as the system's C compiler lays it out, padding included. Declare every field of the header, in its order: a wrong field list is undefined behavior, like a wrong signature. A struct has one field at least (`PARSE-EXTERN-TYPE`) and at most 1024, nested ones counted, in at most 16 levels (`PARSE-EXTERN-ARITY`).
- A struct is a parameter or a result, also of a `compute def` and of a call through a function pointer. It is not an out parameter (`PARSE-EXTERN-OUT`; for a struct that C fills, pass a `C.Pointer` to an owned buffer and read it with `Native.get_struct`, [below](#structs-through-pointers)) or a variadic parameter (`PARSE-EXTERN-VARIADIC-TYPE`).
- Each field of an argument is checked as an argument is, before C runs: an integer outside the bits of its type fails with `RUNTIME-INTEGER-OVERFLOW`, a `C.Float` is rounded, and a freed owned buffer in a `C.Pointer` field fails with `RUNTIME-NATIVE-CLOSED`. A `C.Bool` field of a result is `true` when its byte is not 0.
- A `C.Pointer` field is an address that nothing tracks: the memory it names must outlive C's use. A `compute def` call holds the owned buffers in the fields of its struct arguments until it returns, as it holds its buffer arguments.
- The struct is a type of the block, used after its declaration (`PARSE-EXTERN-TYPE` before). `export struct` makes it importable. Field defaults work as in any struct. A block that declares a struct takes the place of types as a whole, as a block with a resource does.

### Structs through pointers

A C struct that sits in memory, such as an array of MySQL binds or the result that `duckdb_query` fills, is read and written with the struct of the block (Ruby ffi's `Struct.size` and `Struct.new(pointer)`):

- `Native.size_of(Name)` is the size of the struct in bytes, as C's `sizeof` gives it on this system, padding included: a `C.Long` field makes it differ between Windows and the others. Item `k` of a C array of structs is at `k * Native.size_of(Name)`.
- `Native.get_struct(p, offset, Name)` reads the struct at `offset` bytes past `p` into a new record, as a struct result is read.
- `Native.put_struct(p, offset, value)` writes the record there, as a struct argument is written. Every field is checked before the first byte is written: an integer outside its bits fails with `RUNTIME-INTEGER-OVERFLOW`, a freed buffer in a `C.Pointer` field with `RUNTIME-NATIVE-CLOSED`. A buffer stored in a `C.Pointer` field is an address that nothing tracks, as with `put_pointer`.
- The bounds are those of the typed reads and writes above, for the size of the struct: checked in an owned buffer or a view, trusted at a pointer that C returned.
- The type is a struct of an extern block, or a type alias of one. Any other type, or a value in place of the type name, is `CHECK-TYPE-MISMATCH`.

```agentica {mode="check"}
extern "/opt/db/libdb.so"
  struct Bind
    buffer: C.Pointer
    length: C.Long
    is_null: C.Bool
  end

  def db_bind_params(binds: C.Pointer, count: C.Int32) -> C.Int32
end

def main() -> Void
  size = Native.size_of(Bind)
  Native.memory_pointer(2 * size) do |binds|
    Native.memory_pointer(8) do |text|
      Native.put_string(text, 0, "hello")
      Native.put_struct(binds, 0, Bind(buffer: text, length: 5, is_null: false))
      Native.put_struct(binds, size, Bind(buffer: Native.null(), length: 0, is_null: true))
      puts(db_bind_params(binds, 2))
      puts(Native.get_struct(binds, size, Bind).is_null)
    end
  end
end
```
