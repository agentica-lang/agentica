---
title: Getting started
weight: 1
description: Install Agentica, run your first program and check it.
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
- `TCP`, `TLS` and `std/http` run and are tested on Linux, macOS and Windows.

### Build from source

Needs a C11 compiler and `make`; on Linux also `libssl-dev`, `libgc-dev` and `pkg-config` (OpenSSL 3, libgc 8.2 or newer). The build starts from the checked-in `bootstrap/stage0.agcb` and needs no other tool. It also runs on macOS and Windows (MSYS2 UCRT64).

```sh
git clone https://github.com/agentica-lang/agentica.git
cd agentica
git submodule update --init
make    # writes dist/agentica
```

A default build links the system OpenSSL, so `dist/agentica` runs only where it is installed; the release archive is portable. `AGENTICA_GC=vendored` and `AGENTICA_OPENSSL=vendored` build the bundled copies, each on its own (only OpenSSL needs Perl 5 and a few minutes). Pass them to every `make` command, or export them.

## Hello, world

```agentica
def main() -> Void        # every program starts at main
  puts("Hello, world!")
end
```

Save it as `hello.agc` and run it:

```sh
agentica hello.agc
```

```output
Hello, world!
```

## Check

`agentica check hello.agc` checks types without running and prints `check ok`. An error prints a stable code, such as `CHECK-TYPE-MISMATCH`, with its file, line and column, and exits with code 1. The [command line page](/cli/#check-and-errors) has the details.

## Next

- Take the [language tour](/tour/) first, one idea at a time.
- Then look up the builtins in the [library](/library/).
- The [command line](/cli/) page lists every command, option and cache.
