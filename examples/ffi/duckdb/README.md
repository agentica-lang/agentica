# DuckDB through the C API

A full DuckDB flow in one teaching-sized program: `duckdb.agc` wraps the C
API with private scope helpers and `main.agc` runs version check, `:memory:`
open and connect, small resource limits, a typed table, ordered reads of
`INTEGER`, `BIGINT`, `DOUBLE`, `VARCHAR` and `NULL`, one captured SQL error
followed by queries that keep working, and CSV and Parquet `COPY` roundtrips
with counts and typed rows compared. No C shim, no new builtins, no extra
package.

This is an integration example, not a binding: it covers exactly the calls
the flow needs (open, close, connect, disconnect, query, destroy, typed cell
readers, `duckdb_free`, the version string) and stops there. No prepared
statements, callbacks, Arrow, or catalog helpers.

## Run

The library is never committed. Stage exactly one pinned file per system with
the provisioner (it checks the archive hash before it unpacks anything):

```sh
python3 tools/provision_duckdb.py --out examples/ffi/duckdb
ls examples/ffi/duckdb/native/linux/libduckdb.so
```

That lays out `native/<os>/...` under this folder, matching `agentica.toml`.
To do it by hand instead, download the asset for your system from the
[v2.0.0 release](https://github.com/duckdb/duckdb/releases/tag/v2.0.0),
check its SHA-256 against the table below, and unpack only the library:

| system | asset | SHA-256 | member to keep |
| --- | --- | --- | --- |
| Linux x86_64 | `duckdb-shared-libs-linux-amd64.tar.gz` | `993ad89e7dfca66cd6da994c2cad090c2fc160ddf9f550498a098ab4bb13cfb1` | `libduckdb.so` |
| Windows x86_64 | `duckdb-shared-libs-windows-amd64.tar.gz` | `2b83169128239de5f45fe21de80f99bf436e53aa4bb24020dd951a1ba8d4b95f` | `duckdb.dll` |
| macOS x86_64 and arm64 | `duckdb-shared-libs-osx-universal.tar.gz` | `14cd63180614cfd961f7959146ecd9087527ff20b67311efdc3fa1c29c18204d` | `libduckdb.dylib` |

Then, from the repository root:

```sh
dist/agentica examples/ffi/duckdb/main.agc /tmp/duckdb-out
```

Expected output (the `error:` line is the captured SQL error; the run keeps
going after it):

```text
duckdb v2.0.0
columns: 4
rows: 4
1|10000000000|9.5|Ada
2|-42|-0.25|Böb "Jr"
3|0|NULL|NULL
4|7|3.125|O'Brien
error: Catalog Error: Table with name no_such_table_xyz does not exist!
csv rows: 4
csv header: id,code,score,name
parquet rows: 4
```

The program takes one argument, the output directory. It must not exist yet:
its parent must exist, the program creates it private, and it refuses to
overwrite anything. Paths come from the argument, never from a literal, so a
Windows path with backslashes works: inside SQL the path sits in single
quotes, where a backslash stays literal, and a `'` in a path doubles to `''`.

## How the cleanup works

`duckdb_close` and `duckdb_disconnect` take a pointer to the handle, not the
handle value, so a `resource` free (which gets the value) cannot close them.
Each handle instead lives in an 8-byte slot the task owns; the helpers pass
the slot where C wants the pointer, read the handle out for the calls that
want the value, and close through the slot before freeing it, on success and
on error alike. The result buffer (`Native.size_of(DuckdbResult)`, the
`duckdb_result` struct declared in the file) is freed with
`duckdb_destroy_result` after the error text is copied; `duckdb_value_varchar`
results are copied and then `duckdb_free`d.

A halt, a task cancel, or a runtime abort does not run this cleanup: raw C
handles have no destructor here. That is the known limit of the pattern, so
the example keeps every handle on the main task and never spawns around a
live one. Counts cross as `C.Int64`: exact for the small numbers here, not a
claim about the full `uint64_t` range.
