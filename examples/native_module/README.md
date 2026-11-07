# Native module example

A native module is C code written against the VM's C API
(`agentica_native.h`), which a program calls through an `extern module`
block with Agentica types. [`native/stats.c`](native/stats.c) is one with two
functions: `summary` gives a struct in an `Optional`, and `rows` reads a CSV
text into rows of typed cells (an enum), each in one call.

## Build the module

`agentica.toml` names the C file in the `build` table of `[native.stats]`:

```toml
[native.stats]
build = { sources = ["native/stats.c"] }
```

The first run builds it with the system C compiler (`cc`, `gcc` on Windows,
or the one `CC` names) into the package cache, and prints
`built native stats: PATH` on stderr. A later run that finds the sources
unchanged uses that build. `check` never builds.

## Run

From the repository root:

```sh
dist/agentica examples/native_module/stats.agc
```

Expected output:

```text
some(Summary(count: 3, min: 2.0, max: 9.0, mean: 5.0))
none
{"name": Cell.Text("kiwi"), "qty": Cell.Number(3.0), "note": Cell.Empty}
{"name": Cell.Text("apple"), "qty": Cell.Number(1.5), "note": Cell.Text("ripe")}
error("a row has another number of cells")
```
