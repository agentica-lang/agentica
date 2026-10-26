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
  = help: convert it with s.to_i!
```

- Exit code `1`: the program has an error. Exit code `2`: a bad command or an unreadable file.
- Codes start with `LEX-`, `PARSE-`, `CHECK-` or `RUNTIME-`. A runtime error also prints the call stack. See [Diagnostics](/reference/).
- `--ai` and `--json` print the same error for tools: `{"code":"CHECK-TYPE-MISMATCH","file":"bad.agc","range":{...},...}`.

## Look up a builtin

```sh
agentica help String.split    # `agentica help` alone lists commands and namespaces
```

```text
s.split(separator: String) -> List[String]
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

`outline` parses its file, so the imports need not exist; a file that re-exports a name (`export Url.parse`) is also linked, to list the original declaration with its doc. It prints each declaration with `file:line:column` first, like `rg`, and private ones too. `--json` adds the `##` doc, the signature, `exported`, the spans and the fields or variants.

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
| `--jit MODE` | `off` (the default), `on` or `always`: compiles supported operations to machine code on x86-64; `CALL` and `RETURN` use compiled frame-transition exits, not native nested calls. Experimental (elsewhere every mode runs the interpreter); output and step counts do not change. Env `AGENTICA_JIT`; `agentica test` takes only the env |
| `--deny-run` | makes `Process.spawn` and the other starts return an error that begins with `denied: --deny-run` |
| `--deny-net` | makes `TCP` and `TLS` connects and listens (so `std/http` too) return an error that begins with `denied: --deny-net` |
| `--deny-fs` | makes every `File`, `Dir` and `Path` call except `Path.join`, and `Lazy.write_lines`, return an error that begins with `denied: --deny-fs` |
| `--deny-env` | makes `System.env` return an error that begins with `denied: --deny-env`; the locale of error texts still follows `LANG` |
| `--deny-native` | refuses a program that declares an `extern` block or calls a `Native.*` builtin before it runs (`RUNTIME-NATIVE-DENIED`, exit 2). Every `--deny-*` flag turns it on |
| `--sandbox` | all the `--deny-*` flags: use it to run code you do not trust. A program that can start processes escapes a single flag; use `--sandbox`, or add `--deny-run`. `agentica test` gives them to the test files, the step programs and the programs under test, not to its runner |
| `--dump`, `--dump-ir` | print the checked tree or the lowered IR instead of running |
| `--no-cache` | compiles the program again and does not keep its bytecode (see [Bytecode cache](#bytecode-cache)); `check` and `type-at` neither read nor write the check cache (see [Check cache](#check-cache)) |
| `outline --stdin FILE` | lists the declarations of the text on standard input as if `FILE` held it, as `check --stdin FILE` does |
| `type-at --stdin FILE:LINE:COL`, `refs --stdin FILE:LINE:COL` | answer for the text on standard input, as if `FILE` held it |
| `symbol NAME --stdin FILE`, `refs NAME --stdin FILE` | search that text as one more file, the first |
| `check --stdin FILE` | checks the text on standard input as if `FILE` held it, for an editor buffer that is not saved. `FILE` need not exist, but its folder is where imports, `agentica.toml` and `agc_libs/` are found; other files come from the disk. With `--json`, the diagnostic names `FILE` |
| `type-at --partial`, `refs FILE:LINE:COL --partial` | answer although some functions do not check, from the ones that do and from the link: the JSON has `"partial": true` and `diagnostics`, and the exit code is 0. `refs` takes it for a position without PATH. `outline` takes the option and ignores it |
| `install` | fetches the packages of `agentica.lock` with the system `git` into the download cache and writes them to `deps/NAME/` next to `agentica.toml`, where a build reads them (see the modules tour); never changes the lock |
| `add NAME URL --tag TAG`, `add NAME URL --ref COMMIT` (and `--subdir DIR`) | adds a dependency to `agentica.toml` and writes `agentica.lock` and `deps/`, fetching with the system `git` (see the modules tour) |
| `update [NAME]` | fetches the tag pins again (all, or the dependency `NAME`), rewrites `agentica.lock` and refreshes `deps/` |
| `compile FILE -o OUT` | writes VM bytecode |
| `run [OPTIONS] -- FILE.agcb [ARGS...]` | runs bytecode; `run` must be the first word. Options: the ones above except `--dump*`, plus `--source-root DIR`, `--ai`, `--json`. `run --version` lists the linked libraries |
| `--version` | prints the version |

A flag wins over its environment variable.

## Bytecode cache

`agentica FILE.agc` and `agentica test` keep the compiled program of each root file in `_build/bytecode/`, and read it back while the sources are the same. A program that imports `std/analysis` starts in about a tenth of a second instead of six. The entry holds the SHA-256 of every file the program was built from (`agentica.toml` and `agentica.lock` too), what the compiler looked at to find each import (so a library that appears in an earlier folder of the `pkg/` search, or a link that now leads elsewhere, compiles the program again), and the version and build of the binary. Any change compiles the program again and replaces the entry. There is one entry for each root file and nothing deletes it, so remove the folder when you like. `_build/` is in the folder of the project (the nearest `agentica.toml`) or, for a file outside a project, beside the file. Put `_build/` in your `.gitignore` (when the cache makes `_build/` it adds a `.gitignore` of its own, which `git` honours).

The entry is bytecode that runs with your rights, so it is used only when `_build/`, `_build/bytecode/` and the file are yours alone: real folders and files (never links), owned by you, with no write bit for the group or others. The cache makes the folder with mode 0700. A folder that fails these checks is not read and not written, and the program runs without the cache, with no message; a shared folder (such as `/tmp`) is not a good place for it. A folder you make yourself (an existing `_build/` of another tool, or for `AGENTICA_BUILD_DIR`) must not be writable by the group or others (`chmod go-w DIR`, since a umask of 002 makes it 0775), or the cache stays off; leave it to the cache to make the folder and it is 0700. A file system that cannot rename without replacing never gets an entry. On Windows, which has no modes or owners to read, only the link and file-kind checks apply: the cache trusts its folder (no owner or ACL check), and a folder that other users can write is out of scope.

`AGENTICA_BUILD_DIR` names another folder in place of `_build/`; the entries go in its `bytecode/` folder (its parent is made when missing). `--no-cache` neither reads nor writes the cache for one run. If the folder cannot be made or written the program runs without the cache. `compile`, `--dump`, `--dump-ir` and `run -- FILE.agcb` do not use it, and a program that does not compile is never cached. The `--deny-*` flags are for the program, not for the compiler, so the compiler still reads and writes the cache under them. If a run stops with `invalid bytecode` from a cached entry (an entry that is not valid bytecode but passes the cache's own checks, which only someone who writes the folder can make), remove `_build/bytecode/`; `--no-cache` runs the program without that entry.

## Check cache

`agentica check` and `agentica type-at` keep what they learn about each imported file in `_build/check/` (one entry per file, named by a digest of its path or `std/` name), so an editor that runs them on every keystroke does not read, parse and check the same imports again. An entry holds the SHA-256 of the file's text, a digest of the file and everything under it (its imports, their imports and the packages they come from) at which the file passed a check, a copy of the file with the bodies of its functions blanked, and the types of its constants. A file whose entry matches is parsed from the short copy and its bodies are not checked again; any change to the file, to a file it imports or to the binary is a miss and the file is read and checked in full, and its entry replaced. The answer, the diagnostics and their spans included, is the one a run without the cache gives. The root file (and the text of `--stdin`) is always read and checked in full. Entries are written only after a program checks, so a root with an error stores nothing and the first warm-up needs a clean check; a file that does not check is never stored. An entry is kept per file and per project inputs, nothing deletes old ones, and `_build/` is made by the first `check` that stores an entry; remove the folder when you like.

The entries follow the rules of the bytecode cache above: `_build/` and `AGENTICA_BUILD_DIR` choose the folder, it is used only when it and its entries are yours alone, `--no-cache` turns it off, and any entry that is damaged or not for this build is ignored. `outline`, `refs` and `symbol` do not use it. The first run after a change writes the entries and takes a little longer than a run without the cache; the next ones are several times faster.

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
