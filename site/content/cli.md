---
title: Command line
weight: 3
description: Every command, option and cache of the agentica program.
---

The `agentica` program runs, checks and queries Agentica programs. Each section below is one command or one group of options. For a first program, see [Getting started](/getting-started/).

## Run

`agentica FILE.agc` checks a program and runs it. Words after the file name reach the program through `System.args()`:

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

`agentica check hello.agc` checks types without running and prints `check ok`. `agentica check src tests/util.agc` checks several files and folders at once (see [Options](#options)). Every run checks first, so a type error stops it before any output. `check` accepts a file without `main`; a run or `compile` needs `def main() -> Void`. The checker stops at the first error:

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
- Codes start with `LEX-`, `PARSE-`, `CHECK-` or `RUNTIME-`. A runtime error also prints the call stack. See [Diagnostics](/reference/diagnostics/).
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

It prints the exported declarations in source order, each with its signature and its `##` doc, and a struct's fields or an enum's variants. It only reads the file, so the module's imports need not exist. Declarations without `export` are left out.

To learn one module, `agentica help std/queue` lists its exports with the first sentence of each doc (at most about 100 characters), and `agentica help std/queue.pop` prints the signature and the whole doc of one export (a struct's fields or an enum's variants too). `--json` prints one JSON object, with the whole first paragraph as `summary`. A module or name that does not exist is `QUERY-NOT-FOUND` (exit 2); for a name it offers the closest export.

## Query the code

`outline`, `type-at`, `symbol` and `refs` answer questions about the code, for editors and agents. None of them runs the program. Each prints text, or one JSON object with `--json`. Exit codes: `0` answered, `1` the code has an error (its first diagnostic is the answer), `2` a bad question or an unreadable file. The `QUERY-` codes are `QUERY-USAGE` (bad arguments or file), `QUERY-NO-EXPRESSION` (no expression at the position), `QUERY-NOT-FOUND` and `QUERY-AMBIGUOUS-NAME`; see [Diagnostics](/reference/diagnostics/).

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

`outline` parses its file, so the imports need not exist. A file that re-exports a name (`export Url.parse`) is also linked, so the original declaration is listed with its doc. Each line starts with `file:line:column`, like `rg`, and private declarations are listed too. `--json` adds the `##` doc, the signature, `exported`, the spans and the fields or variants.

## Type at a position

```sh
agentica type-at src/orders.agc:22:14    # --json for one object; --stdin FILE:LINE:COL reads FILE from standard input
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

Line and column count from 1, in code points (an emoji is one column). The first line is the type of the expression and its span; the next is its definition (for a builtin, its signature). `type-at` checks the file and what it imports, but needs no `main`. A type of another file is written through the import alias (`Models.User`). A local, a parameter or a loop variable has a type and a definition at its binding. A type name in an annotation or a type argument (`Models.User`) has `kind` `type` and the struct, enum or alias it names as its definition; a builtin type (`Int`, `List`) has none. A builtin (`split` in `xs.split(",")`) has no definition; with `--json` it has `kind` `builtin` and the object of `agentica help NAME --json` under `help`.

## Find a name

```sh
agentica symbol Models.User.email src/    # PATH is a file or a folder, default .
```

```text
src/models.agc:4:3 field User.email: String
```

NAME is written as the code writes it: `total`, `User.email`, `Level.Info`, `Models.User` through the import alias of a file under PATH, `std/queue.pop` or a builtin (`Map.get`). A bare name lists every module that declares it, private declarations too. The files under PATH are linked together; one that does not link is listed under `skipped` and the others still answer. `--json` adds `kind`, `module`, `exported`, `signature`, `doc` and the spans to each match.

## Find references

```sh
agentica refs Models.User.email src/    # or: agentica refs src/models.agc:4:3 src/
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

The first line is the declaration. Each other line is a use, with its kind (`call`, `value`, `type`, `construct`, `read`, `pattern` or `binding`) and the function it is in. The position can be on a use or on the declaration. Two fields with one name in two structs are never mixed. A name that several declarations answer to is `QUERY-AMBIGUOUS-NAME`; its help lists each one as `FILE:LINE:COL` for the position form. With `--json` the answer is one object, `{version, command, query, definition, builtin, references, skipped}`.

## Options

| Option | Does |
|---|---|
| `--max-steps N` | stops after `N` steps (`RUNTIME-STEP-LIMIT`). Each scheduler takes steps in batches, so the limit can trip a little late; `--schedulers 1` keeps the exact count |
| `--seed N` | makes `Random` repeat the same numbers |
| `--flush-timeout MS` | waits at most `MS` ms for file data, output and native frees at the end, then warns. Default 30000, most 86400000. Env `AGENTICA_FLUSH_TIMEOUT_MS` |
| `--schedulers N` | scheduler threads, 1 to 1024; default one per logical core. Env `AGENTICA_SCHEDULERS` (empty counts as unset). `--schedulers 1` runs one task at a time, in a fixed order. A bad value exits with code 2; `agentica test` takes only the env |
| `--jit MODE` | `off`, `on` (the default) or `always`: compiles supported operations to machine code on x86-64 and arm64 (Linux and macOS); a call between compiled functions is a native call. Elsewhere every mode runs the interpreter; output and step counts do not change. Env `AGENTICA_JIT`; `agentica test` takes only the env |
| `--deny-run` | makes `Process.spawn` and the other starts return an error that begins with `denied: --deny-run` |
| `--deny-net` | makes `TCP` and `TLS` connects and listens (so `std/http` too) return an error that begins with `denied: --deny-net` |
| `--deny-fs` | makes every `File`, `Dir` and `Path` call except `Path.join`, and `Lazy.write_lines` and `Lazy.write_bytes`, return an error that begins with `denied: --deny-fs` |
| `--deny-env` | makes `System.env` return an error that begins with `denied: --deny-env`; the locale of error texts still follows `LANG` |
| `--deny-native` | refuses a program that declares an `extern` block or calls a `Native.*` builtin before it runs (`RUNTIME-NATIVE-DENIED`, exit 2). Every `--deny-*` flag turns it on |
| `--sandbox` | all the `--deny-*` flags: use it to run code you do not trust. A program that can start processes escapes a single flag; use `--sandbox`, or add `--deny-run`. `agentica test` gives them to the test files, the step programs and the programs under test, not to its runner |
| `--dump`, `--dump-ir` | print the checked tree or the lowered IR instead of running |
| `--no-cache` | compiles the program again and does not keep its bytecode (see [Bytecode cache](#bytecode-cache)); `check` and `type-at` neither read nor write the check cache (see [Check cache](#check-cache)) |
| `outline --stdin FILE` | lists the declarations of the text on standard input as if `FILE` held it, as `check --stdin FILE` does |
| `type-at --stdin FILE:LINE:COL`, `refs --stdin FILE:LINE:COL` | answer for the text on standard input, as if `FILE` held it |
| `symbol NAME --stdin FILE`, `refs NAME --stdin FILE` | search that text as one more file, the first |
| `check [PATH...]` | checks every `.agc` file of the files and folders named, or of the current folder with no PATH. One file path prints `check ok`, or its first diagnostic; with `--json`, `{"ok":true}` or the diagnostic. A folder, no path or several paths end with a count (`check ok: 3 files`, or `check failed: 1 of 3 files` and exit 1), and each failing file prints its first diagnostic (with `--ai`, under the file name). With `--json` the output is one object on stdout, `{ok, checked, failed, files}`, with `{file, ok, diagnostic}` for each file. A folder skips hidden folders, `agc_libs/`, the `deps/` of a project and symbolic links to files, as `symbol` does; `build/` is not skipped. A path that does not exist, or a folder with no `.agc` file, is `QUERY-USAGE` and exit 2, and no file is checked. A file that cannot be read is `QUERY-USAGE` in its entry and makes the exit code 2; the other files are still checked |
| `fmt [PATH...]` | formats every `.agc` file of the files and folders named (the current folder with no PATH) in place; a file that is already formatted is not written. Folders are searched as `check` searches them, so `agc_libs/` is skipped unless you name it. The layout is the one of `compiler/` and `stdlib/`: one statement per line, two-space indents, and a call, list, map or `def` header on one line when it fits, else one item per line with a trailing comma. Comments keep their words and order; a `#` line wider than the width is wrapped. CRLF line ends become LF. The `[style]` of the nearest `agentica.toml` above each file sets the width (`max_line_width`, 119 without it), and `blank_line_after_end = true` adds the empty line after every bare `end` that `check` asks for; a bad value is `PKG-MANIFEST-INVALID`. `fmt` never splits a name or a string, so a line can stay too long; `check` reports it as `CHECK-LINE-TOO-LONG`. A file that does not parse prints its diagnostic, is left as it is and makes the exit code 1. A file named on the command line is formatted whatever its extension, as `check` does; a file whose name starts with `-` is written `./-x.agc`. An unknown option, a path that does not exist or a folder with no `.agc` file is `FMT-USAGE` and exit 2, and no file is written |
| `fmt --check [PATH...]` | writes nothing: lists, one per line, every file that `fmt` would change, and exits 1 if there is one, 0 if there is none. A CRLF file counts as changed |
| `fmt -` | formats the text on standard input to standard output, with the `[style]` of the working folder; a text that does not parse prints its diagnostic and nothing on standard output (exit 1) |
| `fmt --tree FILE` | prints the parse tree without positions and the words of the comments, which formatting never changes |
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

`agentica FILE.agc` and `agentica test` keep the compiled program of each root file in `_build/bytecode/` and read it back while the sources are the same. A program that imports `std/analysis` then starts in about a tenth of a second instead of six.

- An entry holds the SHA-256 of every source file (`agentica.toml` and `agentica.lock` too), how each import was found, and the version and build of the binary. Any change compiles the program again and replaces the entry.
- `_build/` is in the project folder (the nearest `agentica.toml`) or, for a file outside a project, beside the file. Nothing deletes old entries: remove the folder when you like, and put `_build/` in your `.gitignore`.
- The entry is bytecode that runs with your rights, so it is used only when `_build/`, `_build/bytecode/` and the file are real folders and files (no links) owned by you, with no write bit for the group or others. The cache makes the folder with mode 0700. A folder that fails the checks is skipped with no message, so `/tmp` is a poor place for it. A folder you make yourself must pass `chmod go-w DIR`. On Windows only the link and file-kind checks apply.
- `AGENTICA_BUILD_DIR` names another folder in place of `_build/`. `--no-cache` neither reads nor writes the cache for one run. `compile`, `--dump`, `--dump-ir` and `run -- FILE.agcb` do not use it, and a program that does not compile is never cached. The compiler uses the cache even under `--deny-*`.
- If a run stops with `invalid bytecode` from a cached entry, remove `_build/bytecode/`.

## Check cache

`agentica check` and `agentica type-at` keep what they learn about each imported file in `_build/check/`, so an editor that runs them on every keystroke does not check the same imports again. A file whose entry matches (its text and everything it imports are unchanged) is not checked again; any other change is a miss and the file is checked in full. The answer, diagnostics and spans included, is the one a run without the cache gives.

- The root file and the text of `--stdin` are always checked in full. Entries are written only after a program checks.
- It follows the rules of the bytecode cache: the same folder choice, the same ownership checks, and `--no-cache` turns it off. A damaged entry is ignored. `outline`, `refs` and `symbol` do not use it.
- The first run after a change writes the entries and is a little slower; the next ones are several times faster.

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
