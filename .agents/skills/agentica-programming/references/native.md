# Native code

An `extern` block declares C functions of a native library. Each line is a
signature with C types and no body; call the function like any `def`.

~~~ruby
extern "libm.so.6"
  ## The cosine of x.
  export def cos(x: C.Double) -> C.Double

  def labs(n: C.Int64) -> C.Int64
end
~~~

- Types: `C.Int32` (32-bit `int`, an `Int`), `C.Int64` (`Int`), `C.Double`
  (`Float`), `C.Bool` (`Bool`), `C.String` (`const char *`, a `String`); a
  result may be `Void`. Anything else (`C.Int` too: write the width) is
  `PARSE-EXTERN-TYPE`; more than 64 parameters `PARSE-EXTERN-ARITY`; a name
  with `?` or `!` `PARSE-EXTERN-NAME`; a default `PARSE-EXTERN-DEFAULT`. `##`
  docs go on the `def` lines.
- The library is a plain string: a name without `/` (the system looks it up) or
  an absolute path, else `PARSE-EXTERN-LIBRARY`. It opens at the first call; not
  found is `RUNTIME-NATIVE-LOAD`. The working directory is never searched. On
  Windows a name (`"ucrtbase.dll"`, `"winsqlite3.dll"`) is looked up next to
  `agentica.exe` and in System32, not in `PATH`; an absolute path is
  `"C:\\libs\\x.dll"` (escaped backslashes), and its DLLs are searched in its
  folder and the default folders, never in `PATH` (put `libgcc_s_seh-1.dll` next
  to a MinGW DLL).
  On macOS a name (`"libsqlite3.dylib"`) is looked up as `/usr/lib/NAME` (and
  in `DYLD_LIBRARY_PATH`): the system libraries, in the dyld shared cache
  (libc and libm are `"libSystem.B.dylib"`); any other library needs an
  absolute path. `DYLD_*` variables do not pass through a shebang or a shell
  (SIP drops them).
- A `C.Int32` outside 32 bits is `RUNTIME-INTEGER-OVERFLOW`; a NUL in a
  `C.String` is `RUNTIME-INVALID-CHARACTER`. A `NULL` string result reads as
  `""`: when NULL matters, declare `-> C.Pointer` and use `Native.string_at`.
- `C.Pointer` (`void *`) is a type any code may hold; it may be NULL
  (`Native.null()`, `Native.null?(p) -> Bool`), has no `==`, and inspects as
  `<C.Pointer>`. `C.Bytes` is a parameter only: a `List[Int]` of bytes (an
  item outside 0..255 is `RUNTIME-INVALID-NUMBER`) that C gets as a
  `const uint8_t *` copy valid during the call; pass the length separately.
- Memory C returns: `Native.string_at(p) -> String` (up to the NUL),
  `Native.string_at(p, length)` (exactly `length` bytes, NULs included) and
  `Native.bytes_at(p, length) -> List[Int]` copy it; bytes that are not UTF-8
  become U+FFFD. NULL with length 0 reads as empty (an empty SQLite blob);
  other NULL is `RUNTIME-NATIVE-NULL` (test with `Native.null?` first), checked
  before a negative length (`RUNTIME-INVALID-COUNT`); a length past what C
  owns is undefined behavior. `Native.pointer(n)` is the pointer with value `n`
  (`SQLITE_TRANSIENT` is `Native.pointer(-1)`). A `char **` out parameter
  read with `string_at` is then freed by its C function (`sqlite3_free`).
- `[export] resource Db, free: db_close` in a block declares a resource type,
  freed by `void db_close(void *)` of the same library. Declare it above the
  `def`s that use it. `def db_open(...) -> Db` gives `Result[Db]` (NULL is
  `error("db_open returned NULL")`); the resource is owned by the calling
  task. `Native.close(db)` frees once (a second close does nothing); a call
  with a closed resource is `RUNTIME-NATIVE-CLOSED`. The owner's end frees
  what it did not close; `Task.spawn_owning(&f, db)` hands it on; `main`'s
  return frees nothing. A `compute def` call keeps its resource until it
  returns (a close or cancel meanwhile defers the free). A function that
  returns a borrowed pointer must be `-> C.Pointer`, or it is freed twice. A
  `def` of the free function in the block is `PARSE-EXTERN-FREE` (per block:
  never declare it in another). Resources and `C.Pointer` do not convert; no
  `to_s` or JSON; inspects as `<Db>`.

  ~~~ruby
  extern "libc.so.6"
    resource Stream, free: fclose
    def fopen(path: C.String, mode: C.String) -> Stream
    def fputs(text: C.String, stream: Stream) -> C.Int32
  end
  ~~~
- `out NAME: T` is an out parameter (`T` is `C.Int32`, `C.Int64`, `C.Double`,
  `C.Bool`, `C.Pointer` or a resource; else `PARSE-EXTERN-OUT`). The caller
  does not pass it; C writes through a pointer to a zeroed slot. The call
  returns a record named after the C name in CamelCase (`Sqlite3Open`), with
  `result` (the C result; none for `Void`) and one field per out parameter.
  An out resource field is the resource (not a `Result`): owned by the task
  when C wrote a pointer, closed (never freed, calls fail with
  `RUNTIME-NATIVE-CLOSED`) when it is NULL, so check `result` first. An out
  named `result` beside a C result is `PARSE-EXTERN-OUT`.

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
- A `def` call blocks timers, I/O and other tasks until it returns: keep such
  calls short. Native code must retry on `EINTR` (GC signals cut sleeps and
  polls short).
- `[export] compute def f(...) -> T` runs the call on the VM's compute pool (one
  thread per scheduler) while the task waits and other tasks run; for long
  calls. Same plain result. No timeout, and `--max-steps` cannot end it; for a
  limit run it in a task and use `Task.await(task, ms)`. A cancel skips a call
  not yet started; a running one runs on and its result is dropped. A call that
  never returns holds a pool thread; once `--schedulers` are stuck, later
  compute calls wait. The function must be safe to call from another thread.
- `Native.wait_readable(fd: Int, timeout_ms: Int) -> Result[Void]` and
  `Native.wait_writable` park the task until a descriptor of native code (a
  library's socket) can be read or written; other tasks run. For libraries in
  non-blocking mode: `try Native.wait_readable(Raw.PQsocket(conn), 5_000)`.
  Timeout (positive ms): `error("native: timed out")`; a bad timeout or a
  descriptor that is negative, closed or not pollable (regular file,
  `/dev/null` on Linux): an error starting `native: `. An error or hang-up on
  the descriptor gives `ok` (the next native call reports it). It polls a new
  open of the file, so the descriptor keeps its flags and two tasks may wait on
  one descriptor (a socket, a terminal master, an eventfd or a macOS pipe is
  polled through a duplicate, flags kept). Closing the descriptor does not end
  a wait (it times out unless the file becomes ready). A cancel stops the
  wait.
- Linux x86_64, Windows x64 and macOS (`Native.wait_*` is not supported on
  Windows and returns an error): elsewhere a program with an extern function
  or a `Native.*` call is refused at load with `RUNTIME-NATIVE-UNSUPPORTED`
  (exit 2). `check` works everywhere.
- Allowed by default; `--deny-native` (or any `--deny-*` flag) refuses such a
  program at load (`RUNTIME-NATIVE-DENIED`, exit 2).
- Functions count as `def`s for the declaration order, resources as types. A
  wrong signature is undefined behavior in C: copy it from the C header. No
  variadic functions (`printf`): a fixed signature is undefined behavior, and
  wrong on Apple arm64.
