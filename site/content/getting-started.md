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
- `TCP`, `TLS` and `std/http` run and are tested on Linux, macOS and Windows.

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

`agentica check hello.agc` checks types without running and prints `check ok`. Every run checks first, so a type error stops it before any output. `check` accepts a file without `main`; a run or `compile` needs `def main() -> Void`. The checker stops at the first error:

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

## Read a module's API

```sh
agentica doc std/queue    # a file path works too; --json prints one JSON object
```

It prints the exported declarations in source order, each with its signature and its `##` doc, and a struct's fields or an enum's variants. It only reads the file: the module's imports need not exist. Declarations without `export` are left out.

## Query the code

`outline`, `type-at`, `symbol` and `refs` answer questions about the code, for editors and agents. None of them runs the program. Each prints text, or one JSON object with `--json`. Exit codes: `0` answered, `1` the code has an error (its first diagnostic is the answer), `2` a bad question or an unreadable file. The `QUERY-` codes are `QUERY-USAGE` (bad arguments or file), `QUERY-NO-EXPRESSION` (no expression at the position), `QUERY-NOT-FOUND` and `QUERY-AMBIGUOUS-NAME`; see [Diagnostics](/reference/).

## List a file's declarations

```sh
agentica outline src/orders.agc    # --json prints one JSON object; std/queue works too
```

```text
src/orders.agc:3:1 export struct Order
src/orders.agc:4:3 field Order.id: Int
src/orders.agc:8:1 export def total(order: Order) -> Int
src/orders.agc:14:1 def round_cents(value: Float) -> Int
```

`outline` only parses its file, so the imports need not exist. It prints each declaration with `file:line:column` first, like `rg`, and private ones too. `--json` adds the `##` doc, the signature, `exported`, the spans and the fields or variants.

## Type at a position

```sh
agentica type-at src/orders.agc:22:14    # --json for one object; --stdin FILE:LINE:COL reads FILE from standard input
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

Line and column count from 1, in code points (an emoji is one column). The first line is the type of the expression and its span; the next is its definition (for a builtin, its signature). `type-at` checks the file and what it imports, but needs no `main`. A type of another file is written through the import alias (`Models.User`). A local, a parameter or a loop variable has a type and a definition at its binding. A type name in an annotation or a type argument (`Models.User`) has `kind` `type` and the struct, enum or alias it names as definition; a builtin type (`Int`, `List`) has none. A builtin (`split` in `xs.split(",")`) has no definition; with `--json` it has `kind` `builtin` and the object of `agentica help NAME --json` under `help`.

## Find a name

```sh
agentica symbol Models.User.email src/    # PATH is a file or a folder, default .
```

```text
src/models.agc:4:3 field User.email: String
```

NAME is written as the code writes it: `total`, `User.email`, `Option.Some`, `Models.User` through the import alias of a file under PATH, `std/queue.pop` or a builtin (`Map.get`). A bare name lists every module that declares it, private declarations too. The files under PATH are linked together; one that does not link is listed under `skipped` and the others still answer. `--json` adds `kind`, `module`, `exported`, `signature`, `doc` and the spans to each match.

## Find references

```sh
agentica refs Models.User.email src/    # or: agentica refs src/models.agc:4:3 src/
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

The first line is the declaration. Each other line is a use, with its kind (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`) and the function it is in. The position can be on a use or on the declaration. Two fields with one name in two structs are never mixed. A name that several declarations answer to is `QUERY-AMBIGUOUS-NAME`, and its help lists each one as `FILE:LINE:COL` for the position form. With `--json` the answer is one object, `{version, command, query, definition, builtin, references, skipped}`.

## Options

| Option | Does |
|---|---|
| `--max-steps N` | stops after `N` steps (`RUNTIME-STEP-LIMIT`). Each scheduler takes steps in batches, so the limit can trip a little late; `--schedulers 1` keeps the exact count |
| `--seed N` | makes `Random` repeat the same numbers |
| `--flush-timeout MS` | waits at most `MS` ms for file data and output at the end, then warns. Default 30000, most 86400000. Env `AGENTICA_FLUSH_TIMEOUT_MS` |
| `--schedulers N` | scheduler threads, 1 to 1024; default one per logical core. Env `AGENTICA_SCHEDULERS` (empty counts as unset). `--schedulers 1` runs one task at a time, in a fixed order. A bad value exits with code 2; `agentica test` takes only the env |
| `--deny-run` | makes `Process.spawn` and the other starts return an error that begins with `denied: --deny-run` |
| `--deny-net` | makes `TCP` and `TLS` connects and listens (so `std/http` too) return an error that begins with `denied: --deny-net` |
| `--deny-fs` | makes every `File`, `Dir` and `Path` call except `Path.join`, and `Lazy.write_lines`, return an error that begins with `denied: --deny-fs` |
| `--deny-env` | makes `System.env` return an error that begins with `denied: --deny-env` |
| `--deny-native` | refuses a program that declares an `extern` block before it runs (`RUNTIME-NATIVE-DENIED`, exit 2). Every `--deny-*` flag turns it on |
| `--sandbox` | all the `--deny-*` flags: use it to run code you do not trust. `agentica test` takes none of them yet |
| `--dump`, `--dump-ir` | print the checked tree or the lowered IR instead of running |
| `outline --stdin FILE` | lists the declarations of the text on standard input as if `FILE` held it, as `check --stdin FILE` does |
| `type-at --stdin FILE:LINE:COL`, `refs --stdin FILE:LINE:COL` | answer for the text on standard input, as if `FILE` held it |
| `symbol NAME --stdin FILE`, `refs NAME --stdin FILE` | search that text as one more file, the first |
| `check --stdin FILE` | checks the text on standard input as if `FILE` held it, for an editor buffer that is not saved. `FILE` need not exist, but its folder is where imports, `agentica.toml` and `agc_libs/` are found; other files come from the disk. With `--json`, the diagnostic names `FILE` |
| `type-at --partial`, `refs FILE:LINE:COL --partial` | answer although some functions do not check, from the ones that do and from the link: the JSON has `"partial": true` and `diagnostics`, and the exit code is 0. `refs` takes it for a position without PATH. `outline` takes the option and ignores it |
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

## Editor support

- [agc-tmlanguage](https://github.com/agentica-lang/agc-tmlanguage) is a TextMate grammar for `.agc` files, tested with vscode-textmate, the highlighter of VS Code and Shiki.
- [tree-sitter-agentica](https://github.com/agentica-lang/tree-sitter-agentica) is a tree-sitter grammar with highlight queries. The [Neovim setup](https://github.com/agentica-lang/agc-tmlanguage/blob/main/docs/neovim.md) uses it.
- [agc-lsp](https://github.com/agentica-lang/agc-lsp) is a language server: it runs `agentica check` on the file on disk when it is opened or saved and reports the first error.

## Next

Take the [language tour](/tour/).
