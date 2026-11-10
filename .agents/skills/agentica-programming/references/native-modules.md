# Native modules

A native module is C code written against the VM's C API
(`agentica_native.h`). An `extern module "NAME"` block declares its functions
with Agentica types; one call can take and return lists, maps and the
program's structs and enums. The native-gen package
(https://agentica-lang.github.io/packages/native-gen/) makes a C header from
the block: typed prototypes, the argument checks and the tables.

~~~ruby
struct Summary
  count: Int
  mean: Float
end

extern module "stats"
  ## The count and mean of the values; none for no values.
  def summary(values: List[Float]) -> Optional[Summary]
  def empty?(text: String) -> Bool
end
~~~

- `NAME` is a library as in an `extern` block (a name, an absolute path, or
  the package's `[native.NAME]`).
- Names are the module table's, `?` and `!` allowed. Only `def`,
  `compute def` and `resource Name` lines; `callback`, `struct`, `out`, `...`,
  `= "symbol"` and `free:` after a resource are `PARSE-EXTERN-MODULE`; a `C.`
  type is `PARSE-EXTERN-TYPE`.
- Types that cross: `Int`, `Float`, `Bool`, `String`, `Bytes`, `Void` (result),
  `List`, `Optional`, `Result` of them, `Map` with `Int`, `String` or `Bytes`
  keys, and non-generic structs and enums of the program whose fields cross.
  A resource of the block crosses as a whole parameter type, and in a result
  anywhere but in a field. Anything else, or two crossing types of one bare
  name in a block, is `CHECK-NATIVE-TYPE`.
- A resource belongs to the task that made it and is freed once: at
  `Native.close`, at the task's end or at the end of the run; a call holding
  it delays the free to its end. A closed one is `RUNTIME-NATIVE-CLOSED`.
- The first call binds the function: the module's table must have the same
  canonical signature, mode and type shapes, else `RUNTIME-NATIVE-SIGNATURE`;
  a library that does not load is `RUNTIME-NATIVE-LOAD`. A `compute def` runs
  on the compute pool while the task waits and may block; a cancel drops its
  result but does not stop it.
- `an_raise`, `an_badarg` or a bad constructor in C fail the call with
  `RUNTIME-NATIVE-ERROR` at the `def` line.
- The C side ends with `AN_MODULE_TYPES("stats", functions, types, NULL)`
  (`AN_MODULE` without types, `AN_MODULE_TABLES` with resources): function
  rows such as
  `{"summary", "(List[Float]) -> Optional[Summary]", summary, AN_SHORT}` and
  type rows such as `{"Summary", AN_STRUCT, "count: Int, mean: Float"}`. Each
  getter returns `false` for another type; terms last until the C function
  returns. A short function is thread-safe and never blocks or sleeps.
- A resource row is `{"Db", sizeof(db_state), db_free}`; `an_resource_new`
  makes one and gives its zeroed state, `an_get_resource` gives the state of a
  resource argument. A dirty function's getters give `false` for terms it
  made.
- `an_blocking(env, fn, arg)` (API 1.3) runs `fn(arg)` out of the
  collector's way, in short and dirty functions: wrap a C library call that
  switches stacks (MariaDB Connector/C's non-blocking `_start`/`_cont`) in it.
  `fn` may only read String and Bytes data of the arguments got before; no
  terms, no API calls.
- `[native.NAME] build = { sources = ["native/stats.c"], defines = [...],
  libs = ["m"] }` in `agentica.toml` builds the module with the system C
  compiler (`CC`, else `cc`; `gcc` on Windows) on a run, `compile`, `test` or
  `install` (never `check`), into the package cache, printing
  `built native NAME: PATH`. Sources are `.c` files in `native/`; defines are
  `NAME[=VALUE]`; libs are names for `-l`. A bad item is
  `PKG-MANIFEST-INVALID` at its key path, a missing source
  `PKG-NATIVE-MISSING`, a failed build `PKG-NATIVE-BUILD` at
  `native.NAME.build`. A run builds a library when a file first uses it;
  under any `--deny-*` flag or `--sandbox` nothing builds: the run is
  `RUNTIME-NATIVE-DENIED`, `compile` is `PKG-NATIVE-BUILD`. Keep your own
  headers under `native/`: the cache key does not cover system headers,
  installed libraries or the environment beyond `CPATH`, `C_INCLUDE_PATH`,
  `CPLUS_INCLUDE_PATH` and `LIBRARY_PATH`; to rebuild, remove the entry or
  change a file under `native/`. A fetched package builds too, on first use
  only (`install` does not build it): from a private copy of the `native/`
  files its locked hash covers (`PKG-HASH-MISMATCH` if `deps/` differs), so
  dotfiles are left out and a header outside `native/` is not found.
- `optional = true` beside `build` (it needs `build`): a module that cannot
  be built (no compiler, a compile error) prints `warning: native module NAME
  not built: ...` once a run on stderr (`PKG-NATIVE-UNBUILT`, a JSON object
  with `"warning": true` under `--json`), and the program runs without it.
  Every run compiles the program and tries the build again.
  `Native.load("NAME")` then gives `error` and a call of the module is
  `RUNTIME-NATIVE-LOAD`, so check `Native.load` before using the module and
  fall back. A program that `compile` wrote then never opens the module.
