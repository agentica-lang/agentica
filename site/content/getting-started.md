---
title: Getting started
weight: 1
description: Install Agentica, run your first program, check it and read its errors.
---

## Install

{{% release %}}

Download the archive of your system, check it against `SHA256SUMS`, unpack it anywhere (spaces and non-ASCII letters are fine) and put its `bin` folder on your `PATH`. It holds one program and needs no other library.

| System | Archive | Minimum |
|---|---|---|
| Linux x86-64 | `agentica-VERSION-linux-x86_64.tar.gz` | glibc 2.28 |
| macOS Intel | `agentica-VERSION-macos-x86_64.tar.gz` | macOS 12 |
| macOS Apple silicon | `agentica-VERSION-macos-arm64.tar.gz` | macOS 12, native (no Rosetta) |
| Windows x86-64 | `agentica-VERSION-windows-x86_64.zip` | Windows 10 (system DLLs and the UCRT; no MSYS2 or Visual C++ redistributable) |

```sh
sha256sum -c --ignore-missing SHA256SUMS   # macOS: shasum -a 256 -c ... ; Windows: Get-FileHash
tar -xzf agentica-VERSION-linux-x86_64.tar.gz   # Windows: Expand-Archive
```

- The archives are not developer-signed or notarized (macOS programs carry only the ad hoc signature Apple silicon requires). `SHA256SUMS` is the only proof of origin.
- macOS blocks a browser download: run `xattr -d com.apple.quarantine bin/agentica` (a `curl` download has no mark). Windows SmartScreen may warn once.
- `TCP` and `TLS` work on Linux, macOS and Windows. `std/http` is not on Windows yet.

### Build from source

Needs a C11 compiler and `make`; on Linux also `libssl-dev`, `libgc-dev` and `pkg-config` (OpenSSL 3, libgc 8.2 or newer). The build starts from the checked-in `bootstrap/stage0.agcb` and needs no other tool. It also runs on macOS and Windows (MSYS2 UCRT64).

```sh
git clone https://github.com/sonic182/agentica.git
cd agentica
git submodule update --init
make    # writes dist/agentica
```

- A default build links the system OpenSSL, so `dist/agentica` runs only where it is installed. The release archive is portable.
- `AGENTICA_GC=vendored` and `AGENTICA_OPENSSL=vendored` build the bundled copies, each on its own (only OpenSSL needs Perl 5 and a few minutes). Pass them to every `make` command, or export them.

## Hello, world

```agentica
def main() -> Void        # every program starts at main
  puts("Hello, world!")
end
```

```sh
agentica hello.agc
```

```output
Hello, world!
```

Words after the file name reach the program through `System.args()`:

```agentica {mode="check"}
def main() -> Void
  for name in System.args()
    puts("Hello, #{name}!")
  end
end
```

```sh
agentica greet.agc Ana Bob    # prints one greeting per name
```

## Check and errors

`agentica check hello.agc` checks types without running and prints `check ok`. Every run checks first, so a type error stops it before any output. The checker stops at the first error:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1          # count is an Int
  count = "two"      # error: a String does not fit
  puts(count)
end
```

```text
bad.agc:3:11 error[CHECK-TYPE-MISMATCH]
expected Int, found String

3 |   count = "two"
  |           ^^^^^
  = help: convert it with String.to_int!(...)
```

- Exit code `1`: the program has an error. Exit code `2`: a bad command or an unreadable file.
- Codes start with `LEX-`, `PARSE-`, `CHECK-` or `RUNTIME-`. A runtime error also prints the call stack. See [Diagnostics](/reference/).
- `--ai` and `--json` print the same error for tools: `{"code":"CHECK-TYPE-MISMATCH","file":"bad.agc","range":{...},...}`.

## Look up a builtin

```sh
agentica help String.split    # `agentica help` alone lists commands and namespaces
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
| `--flush-timeout MS` | waits at most `MS` ms for file data and output at the end, then warns. Default 30000, most 86400000. Env `AGENTICA_FLUSH_TIMEOUT_MS` |
| `--schedulers N` | scheduler threads, 1 to 1024. Env `AGENTICA_SCHEDULERS`. This build runs one; a larger number or a bad value exits with code 2 |
| `--allow-run` | lets the program start programs with `Process.spawn` |
| `--dump`, `--dump-ir` | print the checked tree or the lowered IR instead of running |
| `compile FILE -o OUT` | writes VM bytecode |
| `run [OPTIONS] -- FILE.agcb [ARGS...]` | runs bytecode; `run` must be the first word. Options: the ones above except `--dump*`, plus `--source-root DIR`, `--ai`, `--json`. `run --version` lists the linked libraries |
| `--version` | prints the version |

A flag wins over its environment variable.

## Test

```sh
agentica test                                    # test/ and specs/
agentica test test/ports_test.agc --only port    # only tests whose name has "port"
```

Runs `*_test.agc` files ([Test](/library/testing/test/)) and `.feature` specs ([BDD](/library/testing/bdd/)).

## Next

Take the [language tour](/tour/).
