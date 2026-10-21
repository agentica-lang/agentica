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
- A call blocks timers, I/O and other tasks until it returns: keep calls
  short. Native code must retry on `EINTR` (GC signals cut sleeps and polls
  short).
- Linux x86_64 only for now: elsewhere the program is refused at load with
  `RUNTIME-NATIVE-UNSUPPORTED` (exit 2). `check` works everywhere.
- Allowed by default; `--deny-native` (or any `--deny-*` flag) refuses
  any program with an extern function at load (`RUNTIME-NATIVE-DENIED`, exit 2).
- Functions count as `def`s for the declaration order. A wrong signature is
  undefined behavior in C: copy it from the C header.
