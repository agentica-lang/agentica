---
title: Types and resources
weight: 1
description: The C types of an extern block, reading memory that C returns, resources that own a C pointer, and out parameters.
---

## Types

| C type | C | In Agentica |
|---|---|---|
| `C.Int32` | `int32_t` / `int` (32 bits) | `Int` |
| `C.Int64` | `int64_t` | `Int` |
| `C.Double` | `double` | `Float` |
| `C.Bool` | `bool` | `Bool` |
| `C.String` | `const char *` | `String` |
| `C.Pointer` | `void *` | `C.Pointer` |
| `C.Bytes` | `const uint8_t *` (parameters only) | `List[Int]` |

`C.Int` is `PARSE-EXTERN-TYPE`: write the width, `C.Int32` or `C.Int64`. A result may also be `Void`, a block may declare resources, and a parameter may be an out parameter (below). A function takes at most 64 parameters (`PARSE-EXTERN-ARITY`).

- A `C.Int32` argument outside 32 bits fails with `RUNTIME-INTEGER-OVERFLOW`, and a `C.String` with a NUL character with `RUNTIME-INVALID-CHARACTER`.
- The C function gets a copy of each string, valid only during the call. A `C.String` result is copied; `NULL` gives `""`, and bytes that are not UTF-8 become U+FFFD. When NULL matters, declare the result `-> C.Pointer` and read it with `Native.string_at` (below).
- A `C.Bytes` argument is a list of bytes: C gets a copy, valid only during the call, and an item outside 0 to 255 fails with `RUNTIME-INVALID-NUMBER`. Pass the length as a parameter of its own. A `C.Bytes` result is `PARSE-EXTERN-TYPE`.
- A `C.Pointer` is a C pointer that your program passes back to C. It may be NULL: `Native.null()` makes one and `Native.null?(p)` tests it. Pointers have no `==`, and `IO.inspect` prints `<C.Pointer>`.

## Reading memory that C returns

A function that returns a pointer and a length, or text that may be NULL, is declared `-> C.Pointer`, and your program copies the memory:

- `Native.string_at(p)` copies the NUL-terminated text at `p`, and `Native.string_at(p, length)` exactly `length` bytes, NUL bytes included. Bytes that are not UTF-8 become U+FFFD.
- `Native.bytes_at(p, length)` copies `length` bytes into a `List[Int]`.
- A NULL `p` with length 0 reads as `""` or `[]`, as C means it (SQLite gives NULL for an empty blob). Any other NULL `p` fails with `RUNTIME-NATIVE-NULL`, so test it with `Native.null?(p)` first. Then a negative length fails with `RUNTIME-INVALID-COUNT`: the pointer is checked first. A length past the memory C owns is undefined behavior, like a wrong signature: Agentica does not check it.
- `Native.pointer(n)` is the pointer with the integer value `n`, for sentinels such as `SQLITE_TRANSIENT`, which is `Native.pointer(-1)`.

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
    puts(Native.string_at(failed.errmsg))   # near "from": syntax error
    sqlite3_free(failed.errmsg)
  end
  Native.close(db)
end
```

## Resources

A resource is a C pointer that your program owns, such as an open stream or a database connection. `resource Name, free: c_function` in the block declares its type and the C function, in the same library, that frees it, as `void c_function(void *)`.

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
- `Native.close(stream)` runs the free function once and closes the resource; closing it again does nothing. A call that takes a closed resource fails with `RUNTIME-NATIVE-CLOSED`.
- A resource the task did not close is freed when the task ends (return, crash or cancel), like a file. `Task.spawn_owning(&work, stream)` hands it to the new task. When `main` returns, the program ends without freeing what is still open.
- A `compute def` call keeps its resource arguments until it returns: if the resource is closed meanwhile, or its task is cancelled, the free runs when the call ends.
- Every resource result is a new pointer that your program owns. A function that returns a pointer its library keeps (a borrowed one) must be declared `-> C.Pointer`, or the pointer is freed twice. The free function cannot also be declared with `def` in its block (`PARSE-EXTERN-FREE`); the check is per block, so do not declare it in another block either.
- A resource is a type: `export resource` makes it importable, and its lines come before the functions that use it. Resources and `C.Pointer` do not convert into each other. `IO.inspect` prints `<Stream>`; a resource has no `to_s` and no JSON.

## Out parameters

A C function that gives a value through a pointer, such as `int sqlite3_open(const char *filename, sqlite3 **db)`, declares that parameter with `out`. The caller does not pass it: C writes into a slot that is zeroed before the call, and the call returns a record with the C result as `result` and one field per out parameter, named after it.

- The record is a struct named after the C name in CamelCase (`sqlite3_open` gives `Sqlite3Open`), exported with its function. A `Void` function's record has no `result`.
- An out parameter is `C.Int32`, `C.Int64`, `C.Double`, `C.Bool`, `C.Pointer` or a resource of the block; anything else is `PARSE-EXTERN-OUT`. For a `char **`, use an out `C.Pointer`.
- An out resource is the resource itself, not a `Result`. When C wrote a pointer, the calling task owns it, as for a resource result. When C wrote NULL or left the slot alone, it is a resource that is closed already: nothing frees it, `Native.close` does nothing, and a call with it fails with `RUNTIME-NATIVE-CLOSED`. Check `result` before you use it.
- A cancelled `compute def` call drops its record; an out resource that C made is freed when the call returns.
