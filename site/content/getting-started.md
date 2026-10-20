---
title: Getting started
weight: 1
description: Install Agentica, run your first program, check it and read its errors.
---

## Install

{{% release %}}

Get the archive for your system, check it, unpack it and put its `bin` folder on your `PATH`. The archive holds `bin/agentica` (or `bin\agentica.exe`) and needs no other library.

| System | Archive | Minimum |
|---|---|---|
| Linux x86-64 | `agentica-VERSION-linux-x86_64.tar.gz` | glibc 2.28 (Debian 10, Ubuntu 18.10, RHEL 8) |
| macOS Intel | `agentica-VERSION-macos-x86_64.tar.gz` | macOS 12 |
| macOS Apple silicon | `agentica-VERSION-macos-arm64.tar.gz` | macOS 12, native (no Rosetta) |
| Windows x86-64 | `agentica-VERSION-windows-x86_64.zip` | Windows 10 (no MSYS2 or Visual C++ runtime) |

```sh
# Linux (macOS: shasum -a 256 -c SHA256SUMS --ignore-missing)
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf agentica-VERSION-linux-x86_64.tar.gz
```

```powershell
# Windows: compare the hash with SHA256SUMS
Get-FileHash agentica-VERSION-windows-x86_64.zip
Expand-Archive agentica-VERSION-windows-x86_64.zip .
```

- The archives are not signed or notarized. The checksum file is the only proof of origin.
- macOS refuses a browser download with a quarantine mark. Remove it with `xattr -d com.apple.quarantine bin/agentica`. A `curl` download has no mark.
- Windows SmartScreen may warn the first time.

`TCP` works on Linux, macOS and Windows. `TLS` and `std/http` work on Linux and macOS; on Windows a `TLS` call returns an error and `std/http` is not there yet.

### Build from source

You need a C11 compiler (gcc or clang), `make`, and on Linux `libssl-dev`, `libgc-dev` and `pkg-config` (Debian and Ubuntu names; OpenSSL 3 and libgc 8.2 or newer).

```sh
git clone https://github.com/sonic182/agentica.git
cd agentica
git submodule update --init
make
```

`make` writes `dist/agentica`. It runs where its system OpenSSL is installed.

- Without system libraries, use `make AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored`. Vendored OpenSSL needs Perl 5 and takes a few minutes.
- The build also runs on macOS and Windows (MSYS2 UCRT64).

## Hello, world

Save this as `hello.agc`:

```agentica
def main() -> Void        # every program starts at main
  puts("Hello, world!")   # prints a value and a new line
end
```

```sh
agentica hello.agc
```

```output
Hello, world!
```

## Arguments

Words after the file name reach the program through `System.args()`:

```agentica {mode="check"}
def main() -> Void
  for name in System.args()
    puts("Hello, #{name}!")
  end
end
```

```sh
agentica greet.agc Ana Bob
```

```text
Hello, Ana!
Hello, Bob!
```

## Check without running

`agentica check` checks types and does not run the program:

```sh
agentica check hello.agc
```

```text
check ok
```

Every run checks the program first, so a type error stops it before any output.

## Read an error

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1          # count is an Int
  count = "two"      # error: a String does not fit
  puts(count)
end
```

The checker stops at the first error. It prints the place, a stable code and often a `help` line:

```text
bad.agc:3:11 error[CHECK-TYPE-MISMATCH]
expected Int, found String

3 |   count = "two"
  |           ^^^^^
  = help: convert it with String.to_int!(...)
```

- Exit code `1`: the program has an error.
- Exit code `2`: a bad command or a file that cannot be read.
- Codes start with `LEX-`, `PARSE-`, `CHECK-` or `RUNTIME-`.

`--ai` and `--json` print the same error for tools:

```sh
agentica --json bad.agc
```

```text
{"actual":"String","code":"CHECK-TYPE-MISMATCH","expected":"Int","file":"bad.agc","function":"main() -> Void","help":"convert it with String.to_int!(...)","message":"expected Int, found String","range":{"end":{"column":16,"line":3},"start":{"column":11,"line":3}}}
```

A runtime error also prints the call stack, innermost call first. The rules are in [Diagnostics](/reference/).

```text
nested.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]
index 5 is outside a list of length 3

2 |   return xs[i] + 1
  |             ^
  = stack, innermost first:
    pick at nested.agc:2:13
    load at nested.agc:6:10
    main at nested.agc:11:8
```

## Look up a builtin

`agentica help NAME` prints a builtin's signature. `agentica help` alone lists the commands and namespaces.

```sh
agentica help String.split
```

```text
String.split(s: String, separator: String) -> List[String]
Split text; an empty separator gives characters.
```

## Options

| Option | Does |
|---|---|
| `--max-steps N` | stops after `N` steps (`RUNTIME-STEP-LIMIT`) |
| `--seed N` | makes `Random` repeat the same numbers |
| `--flush-timeout MS` | waits at most `MS` ms for file data and output at the end; then the run ends with a warning. Default 30000, most 86400000 (24 hours). Env `AGENTICA_FLUSH_TIMEOUT_MS`; the flag wins |
| `--schedulers N` | scheduler threads, 1 to 1024. Env `AGENTICA_SCHEDULERS`; the flag wins. A bad value exits with code 2. This build runs one scheduler, so a larger number exits with code 2 |
| `--allow-run` | lets the program start programs with `Process.spawn` |
| `--dump` | prints the checked program tree instead of running it |
| `--dump-ir` | prints the lowered VM IR instead of running it |
| `compile FILE -o OUT` | writes VM bytecode; `agentica run -- OUT` runs it |
| `run [OPTIONS] -- FILE.agcb [ARGS...]` | runs bytecode. Options before `--`: `--max-steps`, `--seed`, `--flush-timeout`, `--schedulers`, `--allow-run`, `--source-root DIR`, `--ai`, `--json`. `run` must be the first word. `run --version` also lists the linked libraries |
| `--version` | prints the version |

## Test

```sh
agentica test
agentica test test/ports_test.agc --only port
```

`agentica test` runs `*_test.agc` files ([Test](/library/testing/test/)) and `.feature` specs ([BDD](/library/testing/bdd/)). With no paths it looks in `test/` and `specs/`. `--only TEXT` runs the tests whose name contains `TEXT`.

## Next

Take the [language tour](/tour/), starting with [values and types](/tour/values-and-types/).
