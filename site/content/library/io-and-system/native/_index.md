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

- Native calls work on Linux x86_64 and Windows x64 for now, and `Native.wait_*` on Linux x86_64 (not supported on Windows, where it returns an error). On other systems a program that declares an extern function or calls a `Native.*` builtin is refused before it runs (`RUNTIME-NATIVE-UNSUPPORTED`, exit 2); `check` and `compile` work everywhere.
- Native code runs with your program's rights, and a wrong signature is undefined behavior in C: declare each function exactly as its C header does.
- Put `##` docs on the `def` lines inside the block.

The rest of the section has its own pages:

- Use [Types and resources](/library/io-and-system/native/types/) for the C types, resources and out parameters.
- Use [SQLite](/library/io-and-system/native/sqlite/) for a full example: a library behind safe functions that return `Result`.
- Use [Compute calls](/library/io-and-system/native/compute/) for a call that may take long: the other tasks keep running.
- Use [Waiting on a descriptor](/library/io-and-system/native/waiting/) to wait for a socket or descriptor without stopping the other tasks.

## The block

- The library is a plain string: a name without `/` (`"libm.so.6"`), which the system looks up, or an absolute path (`"/opt/tool/libtool.so"`). Anything else is `PARSE-EXTERN-LIBRARY`. The working directory is never searched. On Windows a name (`"ucrtbase.dll"`) is looked up next to `agentica.exe` and in the system folder, not in `PATH`; write an absolute path with escaped backslashes (`"C:\\libs\\x.dll"`), and the DLLs it needs are searched in its folder and the default folders, never in `PATH` (a MinGW DLL that needs `libgcc_s_seh-1.dll` must have it next to it).
- The library opens at the first call of one of its functions and stays open. A library, dependency or function that is not found fails that call with `RUNTIME-NATIVE-LOAD`.
- Names are C names, without `?` or `!` (`PARSE-EXTERN-NAME`); parameters take no default (`PARSE-EXTERN-DEFAULT`); only the [types](/library/io-and-system/native/types/) and the block's resources cross (`PARSE-EXTERN-TYPE`).
- `export def` makes a function importable from other files. The functions take the place of `def` functions in the declaration order, and resources the place of types.
- `extern` is a keyword only at the start of a top-level declaration, and `resource` only at the start of a line of the block; elsewhere they are ordinary names.

## Running

- A `def` call blocks timers, I/O and other tasks until it returns, so keep such calls short, and use `compute def` for the long ones. `--max-steps` cannot stop a call in the middle.
- Native code must retry calls cut short by `EINTR`: GC signals can interrupt sleeps and polls.
- Native code is allowed by default and can start programs itself. `agentica --deny-native file.agc` (or any `--deny-*` flag) refuses a program that declares any extern function or calls a `Native.*` builtin before anything runs (`RUNTIME-NATIVE-DENIED`, exit 2). Under `agentica test`, such a test file is a file error with that code.
