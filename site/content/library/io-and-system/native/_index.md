---
title: Native code
weight: 7
description: Call C functions of a native library with an extern block.
---

An `extern` block names a native library and declares the C functions your program calls from it. Each line is a signature with C types and no body; the function is then called like any other.

```agentica {mode="check"}
extern "libm.so.6"
  ## The cosine of x, in radians.
  def cos(x: C.Double) -> C.Double

  def labs(n: C.Long) -> C.Long
end

def main() -> Void
  puts(cos(0.0))
  puts(labs(-5))
end
```

- Native calls work on Linux and macOS (x86_64 and arm64) and on Windows x64, and `Native.wait_*` on Linux, macOS and Windows (sockets only on Windows). On other systems a program that declares an extern function or calls a `Native.*` builtin is refused before it runs (`RUNTIME-NATIVE-UNSUPPORTED`, exit 2); `check` and `compile` work everywhere.
- Native code runs with your program's rights, and a wrong signature is undefined behavior in C: declare each function exactly as its C header does. A variadic function (`printf`) is declared with `...` ([variadic functions](/library/io-and-system/native/types/#variadic-functions-and-c-names)).
- Put `##` docs on the `def` lines inside the block.

A package can ship its library or name a system one in its `agentica.toml` (`[native.NAME]`, one entry for each of `linux`, `macos` and `windows`), and `extern "NAME"` in the package's files then opens the right one by its path in `deps/`. The files of its `native/` folder are hashed with the package, so the lock covers them. A library of `native/` that loads a sibling library finds it on Windows (the DLL's folder), but on Linux it must be built with `RPATH=$ORIGIN` and on macOS with `@loader_path`. See [Packages](/tour/modules/).

The rest of the section has its own pages:

- Use [Types and resources](/library/io-and-system/native/types/) for the C types, reading memory that C returns, owned buffers and typed memory, resources, out parameters, C function pointers, callbacks and C structs.
- Use [SQLite](/library/io-and-system/native/sqlite/) for a full example: a library behind safe functions that return `Result`.
- Use [Compute calls](/library/io-and-system/native/compute/) for a call that may take long: the other tasks keep running.
- Use [Waiting on a descriptor](/library/io-and-system/native/waiting/) to wait for a socket or descriptor without stopping the other tasks.
- Use [Wrapping a C library](/library/io-and-system/native/wrapping/) to hide the C habits of a library behind a normal API and ship it in a package.
- Use [Native modules](/library/io-and-system/native/modules/) for C code written for Agentica: it takes and returns Agentica values, a whole result in one call.

## Which one

`extern "LIB"` and `extern module` do different jobs:

- `extern "LIB"` binds an existing C library as it is: you write no C, the library only needs to be installed, and it fits a few calls with scalar or pointer arguments.
- `extern module` is C written for Agentica: you compile a small C file against `agentica_native.h`, and one call takes and returns Agentica values (lists, maps, structs, resources). It fits hot paths and whole results: in `make bench-native` (`benchmarks/native/run.py`, Linux x86-64), a List of 1000 structs took about 65 µs from one module call and about 562 µs from 1000 extern calls with a push each.
- Both together is common: a module that wraps a C library, such as SQLite, and gives the program Agentica values.

## The block

- The library is a plain string: a name without `/` (`"libm.so.6"`), which the system looks up, or an absolute path (`"/opt/tool/libtool.so"`). Anything else is `PARSE-EXTERN-LIBRARY`. The working directory is never searched. On Windows a name (`"ucrtbase.dll"`) is looked up next to `agentica.exe` and in the system folder, not in `PATH`; write an absolute path with escaped backslashes (`"C:\\libs\\x.dll"`), and the DLLs it needs are searched in its folder and the default folders, never in `PATH` (a MinGW DLL that needs `libgcc_s_seh-1.dll` must have it next to it); a relative path there (`"lib\\x.dll"`, `"C:x.dll"`) is `RUNTIME-NATIVE-LOAD`. On macOS a name (`"libsqlite3.dylib"`) is looked up as `/usr/lib/NAME` (and in `DYLD_LIBRARY_PATH`), which finds the system libraries in the dyld shared cache (libc and libm are `"libSystem.B.dylib"`); any other library takes its absolute path (`"/opt/homebrew/lib/libpq.dylib"`; a package can list [candidates](/tour/modules/) in its manifest). macOS drops `DYLD_*` variables when a protected program such as `/usr/bin/env` or `/bin/sh` starts agentica, so `DYLD_LIBRARY_PATH` does not pass through a shebang line or a shell script.
- The library opens at the first call of one of its functions and stays open. A library, dependency or function that is not found fails that call with `RUNTIME-NATIVE-LOAD`.
- `Native.load("NAME") -> Result[Void]` opens the library before its first call: `ok`, and it stays open for the block's functions, or `error` with the loader's text (`native: cannot open NAME: ...`). A package can then report a missing library, or fall back, before any side effect: `try Native.load("pq")`. The argument is a string literal that means what `extern "NAME"` means, the package's `[native.NAME]` included; anything else is `CHECK-NATIVE-LOAD`. A function missing from the library still fails its first call with `RUNTIME-NATIVE-LOAD`.
- `Native.function?("NAME", "symbol") -> Bool` asks whether the library opens and exports the function, so a program can choose a fallback before it calls a declared function that an optional library may lack (a bcrypt `crypt_r` in a user-supplied `libcrypt`): `if Native.function?("libcrypt.so.1", "crypt_r")`. `NAME` is a string literal as for `Native.load`; the symbol is any `String`. It is `true` when an `extern def` with this C name would bind: on Linux and macOS the lookup (`dlsym`) also searches the library's dependencies and its data symbols, on Windows only the DLL's own exports count. A library that does not open, a missing function, or a symbol over 4096 bytes is `false`; the library is not kept open (`Native.load` keeps it, and the first call of a block function opens it anyway). It is refused by `--deny-native` like `Native.load`.
- A `def` name has no `?` or `!`, even with a C name after `=` (`PARSE-EXTERN-NAME`); parameters take no default (`PARSE-EXTERN-DEFAULT`); only the [types](/library/io-and-system/native/types/) and the block's resources and structs cross (`PARSE-EXTERN-TYPE`).
- The block is public, so its functions, resources and structs are importable from other files, unless it comes after `private`. The functions take the place of `def` functions in the declaration order, and resources and structs the place of types. A block that declares a resource or a struct takes the place of types as a whole, its functions included. In an `extern module` block, a resource takes the place of a `def` instead, like the block's functions.
- `extern` is a keyword only at the start of a top-level declaration, and `resource` only at the start of a line of the block; elsewhere they are ordinary names.

## Running

- A `def` call holds the scheduler that runs it until it returns, so keep such calls short, and use [`compute def`](/library/io-and-system/native/compute/) for the long ones. `--max-steps` cannot stop a call in the middle.
- Tasks on different schedulers (`--schedulers`) make their native calls at the same time, `def` and `compute def` alike, so two calls may be inside one library at once. A library that is not thread-safe needs a lock around its calls: `Native.mutex()` makes a `Native.Mutex`, and `lock.synchronize do ... end` runs the block with it held and gives the block's value. A task that waits for the lock parks, and the other tasks go on; waiters get it in the order they came. The end of the task, a crash or a cancel included, gives it back, but a `compute def` call that the block started keeps it taken until C returns. A task that holds it already and calls `synchronize` again fails with `RUNTIME-NATIVE-MUTEX`. A `Native.Mutex` is no data: it has no `==`, no `to_s`, and is no constant, so a package makes one in its open function and keeps it with its handle.

```agentica {mode="check"}
extern "libm.so.6"
  def cos(x: C.Double) -> C.Double
end

def main() -> Void
  lock = Native.mutex()
  value = lock.synchronize do cos(0.0) end
  puts(value)
end
```

- Native code must retry calls cut short by `EINTR`: GC signals can interrupt sleeps and polls.
- A `RUNTIME-NATIVE-*` or `RUNTIME-INTEGER-OVERFLOW` error of an extern call has its primary span on the `extern def` line; the call site is in the stack.
- Native code is allowed by default and can start programs itself. `agentica --deny-native file.agc` (or any `--deny-*` flag) refuses a program that declares any extern function or calls a `Native.*` builtin before anything runs (`RUNTIME-NATIVE-DENIED`, exit 2). Under `agentica test`, such a test file is a file error with that code. Under these flags a [native module](/library/io-and-system/native/modules/) with a `build` table is not built, and `agentica compile` refuses it (`PKG-NATIVE-BUILD`).
