# FFI examples

Small runnable examples of calling C from Agentica (`extern` blocks,
`C` types, `Native`). They all use one tiny teaching library, `demo.c`
(only the C library, no other dependencies): plain arithmetic, not a model.
Each pattern is the same one real numeric or inference runtimes use, with a
note saying which.

- [`calls.agc`](calls.agc): plain typed calls, plus one `compute def` whose
  input bounds the work (kept small here).
- [`records_and_buffers.agc`](records_and_buffers.agc): a small struct passed
  by value, an owned resource with a destructor and an explicit
  `Native.close`, and a caller-owned float buffer that C fills and reads.
- [`function_table.agc`](function_table.agc): dispatch through a table of
  typed C function pointers, the shape of APIs like onnxruntime's `OrtApi`.
- [`duckdb/`](duckdb/): the same shapes against the real DuckDB C API
  (pinned v2.0.0): version check, `:memory:` open and connect, typed rows,
  a captured SQL error, and CSV and Parquet `COPY` roundtrips.

## Build the library

From this folder, build the library for your system (it is ignored by git;
only `demo.c` is committed):

```sh
# Linux
cc -shared -fPIC -O1 -o native/linux/libdemo.so demo.c
# macOS
cc -dynamiclib -O1 -o native/macos/libdemo.dylib demo.c
# Windows
cc -shared -O1 -o native/windows/demo.dll demo.c
```

`agentica.toml` maps the name `demo` in the `extern` blocks to the built
file of the running system. `check` and `run` need the file to exist.

## Run

From the repository root:

```sh
dist/agentica examples/ffi/calls.agc
dist/agentica examples/ffi/records_and_buffers.agc
dist/agentica examples/ffi/function_table.agc
```

Expected output:

```text
42
-3.0
5050
```

```text
7
13
error("demo_acc_open returned NULL")
3.0
```

```text
42
-3.0
true
demo-api-1
```

## How the patterns map to real C APIs

- Plain `extern` calls wrap one C function each; a `compute def` keeps a
  long call (a large numeric transform, a blocking encode step) off the
  task's thread.
- Structs by value carry small option/result records; resources wrap owned
  handles (a context, a session) whose destructor runs at `Native.close` or
  at the end of the owning task; caller-owned buffers move plain arrays
  (float or int features, token ids) without copying through Agentica lists.
- A versioned table of function pointers is how plugin-style APIs publish
  many entry points through one handle: read a slot with
  `Native.get_pointer`, call it through a `C.Function` parameter.
