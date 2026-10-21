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

- Native calls work on Linux x86_64 for now. On other systems a program that declares an extern function is refused before it runs (`RUNTIME-NATIVE-UNSUPPORTED`, exit 2); `check` and `compile` work everywhere.
- Native code runs with your program's rights, and a wrong signature is undefined behavior in C: declare each function exactly as its C header does.

## Types

| C type | C | In Agentica |
|---|---|---|
| `C.Int` | `int` (32 bits) | `Int` |
| `C.Int64` | `int64_t` | `Int` |
| `C.Double` | `double` | `Float` |
| `C.Bool` | `bool` | `Bool` |
| `C.String` | `const char *` | `String` |

A result may also be `Void`. A function takes at most 64 parameters.

- A `C.Int` argument outside 32 bits fails with `RUNTIME-INTEGER-OVERFLOW`, and a `C.String` with a NUL character with `RUNTIME-INVALID-CHARACTER`.
- The C function gets a copy of each string, valid only during the call. A `C.String` result is copied; `NULL` gives `""`, and bytes that are not UTF-8 become U+FFFD.

## The block

- The library is passed to the system loader as written: `"libm.so.6"` is looked up where the system finds libraries, and a name with `/` (`"./lib/tool.so"`) is a path, relative to the current folder.
- The library opens at the first call of one of its functions and stays open until the program ends. A library or function that is not found fails that call with `RUNTIME-NATIVE-LOAD`.
- Names are C names, without `?` or `!` (`PARSE-EXTERN-NAME`); parameters take no default (`PARSE-EXTERN-DEFAULT`); only the types above cross (`PARSE-EXTERN-TYPE`).
- `export def` makes a function importable from other files. The functions take the place of `def` functions in the declaration order.
- `extern` is a keyword only at the start of a top-level declaration; elsewhere it is an ordinary name.

## Running

- One native call runs at a time in the whole program, on the scheduler of the task that makes it. `--max-steps` cannot stop a call in the middle; a call counts as 64 steps.
- Native code is allowed by default. `agentica --deny-native file.agc` refuses a program that declares any extern function before anything runs (`RUNTIME-NATIVE-DENIED`, exit 2). `agentica test` does not take the option yet.
