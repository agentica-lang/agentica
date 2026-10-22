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

- Types: `C.Int` (32-bit `int`, an `Int`), `C.Int64` (`Int`), `C.Double`
  (`Float`), `C.Bool` (`Bool`), `C.String` (`const char *`, a `String`); a
  result may be `Void`. Anything else is `PARSE-EXTERN-TYPE`; more than 64
  parameters `PARSE-EXTERN-ARITY`; a name with `?` or `!` `PARSE-EXTERN-NAME`;
  a default `PARSE-EXTERN-DEFAULT`. `##` docs go on the `def` lines.
- The library is a plain string: a name without `/` (the system looks it up)
  or an absolute path; anything else is `PARSE-EXTERN-LIBRARY`. It opens at the
  first call; not found is `RUNTIME-NATIVE-LOAD`.
- A `C.Int` outside 32 bits is `RUNTIME-INTEGER-OVERFLOW`; a NUL in a
  `C.String` is `RUNTIME-INVALID-CHARACTER`. A `NULL` string result reads as
  `""` for now.
- A `def` call blocks timers, I/O and other tasks until it returns: keep such
  calls short. Native code must retry on `EINTR` (GC signals cut sleeps and
  polls short).
- `[export] compute def f(...) -> T` runs the call on the VM's compute pool
  (one thread per scheduler) while the task waits and other tasks run; for long
  calls. Same plain result. No timeout, `--max-steps` cannot end it; for a
  limit, run it in a task and use `Task.await(task, ms)`. A cancel skips a call
  not yet started; a running one runs on and its result is dropped. A call that
  never returns holds a pool thread; once `--schedulers` are stuck, later
  compute calls wait. The function must be safe to call from another thread.
- `Native.wait_readable(fd: Int, timeout_ms: Int) -> Result[Void]` and
  `Native.wait_writable` park the task until a descriptor of native code (a
  library's socket) can be read or written; other tasks run. For libraries in
  non-blocking mode: `try Native.wait_readable(Raw.PQsocket(conn), 5_000)`.
  Timeout (positive ms): `error("native: timed out")`; a bad timeout or a
  descriptor that is negative, closed or not pollable (regular file,
  `/dev/null`): an error starting `native: `. An error or hang-up on the
  descriptor gives `ok` (the next native call reports it). It polls a
  duplicate, so two tasks may wait on one descriptor; the descriptor becomes
  non-blocking. A cancel stops the wait.
- Linux x86_64 only for now: elsewhere a program with an extern function or a
  `Native.wait_*` call is refused at load with `RUNTIME-NATIVE-UNSUPPORTED`
  (exit 2). `check` works everywhere.
- Allowed by default; `--deny-native` (or any `--deny-*` flag) refuses such a
  program at load (`RUNTIME-NATIVE-DENIED`, exit 2).
- Functions count as `def`s for the declaration order. A wrong signature is
  undefined behavior in C: copy it from the C header.
