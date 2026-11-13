---
title: Native modules
weight: 6
description: Call C code written for Agentica with Agentica types, a whole result in one call.
---

A native module is C code written against the VM's C API, the header `agentica_native.h`. An `extern module "NAME"` block declares its functions with Agentica types, and the program calls them like any `def`. One call can take and return lists, maps, optionals, results and the program's own structs and enums, such as all the rows of a query, where an [`extern` block](/library/io-and-system/native/) needs a call per C value.

```agentica {mode="check"}
struct Summary
  count: Int
  mean: Float
end

enum Cell
  Empty
  Number(Float)
  Text(String)
end

extern module "stats"
  ## The count and mean of the values; none for no values.
  def summary(values: List[Float]) -> Optional[Summary]
  ## The lines of a CSV text after its header, as maps from the header's names to typed cells.
  def rows(text: String) -> Result[List[Map[String, Cell]]]
  def empty?(text: String) -> Bool
end

def main() -> Void
  puts(summary([2.0, 4.0, 9.0]))
  puts(rows("name,qty\nkiwi,3\n"))
end
```

## The block

- `NAME` is a library as in an `extern` block: a name without `/`, an absolute path, or the `[native.NAME]` of the package's `agentica.toml`.
- Each line is a `def` or `compute def` with no body, named as the module's table names it, `?` and `!` included, or a `resource Name`. `##` docs work as for any `def`, and a resource line takes the place of a `def` in the declaration order. The block is public as a whole, or private as a whole after `private`.
- These types cross: `Int`, `Float`, `Bool`, `String`, `Bytes`, `Void` as the result, a `List`, `Optional` or `Result` of them, a `Map` with `Int`, `String` or `Bytes` keys, aliases of these, and the structs and enums of the program that are not generic, whose fields and payloads cross too. A resource of the block crosses as the whole type of a parameter, and anywhere in a result but in a field or payload. Any other type is `CHECK-NATIVE-TYPE` at it, and so are two such types or resources of one bare name in one block (`A.Row` and `B.Row`): the module knows its types by that name.
- The table names the C function and its types, so a `callback` or `struct` line, a `free:` after a resource, an `out` parameter, a `...` and a C name after `=` are `PARSE-EXTERN-MODULE`, and a `C.` type is `PARSE-EXTERN-TYPE`.
- A `def` is a short call. A `compute def` is a dirty call: it runs on the compute pool while the task waits, as a `compute def` of an `extern` block does, and may block. A task cancelled during one does not stop it: the call runs to its end and its result is dropped.
- A resource is a handle to C state that the module keeps, such as a connection. It belongs to the task that made it. The module's free function frees it once: at `Native.close`, at the end of that task, or at the end of the run, newest first. A call that holds it as an argument keeps it alive until the call returns, whatever closes it meanwhile. `Native.closed?` tells whether it is closed, and a call with a closed one fails with `RUNTIME-NATIVE-CLOSED`.
- Any `--deny-*` flag or `--sandbox` refuses a program with a module block before it runs (`RUNTIME-NATIVE-DENIED`, exit 2), with or without a cached program, and nothing is built: a `build` table starts no compiler, and `agentica compile` under such a flag refuses the module (`PKG-NATIVE-BUILD`).

## Binding

The first call of a function of the block opens the library, as an `extern` block does, and calls its `agentica_native_init` once per run. A library that does not open, has no entry point, or was built for another major version of the API (or a newer minor one) fails that call with `RUNTIME-NATIVE-LOAD`. Then the VM looks the function up by name in the module's table. It must have the same signature, the same mode, and each struct or enum with the same name, fields or variants and types; otherwise the call fails with `RUNTIME-NATIVE-SIGNATURE`. A signature is written canonically: aliases expanded, user types by their bare names, `", "` between parameters and type arguments, then `" -> "` and the result, as in `(List[Float]) -> Optional[Summary]`. A struct's shape is `"count: Int, mean: Float"`, an enum's `"Empty | Number(Float) | Text(String)"`, in declared order.

## The C side

The [native-gen](https://agentica-lang.github.io/packages/native-gen/) package makes a C header from the block: typed prototypes, argument checks and the function and type tables. The C file then holds plain C functions. This section is the API under it.

```c
#include "agentica_native.h"

enum { SUMMARY };

static an_term summary(an_env *env, int argc, const an_term *argv) {
  an_list_cursor c;
  an_term item;
  size_t n;
  double total = 0, x;
  (void)argc;
  if (!an_list_cursor_begin(env, argv[0], &c, &n)) return an_badarg(env, 0);
  if (n == 0) return an_none(env);
  while (an_list_next(env, &c, &item)) {
    if (!an_get_float(env, item, &x)) return an_badarg(env, 0);
    total += x;
  }
  an_term fields[2] = {an_int(env, (int64_t)n), an_float(env, total / n)};
  return an_some(env, an_struct(env, SUMMARY, fields));
}

static const an_type types[] = {{"Summary", AN_STRUCT, "count: Int, mean: Float"}};

static const an_function functions[] = {
  {"summary", "(List[Float]) -> Optional[Summary]", summary, AN_SHORT},
};

AN_MODULE_TYPES("stats", functions, types, NULL)
```

- `AN_MODULE(NAME, FUNCTIONS, LOAD)` defines the entry point of a module without types, `AN_MODULE_TYPES(NAME, FUNCTIONS, TYPES, LOAD)` of one with them, and `AN_MODULE_TABLES(NAME, FUNCTIONS, FUNCTION_COUNT, TYPES, TYPE_COUNT, RESOURCES, RESOURCE_COUNT, LOAD)` of one with resources (`NULL, 0` for a table it does not have). `LOAD` is `NULL` or a function that runs once after the entry point and returns `NULL` or a message that refuses the module.
- A row of the function table is the name, the canonical signature, the C function and its mode, `AN_SHORT` (or `AN_DIRTY` for a `compute def`). A row of the type table is the bare name, `AN_STRUCT` or `AN_ENUM`, and the shape; its index is the type that `an_struct`, `an_get_field`, `an_enum`, `an_get_variant` and `an_get_payload` take, and fields, variants and payloads count from 0. Two rows of one name refuse the module (`RUNTIME-NATIVE-LOAD`).
- Values are opaque terms. Every getter (`an_get_int`, `an_get_string`, `an_list_next`, `an_map_get`, `an_get_optional`, `an_get_result`, `an_get_field`, `an_get_variant`, `an_get_payload` and the others) returns `false` for a term of another type, or a field or payload out of range. The data of a String or Bytes is borrowed and read-only: copy it to keep it.
- A term lasts until the function returns: keep it in C locals, never in static data, `malloc` memory or across calls.
- `an_raise(env, message)` and `an_badarg(env, index)` fail the call, and so does a constructor that gets bad input (text that is not UTF-8, a Map key that is not an `Int`, `String` or `Bytes`, a type the signature does not reach). The call then fails with `RUNTIME-NATIVE-ERROR` at the `def` line once the function returns, whatever it returns; the call site is in the stack. A result of another type than the signature's is `RUNTIME-NATIVE-ERROR` too.
- A row of the resource table is the name, the size of its C state, and the function that frees the state (or `NULL`); its index is the type of `an_resource_new` and `an_get_resource`. `an_resource_new(env, type, &term)` makes a resource and gives its zeroed state; `an_get_resource(env, term, type, &state)` gives the state of a resource argument of the call. The state holds C data only, never a term: a per-connection cache of prepared statements lives there, and the free of the connection finalizes them. The free function gets the state alone, and the VM frees the memory after it.
- A dirty function reads its arguments in place. An Int, Float, Bool or Void it makes, `none` and a variant without a payload are values at once, and the getters read them. Any other term its constructors make (a String, Bytes, List, Map, `some`, `ok`, `error`, struct, variant with a payload or resource) is kept apart and becomes a value once the call returns, so a getter gives `false` for it.
- A short function runs on the scheduler of the calling task, at the same time as the calls of other schedulers, so it must be thread-safe (or the program guards it with [`Native.mutex()`](/library/io-and-system/native/)). It may allocate and build large results, but must not block, sleep, wait on I/O or run longer than about 100 microseconds. A callback of an extern block that it starts runs nothing and gives zero.
- `an_blocking(env, fn, arg)` (API 1.3) runs `fn(arg)` where the collector does not stop the thread: use it around a C library call that switches to a stack of its own, such as a `_start` or `_cont` call of MariaDB Connector/C's non-blocking API. It works in short and dirty functions alike. `fn` may use the module's own memory and the state of a resource that `an_get_resource` or `an_resource_new` gave in the call, and read the String and Bytes data of the call's arguments that a getter gave before; nothing else of the VM: no term, no write to GC memory, no API call. The argument data lasts until the call returns: data that a C library keeps across calls (the query of a `_start` that a later `_cont` finishes) is copied into the resource state or other `malloc` memory. In a short function it still holds up the scheduler, so a call that waits belongs in a `compute def`.
- The module links nothing of `agentica`: every call goes through a table that the VM passes in. A `build` table in `[native.NAME]` of `agentica.toml` (`build = { sources = ["native/stats.c"] }`) has a run build it with the system C compiler and the header of the running binary (see [packages](/tour/modules/)). With `optional = true` beside it, a module that cannot be built is a warning and the program runs without it, so the package checks `Native.load("stats")` before it calls the module. To build it yourself: on Linux `cc -std=c11 -shared -fPIC -o libstats.so stats.c`, on macOS `-dynamiclib`, on Windows `-shared` (a DLL), with the `include/agentica_native.h` of the release archive of the version that runs the module.
- A crash in a module ends the program, as a crash in an extern library does.
- The [profile](/library/testing/profile/) (`AGENTICA_VM_TRACE=profile`) has a `native` row per module function that ran: its calls, the microseconds in C, and its mode.
