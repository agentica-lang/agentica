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

- Native calls work on Linux x86_64, Windows x64 and macOS (x86_64 and arm64), and `Native.wait_*` on Linux x86_64, macOS and Windows (sockets only on Windows). On other systems a program that declares an extern function or calls a `Native.*` builtin is refused before it runs (`RUNTIME-NATIVE-UNSUPPORTED`, exit 2); `check` and `compile` work everywhere.
- Native code runs with your program's rights, and a wrong signature is undefined behavior in C: declare each function exactly as its C header does. A variadic function (`printf`) is declared with `...` ([variadic functions](/library/io-and-system/native/types/#variadic-functions-and-c-names)).
- Put `##` docs on the `def` lines inside the block.

A package can ship its library or name a system one in its `agentica.toml` (`[native.NAME]`, one entry for each of `linux`, `macos` and `windows`), and `extern "NAME"` in the package's files then opens the right one by its path in `deps/`. The files of its `native/` folder are hashed with the package, so the lock covers them. See [Packages](/tour/modules/).

The rest of the section has its own pages:

- Use [Types and resources](/library/io-and-system/native/types/) for the C types, reading memory that C returns, owned buffers and typed memory, resources, out parameters, C function pointers and C structs.
- Use [SQLite](/library/io-and-system/native/sqlite/) for a full example: a library behind safe functions that return `Result`.
- Use [Compute calls](/library/io-and-system/native/compute/) for a call that may take long: the other tasks keep running.
- Use [Waiting on a descriptor](/library/io-and-system/native/waiting/) to wait for a socket or descriptor without stopping the other tasks.
- Use [Wrapping a C library](/library/io-and-system/native/wrapping/) to hide the C habits of a library behind a normal API and ship it in a package.

## The block

- The library is a plain string: a name without `/` (`"libm.so.6"`), which the system looks up, or an absolute path (`"/opt/tool/libtool.so"`). Anything else is `PARSE-EXTERN-LIBRARY`. The working directory is never searched. On Windows a name (`"ucrtbase.dll"`) is looked up next to `agentica.exe` and in the system folder, not in `PATH`; write an absolute path with escaped backslashes (`"C:\\libs\\x.dll"`), and the DLLs it needs are searched in its folder and the default folders, never in `PATH` (a MinGW DLL that needs `libgcc_s_seh-1.dll` must have it next to it). On macOS a name (`"libsqlite3.dylib"`) is looked up as `/usr/lib/NAME` (and in `DYLD_LIBRARY_PATH`), which finds the system libraries in the dyld shared cache (libc and libm are `"libSystem.B.dylib"`); any other library takes its absolute path (`"/opt/homebrew/lib/libpq.dylib"`). macOS drops `DYLD_*` variables when a protected program such as `/usr/bin/env` or `/bin/sh` starts agentica, so `DYLD_LIBRARY_PATH` does not pass through a shebang line or a shell script.
- The library opens at the first call of one of its functions and stays open. A library, dependency or function that is not found fails that call with `RUNTIME-NATIVE-LOAD`.
- A `def` name has no `?` or `!`, even with a C name after `=` (`PARSE-EXTERN-NAME`); parameters take no default (`PARSE-EXTERN-DEFAULT`); only the [types](/library/io-and-system/native/types/) and the block's resources and structs cross (`PARSE-EXTERN-TYPE`).
- `export def` makes a function importable from other files. The functions take the place of `def` functions in the declaration order, and resources and structs the place of types. A block that declares a resource or a struct takes the place of types as a whole, its functions included.
- `extern` is a keyword only at the start of a top-level declaration, and `resource` only at the start of a line of the block; elsewhere they are ordinary names.

## Running

- A `def` call blocks timers, I/O and other tasks until it returns, so keep such calls short, and use [`compute def`](/library/io-and-system/native/compute/) for the long ones. `--max-steps` cannot stop a call in the middle.
- Native code must retry calls cut short by `EINTR`: GC signals can interrupt sleeps and polls.
- Native code is allowed by default and can start programs itself. `agentica --deny-native file.agc` (or any `--deny-*` flag) refuses a program that declares any extern function or calls a `Native.*` builtin before anything runs (`RUNTIME-NATIVE-DENIED`, exit 2). Under `agentica test`, such a test file is a file error with that code.
