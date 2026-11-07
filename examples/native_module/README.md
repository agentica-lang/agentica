# Native module example

A native module is C code written against the VM's C API
(`vm/agentica_native.h`), which a program calls through an `extern module`
block with Agentica types. [`stats.c`](stats.c) is one with two functions:
`summary` gives a struct in an `Optional`, and `rows` reads a CSV text into
rows of typed cells (an enum), each in one call.

## Build the module

From this folder, build the module for your system (it is ignored by git; only
`stats.c` is committed). It links nothing of `agentica`:

```sh
# Linux
cc -std=c11 -shared -fPIC -O2 -o native/linux/libstats.so stats.c
# macOS
cc -std=c11 -dynamiclib -O2 -o native/macos/libstats.dylib stats.c
# Windows
cc -std=c11 -shared -O2 -o native/windows/stats.dll stats.c
```

`agentica.toml` maps the name `stats` of the block to the built file of the
running system. `check` and `run` need the file to exist.

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
