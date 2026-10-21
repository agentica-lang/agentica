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

`agentica check hello.agc` checks types without running and prints `check ok`. Every run checks first, so a type error stops it before any output. `check` needs no `main`, so a library file passes; running or compiling a file needs `def main() -> Void`. The checker stops at the first error:

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

It prints each declaration with `file:line:column` first, like `rg`, and private declarations too. `--json` adds the `##` doc, the signature, `exported` and the spans, with the fields and variants. Like `doc`, it only reads the file, so its imports need not exist. A bad question, such as a missing file, is `QUERY-USAGE` and exits 2.

Ask for the type at a position, with the definition of what the expression names:

```sh
agentica type-at src/orders.agc:22:14    # --json prints one JSON object; --stdin reads the file from standard input
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

Line and column count from 1, in code points (an emoji is one column). A type of another file is written through the import alias (`Models.User`). `type-at` checks the file and what it imports, but needs no `main`; an error in the program is its own diagnostic and exits 1. A position that is not on a token of an expression is `QUERY-NO-EXPRESSION` and exits 2. With `--json` the definition also has its signature and its `##` doc, and the name of a builtin (`split` in `xs.split(",")`) answers `kind` `builtin` with the object of `agentica help NAME --json` under `help`. A local variable, a parameter or a name bound by a loop or a `case` answers with its type and a definition at the place that binds it, whether the position is on a use or on the binding.

Find where a name is defined in a folder, with its signature and `##` doc:

```sh
agentica symbol Models.User.email src/    # PATH is a file or a folder, default .; --json, --stdin FILE
```

```text
src/models.agc:4:3 field User.email: String
```

NAME is written as the code writes it: `total`, `User.email`, `Option.Some`, `Models.User` through the import alias of a file under PATH, `std/queue.pop`, or a builtin (`Map.get`). A bare name lists every module that declares it, private declarations too. With `--json` each match has its `kind`, `module`, `exported`, `signature`, `doc` and spans, and a builtin has the object of `agentica help NAME --json` under `help`. The files of PATH are linked together: one that does not lex, parse or link is listed under `skipped` with its diagnostic, and the others still answer. A name that nothing declares is `QUERY-NOT-FOUND` and exits 2; if no file links, the first diagnostic is the answer and exits 1.

List every reference to a name, or to the name at a position:

```sh
agentica refs Models.User.email src/    # NAME and PATH as for symbol; --json prints one JSON object
agentica refs src/models.agc:4:3 src/   # FILE:LINE:COL; --stdin reads the file from standard input
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:9:30 read in render
src/report.agc:31:5 construct in sample
```

The two forms give the same answer for the same declaration. The position can be on a use, on the name where the declaration is written, or on a name of an import list (`make` of `import {make} from "models"`). The name can be a function, a struct, an enum, a variant, a field, a constant, a type alias, a local variable, a parameter or a builtin; a field of one struct is never mixed with a field of the same name in another, nor a variable of one block with a variable of the same name in a sibling block. The first line is the definition (a builtin has none) and each other line is a use, with its kind (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`) and the function it is in; the span of a use is the name alone. `refs` links the files together (FILE and the files under PATH for a position, the files under PATH for a NAME, default `.`, and what they import), so it sees the uses in all of them, and checks them. A file under PATH that does not link is listed under `skipped` and the others still answer. A NAME that nothing declares is `QUERY-NOT-FOUND`, and one that several declarations answer to is `QUERY-AMBIGUOUS-NAME` with each candidate as `FILE:LINE:COL` in its help, ready for the position form. Positions, `--stdin` and the other exit codes are those of `type-at`. A position on the module alias of `Models.total(u)` selects the function, not the module, and a position on a module alias or a path of an import line is `QUERY-NO-EXPRESSION`. With `--json` the answer is `{version, command, query, definition, builtin, references, skipped}`; no references is an empty list, not an error.

## Options

| Option | Does |
|---|---|
| `--max-steps N` | stops after `N` steps (`RUNTIME-STEP-LIMIT`). Each scheduler takes steps in batches, so the limit can trip a little late; `--schedulers 1` keeps the exact count |
| `--seed N` | makes `Random` repeat the same numbers |
| `--flush-timeout MS` | waits at most `MS` ms for file data and output at the end, then warns. Default 30000, most 86400000. Env `AGENTICA_FLUSH_TIMEOUT_MS` |
| `--schedulers N` | scheduler threads, 1 to 1024; default one per logical core. Env `AGENTICA_SCHEDULERS` (empty counts as unset). `--schedulers 1` runs one task at a time, in a fixed order. A bad value exits with code 2; `agentica test` takes only the env |
| `--allow-run` | lets the program start programs with `Process.spawn` |
| `--dump`, `--dump-ir` | print the checked tree or the lowered IR instead of running |
| `type-at --stdin FILE:LINE:COL`, `refs --stdin FILE:LINE:COL` | answers for the text on standard input as if `FILE` held it |
| `symbol NAME --stdin FILE`, `refs NAME --stdin FILE` | searches the text on standard input as one more file, the first |
| `outline --stdin FILE` | lists the declarations of the text on standard input as if `FILE` held it, as `check --stdin FILE` does |
| `check --stdin FILE` | checks the text on standard input as if `FILE` held it, for an editor buffer that is not saved. `FILE` need not exist, but its folder is where imports, `agentica.toml` and `agc_libs/` are found; other files come from the disk. With `--json`, the diagnostic names `FILE` |
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
