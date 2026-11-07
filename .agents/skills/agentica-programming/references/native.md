# Native code

An `extern` block declares C functions of a native library. Each line is a
signature with C types and no body; call the function like any `def`.

~~~ruby
extern "libm.so.6"
  ## The cosine of x.
  export def cos(x: C.Double) -> C.Double

  def labs(n: C.Long) -> C.Long
end
~~~

- Types: the integers `C.Int8`, `C.Int16`, `C.Int32`, `C.Int64`, `C.UInt8`,
  `C.UInt16`, `C.UInt32` and `C.Long` (C `long`: 32 bits on Windows, 64
  elsewhere), each an `Int`; `C.Double` (`Float`), `C.Float` (32-bit `float`, a
  `Float`, rounded; out of range is an infinity), `C.Bool` (`Bool`), `C.String`
  (`const char *`, a `String`); a result may be `Void`. Anything else (`C.Int`
  too: write the width) is `PARSE-EXTERN-TYPE`; more than 64 parameters
  `PARSE-EXTERN-ARITY`; a name with `?` or `!` `PARSE-EXTERN-NAME`; a default
  `PARSE-EXTERN-DEFAULT`. `##` docs go on the `def` lines.
- The library is a plain string: a name without `/` (the system looks it up) or
  an absolute path, else `PARSE-EXTERN-LIBRARY`. It opens at the first call; not
  found is `RUNTIME-NATIVE-LOAD`. The working directory is never searched. On
  Windows a name is looked up next to `agentica.exe` and in System32, not in
  `PATH`; write an absolute path with escaped backslashes. On macOS a name is
  looked up as `/usr/lib/NAME` (libc and libm are `"libSystem.B.dylib"`); any
  other library needs an absolute path.
- A package picks its library per system in its `agentica.toml`
  (`[native.NAME]`, see `modules.md`); `extern "NAME"` in its files opens it. A
  `native/` library that loads a sibling: on Linux build it with
  `RPATH=$ORIGIN`, on macOS with `@loader_path`.
- `Native.load("NAME") -> Result[Void]` opens the library now: `ok` (it stays
  open for the extern functions) or `error("native: cannot open NAME: ...")`, so
  a package can report a missing library or fall back before any side effect
  (`try Native.load("pq")`). The argument is a string literal (else
  `CHECK-NATIVE-LOAD`). A missing function is still `RUNTIME-NATIVE-LOAD` at its
  call.
- `Native.function?("NAME", "symbol") -> Bool` asks whether the library opens
  and exports the function, so a program can pick a fallback before calling a
  declared function that the library may lack (`NAME` as for `Native.load`; the
  symbol is any String). `true` means an `extern def` with that C name would
  bind (Linux and macOS also find dependencies' and data symbols; Windows only
  the DLL's own exports). A missing library or function, or a symbol over 4096
  bytes, is `false`; nothing stays open.
- An integer argument takes the bits of its type read as signed or unsigned,
  as `put_int32` does (`C.Int32` -2^31 to 2^32 - 1, `C.UInt8` -128 to 255), and
  C gets the low bits; outside is `RUNTIME-INTEGER-OVERFLOW`. Unsigned results
  are never negative (`C.UInt32` above 2^31 is positive). No unsigned 64-bit
  type: `uint64_t` and `size_t` are `C.Int64`, `unsigned long` is `C.Long`
  (same bits; above the signed maximum reads negative). A NUL in a `C.String`
  is `RUNTIME-INVALID-CHARACTER` (for text with a NUL or a known length, use
  `Native.from_string` and `bytesize`). A `NULL` string result reads as
  `""`: when NULL matters, declare `-> C.Pointer` and use `Native.get_string`.
- `C.Pointer` (`void *`) is a type any code may hold; it may be NULL
  (`Native.null()`, `Native.null?(p) -> Bool`), and has no `==`. `C.Bytes` is a
  parameter only: a `Bytes` that C gets as a `const uint8_t *` copy valid during
  the call; pass the length separately (`b.size`).
- Memory C returns, from a byte offset: `Native.get_string(p, off) -> String`
  (up to the NUL), `Native.get_string(p, off, length)` (exactly `length` bytes,
  NULs included) and `Native.get_bytes(p, off, length) -> Bytes` copy it; bytes
  that are not UTF-8 become U+FFFD. NULL with length 0 reads as empty; other
  NULL is `RUNTIME-NATIVE-NULL` (test with `Native.null?` first); a length past
  what C owns is undefined behavior. `Native.pointer(n)` is the pointer with
  value `n` (`SQLITE_TRANSIENT` is `Native.pointer(-1)`); `Native.address(p) ->
  Int` is the inverse (a freed buffer `RUNTIME-NATIVE-CLOSED`): subtract two
  pointers into one block for the bytes between them (SQLite's `pzTail`). A
  `char **` out parameter read with `get_string` is then freed by its C
  function.
- Owned buffers: `Native.memory_pointer(size) -> C.Pointer` is `size` zeroed
  bytes that the task owns (pass it to any `C.Pointer` parameter).
  `Native.free(p)` ends a buffer; the owner's end frees the rest, so a loop that
  never frees grows. `Native.memory_pointer(size) do |buf| ... end` frees it
  when the block ends (an error returned with `try` too) and gives the block's
  value: prefer it for a buffer of one call (one handed to another task is left
  to its new owner). `Native.from_string(text)` (block form too) is a buffer of
  the UTF-8 bytes of `text` and a NUL (`text.bytesize + 1` bytes, NULs inside
  kept): pass it with `text.bytesize` to C that takes a length.
  `Task.spawn_owning(&f, buf)` hands a buffer over; a channel send or a task's
  result does not. A `compute def` call holds it (reading or writing it
  meanwhile races with C). A freed one is `RUNTIME-NATIVE-CLOSED`; `Native.free`
  of C's pointer `RUNTIME-NATIVE-NOT-OWNED`. `put_pointer` stores an untracked
  address: keep the target alive while C uses it.
- `Native.offset(p, n) -> C.Pointer` is `n` bytes past `p`: plain `p + n`
  (wrapping) for C's pointer; for a buffer a view from byte `n` to its end (`n`
  outside 0..size is `RUNTIME-NATIVE-BOUNDS`), freed with its buffer;
  `Native.free(view)` is `RUNTIME-NATIVE-NOT-OWNED` and `Task.spawn_owning`
  takes the buffer, not a view.
- Typed memory at a byte offset of any `C.Pointer` (Ruby `ffi` names):
  `Native.get_int8/16/32/64(p, off)`, `get_uint8/16/32`, `get_float32/64`,
  `get_pointer`; `Native.put_int8/16/32/64(p, off, v)` (signed or unsigned
  range, else `RUNTIME-INTEGER-OVERFLOW`), `put_float32/64`, `put_pointer`,
  `put_string(p, off, s)` (adds the NUL), `put_bytes(p, off, bytes)` (a
  `Bytes`); bulk
  `Native.get_array_of_int32/int64/float32/float64(p, off, count) -> List` and
  `put_array_of_*(p, off, list)`. In a buffer, past its end or a negative offset
  is `RUNTIME-NATIVE-BOUNDS`; at C's pointer only NULL (`RUNTIME-NATIVE-NULL`)
  and a negative offset are checked, the rest is trusted (UB if wrong). Two
  tasks that use the same C memory at once race, as in C.
- `[export] resource Db, free: db_close` in a block declares a resource type,
  freed by `void db_close(void *)` of the same library (any C name, capitals
  allowed: `free: PQfinish`; only `C.Function` is a type). On Windows the free
  function must come from the declared library itself (not a dependency's
  `free`). Declare the resource above the `def`s that use it. `resource Db,
  free_ref: duckdb_close` is freed by `void duckdb_close(void **)`: each free
  passes the address of the pointer (C may write NULL there); a second free word
  is `PARSE-EXTERN-FREE`, and `free_ref: C.Function` is `PARSE-EXTERN-FUNCTION`.
  `def db_open(...) -> Db` gives `Result[Db]` (NULL is `error("db_open returned
  NULL")`); the resource is owned by the calling task. `Native.close(db)` frees
  once (a second close does nothing); a call with a closed resource is
  `RUNTIME-NATIVE-CLOSED`. The owner's end frees what it did not close;
  `Task.spawn_owning(&f, db)` hands it on. A running call (`def` or `compute
  def`) keeps its resource until it returns (a close, or a cancel of a `compute
  def`, meanwhile defers the free), and what it comes from, one level up only (a
  statement keeps its database, a row of the statement does not): close children
  before parents. The end of the run frees every resource and buffer still open
  (any task's), newest first, after waiting for running calls that hold one; the
  wait and the frees share the `--flush-timeout` limit (0 frees nothing), and
  what is slower is left with one stderr warning. Any task may pass a resource
  or buffer to C (no owner check); only the owner's end frees it, and
  `Native.close`/`free` by any task closes it for all. Two tasks inside C on one
  object race, as in C. A free that blocks (`mysql_close`) runs on the scheduler
  and stalls other tasks. A parent handed to another task may be freed before
  its children: close the children first, or keep them in one task. A function
  that returns a borrowed pointer must be `-> C.Pointer`, or it is freed twice.
  A `def` of the free function in the block is `PARSE-EXTERN-FREE` (per block:
  never declare it in another). Resources and `C.Pointer` do not convert; no
  `to_s` or JSON; inspects as `<Db>`.
  ~~~ruby
  extern "libc.so.6"
    resource Stream, free: fclose
    def fopen(path: C.String, mode: C.String) -> Stream
    def fputs(text: C.String, stream: Stream) -> C.Int32
  end
  ~~~
- `Native.closed?(x) -> Bool` asks before a call would stop the task with
  `RUNTIME-NATIVE-CLOSED`, so a wrapper can return `error`: `true` after
  `Native.close` (any task) or the owner's end, for a NULL out resource and for
  a freed owned buffer; `false` for a live one and for any `C.Pointer` of C,
  NULL included. `true` is final; `false` can go stale if another task may
  close `x`.
- `out NAME: T` is an out parameter (`T` is an integer type, `C.Double`,
  `C.Float`, `C.Bool`, `C.Pointer` or a resource; else `PARSE-EXTERN-OUT`).
  The caller does not pass it; C writes through a pointer to a zeroed slot. The
  call returns a record named after the function in CamelCase
  (`Sqlite3Open`), with `result` (the C result; none for `Void`) and one field
  per out parameter.
  An out resource field is the resource (not a `Result`): owned by the task
  when C wrote a pointer, closed (never freed, calls fail with
  `RUNTIME-NATIVE-CLOSED`) when it is NULL, so check `result` or
  `Native.closed?` first (comment-only SQL gives `SQLITE_OK` and a NULL
  statement). An out named `result` beside a C result is `PARSE-EXTERN-OUT`.

  ~~~ruby
  extern "libsqlite3.so.0"
    resource Db, free: sqlite3_close_v2
    def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  end

  def open(path: String) -> Result[Db]
    opened = sqlite3_open(path)
    if opened.result != 0
      Native.close(opened.db)   # a failed open still gives a live handle
      return error("sqlite open failed: #{opened.result}")
    end

    return ok(opened.db)
  end
  ~~~
- A `def` call holds its scheduler until it returns: keep such calls short.
  Native code must retry on `EINTR` (GC signals cut sleeps and polls short).
- Native calls (`def` and `compute def`) of tasks on different schedulers run
  at the same time. Guard a library that is not thread-safe with a lock:
  `lock = Native.mutex()` (a `Native.Mutex`), then
  `lock.synchronize do ... end` runs the block with it held and returns the
  block's value. A waiter parks (FIFO); the task's end, crash or cancel gives it
  back (a running `compute def` of the block keeps it until C returns); a nested
  `synchronize` by the holder is `RUNTIME-NATIVE-MUTEX`. A mutex
  is no data (no `==`, no `to_s`, no constant): make it in the open function and
  keep it next to the handle.
- `[export] compute def f(...) -> T` runs the call on the VM's compute pool (one
  thread per scheduler) while the task waits and other tasks run; for long
  calls. Same plain result. No timeout, and `--max-steps` cannot end it; for a
  limit run it in a task and use `Task.await(task, ms)`. A cancel skips a call
  not yet started; a running one runs on and its result is dropped. A call that
  never returns holds a pool thread; once `--schedulers` are stuck, later
  compute calls wait. The function must be safe to call from another thread.
  At process end the final flush skips C stdout or stderr while a native call
  holds its lock, so buffered C bytes may be lost.
- `Native.wait_readable(fd: Int, timeout_ms: Int) -> Result[Void]` and
  `Native.wait_writable` park the task until a descriptor of native code (a
  library's socket) can be read or written; other tasks run. For libraries in
  non-blocking mode: `try Native.wait_readable(Raw.PQsocket(conn), 5_000)`.
  Timeout (positive ms): `error("native: timed out")`; a bad timeout or a
  descriptor that is negative, closed or not pollable (regular file): an error
  starting `native: `. An error or hang-up on the descriptor gives `ok` (the
  next native call reports it). Two tasks may wait on one descriptor; a cancel
  stops the wait. On Windows only a socket works (its Winsock `SOCKET`), one
  wait per socket at a time.
- Linux and macOS (x86_64, arm64), Windows x64: elsewhere such a program is
  refused at load (`RUNTIME-NATIVE-UNSUPPORTED`, exit 2). `--deny-native` (or
  any `--deny-*` flag) refuses it too (`RUNTIME-NATIVE-DENIED`, exit 2).
- Variadic C functions: `...` where the variadic part starts, then the C type of
  each argument the calls pass. `= "c_name"` after the result names the C
  function when the `def` name differs, so one function takes several shapes.
  `...` needs a C parameter (not a `C.Function`) before it
  (`PARSE-EXTERN-VARIADIC-FIXED`) and appears once (`PARSE-EXTERN-VARIADIC`);
  after it no `out`, `C.Bool`, `C.Float` or 8 and 16-bit integer (C promotes
  them: write `C.Int32`, `C.Double`; `PARSE-EXTERN-VARIADIC-TYPE`). Never
  declare a variadic function without `...`: on Apple arm64 its arguments go on
  the stack.

  ~~~ruby
  extern "libc.so.6"
    def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
    def fcntl_get(fd: C.Int32, cmd: C.Int32, ...) -> C.Int32 = "fcntl"
    def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  end
  ~~~
- Function pointers (a table of them, as onnxruntime's `OrtApi`): a first
  parameter `fn: C.Function` makes the `def` call that address, with its
  declared signature (no `= "symbol"`); pass `Native.get_pointer(api, slot *
  8)`. `resource Session, free: C.Function` is freed through a pointer: the
  `def` that makes one (result or `out`) takes it as its last parameter `free:
  C.Function` (after the `out` ones), and close, the owner's end and a dropped
  compute result call it once. A sole `C.Function` of a `def` that returns such
  a resource is its free function. `C.Function` is a `C.Pointer` to the program;
  elsewhere, or a second such resource in one call, is `PARSE-EXTERN-FUNCTION`;
  never a result, `out` or variadic. NULL is `RUNTIME-NATIVE-NULL` before C
  runs, an owned buffer `RUNTIME-NATIVE-BOUNDS`; a wrong address is undefined
  behavior.

  ~~~ruby
  extern "/opt/plugin/libplugin.so"
    resource Handle, free: C.Function
    def plugin_api(version: C.Int32) -> C.Pointer
    def open(fn: C.Function, path: C.String, out h: Handle,
             free: C.Function) -> C.Int32
    compute def read(fn: C.Function, h: Handle, n: C.Int64) -> C.Int64
  end
  ~~~
- Callbacks (C calls your function: `qsort`, a SQLite collation; Ruby ffi's
  `callback`): `callback Name(params) -> result` in the block, then
  `cb = Native.callback(Name, &fn)` and pass `cb` to a `def` that takes
  `cmp: Name` (also after `...`). Types: integers, `C.Double`, `C.Float`,
  `C.Bool`, `C.String` (parameter only), `C.Pointer`, a `Void` result; else
  `PARSE-EXTERN-TYPE`; no default, `out` or `...`. `fn` is a `def` named with
  `&` whose types are the Agentica ones (`C.Int32` is `Int`), else
  `CHECK-TYPE-MISMATCH`; an `Fn` value or an extern `def` is
  `CHECK-NATIVE-CALLBACK` and a block is refused (context goes through C's
  `void *` user data). `cb` is a resource (`Native.close`; C that calls it
  after gets zero, so a free function may still call a stored one). A
  callback is never a result or `out`; a parameter
  `cmp: Optional[Name]` takes `none` for NULL. `fn` runs in the calling task
  while C waits: no wait inside it (`Task.sleep`, channels, a `compute def`, a
  print behind another task's print): `RUNTIME-NATIVE-CALLBACK`; a print into
  a full output buffer waits for it to drain. A failure in
  `fn` gives C zero and fails the extern call when C returns. A callback from
  C's own thread, a free function or a `compute def` gives zero (the compute
  call then fails); at most 128 nested (`RUNTIME-STACK-OVERFLOW`).
- C structs by value (llama.cpp's `llama_context_params`, Ruby ffi's
  `FFI::Struct`): `[export] struct Name ... end` in the block, every field of
  the header in its order, each an integer type, `C.Double`, `C.Float`,
  `C.Bool`, `C.Pointer` or a struct declared above in the block (else
  `PARSE-EXTERN-TYPE`: a `char *` is a `C.Pointer` read with
  `Native.get_string`; no fixed arrays). The program sees an ordinary struct
  (`Int`, `Float`, `Bool`, `C.Pointer` fields; defaults and `.with` work),
  copied into C for each call and back from a struct result. A parameter or a
  result (also `compute def` and through a `C.Function`), never `out`
  (`PARSE-EXTERN-OUT`: pass an owned buffer, read it with `get_struct`) or
  variadic. Fields are checked like arguments (`RUNTIME-INTEGER-OVERFLOW`, a
  freed buffer `RUNTIME-NATIVE-CLOSED`). A wrong field list is undefined
  behavior.

  ~~~ruby
  extern "/opt/infer/libinfer.so"
    struct ContextParams
      n_ctx: C.Int32
      n_threads: C.Int32
      embeddings: C.Bool
      callback_data: C.Pointer
    end

    def infer_context_default_params() -> ContextParams
    def infer_context_size(params: ContextParams) -> C.Int32
  end

  def main() -> Void
    params = infer_context_default_params().with(n_ctx: 4096)
    puts(infer_context_size(params))
  end
  ~~~
- Such a struct in memory (Ruby ffi's `Struct.size`, `Struct.new(ptr)`):
  `Native.size_of(Name) -> Int` is C's `sizeof` (a `C.Long` field differs on
  Windows), `Native.get_struct(p, off, Name) -> Name` reads one,
  `Native.put_struct(p, off, value)` writes one (fields checked first, as for a
  call; a `C.Pointer` field is untracked, as with `put_pointer`). An array:
  item `k` at `k * Native.size_of(Name)`. Bounds as for `get_int32`. `Name`
  may be an alias of such a struct; another type, or a value for the type name:
  `CHECK-TYPE-MISMATCH`.
- Functions count as `def`s for the declaration order, resources and structs
  as types; a block with a resource or a struct counts as types as a whole. In
  an `extern module` block, a resource counts as a `def` instead. A wrong
  signature is undefined behavior in C: copy it from the C header.

## Wrapping a library

Keep the `extern` layer private and give the user a normal API; guide:
`library/io-and-system/native/wrapping.md`.

- Copy the C signatures as they are (no `?`, `!` or default in the block). The
  public `def`s use Ruby names and return `Result` with an error text that
  names the bad value. An out parameter becomes a field of your own struct; a
  yes/no `int` becomes a `name?` function returning `Bool`.
- A block with a resource or a struct sits with the types, above every function
  of the file, and its `def`s do not count as functions for `CHECK-DECL-ORDER`.
  `export resource` so callers can name the type, keep the `def`s private. A
  block with neither: put it at the end of the file. An `extern module` block
  is all `def`s, its resources included: put it with the functions.
- A `String` with a NUL stops the program at the C call
  (`RUNTIME-INVALID-CHARACTER`): check inputs first, or pass
  `Native.from_string(s)` and `s.bytesize` when C takes a length.
- A table of function pointers: keep the slot numbers as constants, get the
  table once (turn a NULL into an `error`) and never show a `C.Pointer` of a
  function to the caller.
- No varargs in Agentica: declare each shape of a variadic C function with
  `...` and `= "symbol"`, keep them private, and give the public `def` a
  `List[T]`, a struct with defaults, or parameters with defaults. Never let the
  caller choose a printf format: pass a constant format and the text as `%s`.
- A package lists the library per system in `agentica.toml` (`[native.NAME]`,
  see `modules.md`) and the `extern` block says `extern "NAME"`.
