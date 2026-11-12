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
  count = 1 # count is an Int
  count = "two" # error: a String does not fit
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
- Codes start with `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-` or `LINT-` (the suggestions of [`lint`](#suggest-style-changes)). A runtime error also prints the call stack. See [Diagnostics](/reference/diagnostics/).
- `--ai` and `--json` print the same error for tools: `{"code":"CHECK-TYPE-MISMATCH","file":"bad.agc","range":{...},...}`. A warning, which is not an error (`PKG-NATIVE-UNBUILT`), is a JSON object with `"warning": true`, or an `--ai` block that starts with `warning`.

## Suggest style changes

```sh
agentica lint src    # PATH is a file or a folder, default .; --json prints one document; --strict exits 1 for any suggestion
```

```text
src/orders.agc:12:5 LINT-STRING-APPEND-IN-LOOP this loop grows a String with +, which copies the text on every pass
  help: push the pieces on a List and join them once after the loop: parts = parts.push(piece), parts.join("")
lint: 1 suggestion in 1 of 12 files
```

`lint` suggests changes from the [style guide](/style/). It only parses each file, so the imports need not exist and it reads no types. A suggestion is not an error: what is always a mistake (an unused import, unreachable code) stays an error of `check`. Each line is `file:line:column CODE message`, with the way to write it on the next line. Exit codes: `0` with or without suggestions, `1` with `--strict` and any suggestion (for CI) or when a file does not parse (its first diagnostic is printed, and the last line says `lint failed: 1 of 2 files could not be parsed`), `2` for a bad call or an unreadable file. `--json` prints one object: `ok`, `checked`, `suggestions` and `files`, an entry for each file with its `suggestions` (each has `code`, `message`, `help`, `file` and `range`, as a diagnostic does) or its `diagnostic`; the files that did not parse or read are those with a `diagnostic`. The rules, in the order of the guide:

| Code | Suggests |
|---|---|
| `LINT-PRIVATE-DOC` | no `##` doc on a private function, struct or enum |
| `LINT-REPEATED-QUALIFIED-NAME` | `import {Value} from "db"` for a name such as `Db.Value` that a file writes twenty times or more |
| `LINT-IF-CHAIN` | `case` for an `if` chain of three or more branches that test one variable against literals |
| `LINT-NEGATED-ELSE` | the positive case first, not `if not x` with an `else` |
| `LINT-BOOL-COMPARE` | `if done`, not `if done == true` |
| `LINT-SINGLE-PIPE` | a plain call, not `x \|> f()` with one step |
| `LINT-NESTED-CALL` | a pipe for three calls nested in first position, `h(g(f(x)))`, when the two outer ones are functions of the file or of a module it imports, not builtins; a `try` stays on its step (`\|> try h()`) |
| `LINT-LAMBDA-CHAIN` | a pipe into methods, `xs \|> map(->(x) { ... }) \|> sum()`, for a method chain of three or more steps from the first one that passes a lambda; a name without arguments counts only as the last step |
| `LINT-TO-S-CONCAT` | interpolation, not `"n=" + n.to_s` |
| `LINT-STRING-APPEND-IN-LOOP` | `push` and one `join`, not `s = s + piece` in a `for` or `while` loop, which copies the text on every pass |

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

`outline` parses its file, so the imports need not exist. A file that re-exports a name (`export Url.parse`) is also linked, so the original declaration is listed with its doc. Each line starts with `file:line:column`, like `rg`, and private declarations are listed too. `--json` adds the `##` doc, the signature, `exported`, the spans and the fields or variants; a module block (kind `module`) lists its declarations under `items`.

## Type at a position

```sh
agentica type-at src/orders.agc:22:14    # --json for one object; --stdin FILE:LINE:COL reads FILE from standard input
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

Line and column count from 1, in code points (an emoji is one column). The first line is the type of the expression and its span; the next is its definition (for a builtin, its signature). `type-at` checks the file and what it imports, but needs no `main`. A type of another file is written through the import alias (`Models.User`), and one of a module block through the block's name (`Counter.State`, or `Agents.Counter.State` through an alias), except inside its own block. A local, a parameter or a loop variable has a type and a definition at its binding. A type name in an annotation or a type argument (`Models.User`) has `kind` `type` and the struct, enum or alias it names as its definition; a builtin type (`Int`, `List`) has none. A builtin (`split` in `xs.split(",")`) has no definition; with `--json` it has `kind` `builtin` and the object of `agentica help NAME --json` under `help`.

## Find a name

```sh
agentica symbol Models.User.email src/    # PATH is a file or a folder, default .
```

```text
src/models.agc:4:3 field User.email: String
```

NAME is written as the code writes it: `total`, `User.email`, `Level.Info`, `Models.User` through the import alias of a file under PATH, `Counter.start` or `Agents.Counter.start` for an export of a module block, `std/queue.pop` or a builtin (`Map.get`). A bare name lists every module that declares it, private declarations too (a private name of a module block is found bare only). The files under PATH are linked together; one that does not link is listed under `skipped` and the others still answer. `--json` adds `kind`, `module`, `exported`, `signature`, `doc` and the spans to each match.

## Find references

```sh
agentica refs Models.User.email src/    # or: agentica refs src/models.agc:4:3 src/
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

The first line is the declaration. Each other line is a use, with its kind (`call`, `value`, `type`, `construct`, `read`, `pattern`, `binding`, or `qualifier` for the name of a module block written before one of its names, `Counter` of `Counter.start(1)`) and the function it is in. The position can be on a use or on the declaration. Two fields with one name in two structs are never mixed. A name that several declarations answer to is `QUERY-AMBIGUOUS-NAME`; its help lists each one as `FILE:LINE:COL` for the position form. With `--json` the answer is one object, `{version, command, query, definition, builtin, references, skipped}`.

## Options

| Option | Does |
|---|---|
| `--max-steps N` | stops after `N` steps (`RUNTIME-STEP-LIMIT`). Each scheduler takes steps in batches, so the limit can trip a little late; `--schedulers 1` keeps the exact count |
| `--seed N` | makes `Random` repeat the same numbers |
| `--flush-timeout MS` | waits at most `MS` ms for file data, output and native frees at the end, then warns. Default 30000, most 86400000. Env `AGENTICA_FLUSH_TIMEOUT_MS` |
| `--schedulers N` | scheduler threads, 1 to 1024; default one per logical core. Env `AGENTICA_SCHEDULERS` (empty counts as unset). `--schedulers 1` runs one task at a time, in a fixed order. A bad value exits with code 2; `agentica test` takes only the env |
| `--jit MODE` | `off`, `on` (the default) or `always`: compiles supported operations to machine code on x86-64 and arm64 (Linux and macOS); a call between compiled functions is a native call. Elsewhere every mode runs the interpreter; output and step counts do not change. Env `AGENTICA_JIT`; `agentica test` takes only the env |
| `--coverage FILE` | writes the line coverage of the run to `FILE` as LCOV (`SF`, `FN`, `FNDA`, `DA` and their totals). It counts the program's files and the packages read in place (workspace members and `path` dependencies), not `std/` or fetched packages; a package's file is named as in diagnostics, such as `pkg/tools@path/tools.agc`. A line is one that starts a statement or an expression the program can step on; its count is the most times one of them ran (with `--max-steps`, the step that stops the run counts as run). The report is written when the run ends, a failed run too. A file that cannot be written fails the run (`RUNTIME-INTERNAL`), or, after a failure, adds a warning line. The JIT is off for the run. `agentica test` takes `--coverage` with no file instead ([Coverage](/library/testing/#coverage)) |
| `--deny-run` | makes `Process.spawn` and the other starts return an error that begins with `denied: --deny-run` |
| `--deny-net` | makes `TCP` and `TLS` connects and listens (so `std/http` too) return an error that begins with `denied: --deny-net` |
| `--deny-fs` | makes every `File`, `Dir` and `Path` call except `Path.join`, and `Lazy.write_lines` and `Lazy.write_bytes`, return an error that begins with `denied: --deny-fs` |
| `--deny-env` | makes `System.env` return an error that begins with `denied: --deny-env`; the locale of error texts still follows `LANG` |
| `--deny-native` | refuses a program that declares an `extern` block or calls a `Native.*` builtin before it runs (`RUNTIME-NATIVE-DENIED`, exit 2). Every `--deny-*` flag turns it on |
| `--sandbox` | all the `--deny-*` flags: use it to run code you do not trust. A program that can start processes escapes a single flag; use `--sandbox`, or add `--deny-run`. `agentica test` gives them to the test files, the step programs and the programs under test, not to its runner |
| `--dump`, `--dump-ir` | print the checked tree or the lowered IR instead of running |
| `--no-cache` | compiles the program again and does not keep its bytecode (see [Bytecode cache](#bytecode-cache)); `check` and `type-at` neither read nor write the check cache (see [Check cache](#check-cache)) |

A flag wins over its environment variable.

Three variables have no flag. `AGENTICA_GC_HEAP` (default `32M`: bytes, or a number with `K`, `M` or `G`; `0` for the collector's own start; a bad value exits with code 2) sets the heap the memory collector starts at: larger stops less often and uses more memory. The collector's own `GC_INITIAL_HEAP_SIZE` wins over it when set. `GC_FREE_SPACE_DIVISOR` (the VM uses 2; 3 uses less memory, 1 runs faster) sets how fast the heap grows. `AGENTICA_PERF_MAP=1` names compiled functions for Linux `perf` (see [Profile](/library/testing/profile/#linux-perf)).

## Commands

| Command | Does |
|---|---|
| `check [PATH...]` | checks every `.agc` file of the files and folders named, or of the current folder with no PATH. One file path prints `check ok`, or its first diagnostic; with `--json`, `{"ok":true}` or the diagnostic. A folder, no path or several paths end with a count (`check ok: 3 files`, or `check failed: 1 of 3 files` and exit 1), and each failing file prints its first diagnostic (with `--ai`, under the file name). With `--json` the output is one object on stdout, `{ok, checked, failed, files}`, with `{file, ok, diagnostic}` for each file. A folder skips hidden folders, `agc_libs/`, `_build/`, the `deps/` of a project and symbolic links to files, as `symbol` does; `build/` is not skipped. A path that does not exist, or a folder with no `.agc` file, is `QUERY-USAGE` and exit 2, and no file is checked. A file that cannot be read is `QUERY-USAGE` in its entry and makes the exit code 2; the other files are still checked |
| `check --stdin FILE` | checks the text on standard input as if `FILE` held it, for an editor buffer that is not saved. `FILE` need not exist, but its folder is where imports, `agentica.toml` and `agc_libs/` are found; other files come from the disk. With `--json`, the diagnostic names `FILE` |
| `lint [PATH...]` | suggests style changes; see [Suggest style changes](#suggest-style-changes) |
| `fmt [PATH...]`, `fmt --check`, `fmt -`, `fmt --tree FILE` | formats files in place, lists the files it would change, formats standard input, or prints the parse tree; see [Format](#format) |
| `outline --stdin FILE` | lists the declarations of the text on standard input as if `FILE` held it, as `check --stdin FILE` does |
| `type-at --stdin FILE:LINE:COL`, `refs --stdin FILE:LINE:COL` | answer for the text on standard input, as if `FILE` held it |
| `symbol NAME --stdin FILE`, `refs NAME --stdin FILE` | search that text as one more file, the first |
| `type-at --partial`, `refs FILE:LINE:COL --partial` | answer although some functions do not check, from the ones that do and from the link: the JSON has `"partial": true` and `diagnostics`, and the exit code is 0. `refs` takes it for a position without PATH. `outline` takes the option and ignores it |
| `install`, `add NAME URL --tag TAG` (or `--ref COMMIT`, `--subdir DIR`), `update [NAME]` | keep `deps/` and `agentica.lock`; see [Packages](/tour/modules/#packages) |
| `compile FILE -o OUT` | writes VM bytecode |
| `run [OPTIONS] -- FILE.agcb [ARGS...]` | runs bytecode; `run` must be the first word. Options: the ones above except `--dump*`, plus `--source-root DIR`, `--ai`, `--json`. `run --version` lists the linked libraries |
| `--version` | prints the version |

## Format

```sh
agentica fmt src         # format in place; PATH is a file or a folder, default .
agentica fmt --check .   # list the files fmt would change; exit 1 if there is one
agentica fmt - < a.agc   # format standard input to standard output
```

`fmt` formats every `.agc` file of the files and folders named, searched as `check` searches them (`agc_libs/` is skipped unless you name it); a file that is already formatted is not written. The layout is the one of the [style guide](/style/):

- One statement per line, two-space indents, and a call, list, map or `def` header on one line when it fits, else one item per line with a trailing comma. A statement that takes several lines is followed by an empty line, unless a comment that closes its block comes next.
- A pipe chain of two or more `|>` that is a whole statement, binding value or return value is one stage per line even when it fits, in parentheses closed by a lone `)`. A method chain in that place that the source writes with a `.` at the start of each line is joined when it fits, and else keeps that form.
- An `if` with no `elsif` or `else`, no comment and one `return`, `break` or `next` of one line is written as the guard it stands for (`return x if c`) when that fits on the line; a guard that does not fit or spans lines is written as the `if`.
- A `def` whose body is one value, with a result other than `Void` and no comment from its `def` line to its `end` line, is written as a one-line def (`def f() -> Int = value`) when that fits; a one-line def that does not fit, or whose value takes lines of its own, is written as a `def` with `end`, with an empty line on both sides. The empty lines around a def are kept as found.
- In a def whose result is not `Void` (nor a `Void` alias of the same file), a last `return value` (also the last of a branch of a last `if` with an `else`, or of an arm of a last `case`) is written as the bare value; a `try` or `case` value keeps its `return`.
- Comments keep their words and order; a `#` line wider than the width is wrapped. CRLF line ends become LF.

The `[style]` of the nearest `agentica.toml` above each file sets the width (`max_line_width`, 119 without it), and `blank_line_after_end = true` adds the empty line after every bare `end` that `check` asks for; a bad value is `PKG-MANIFEST-INVALID`. `fmt` never splits a name or a string, and keeps a trailing comment on the last line of a statement, so a line can stay too long (`CHECK-LINE-TOO-LONG`).

- A file that does not parse prints its diagnostic, is left as it is and makes the exit code 1; with `fmt -` nothing is printed on standard output. A file named on the command line is formatted whatever its extension; a name that starts with `-` is written `./-x.agc`. An unknown option, a path that does not exist or a folder with no `.agc` file is `FMT-USAGE` and exit 2, and no file is written.
- `fmt --check` writes nothing; a CRLF file counts as changed. `fmt -` uses the `[style]` of the working folder.
- `fmt --tree FILE` prints the parse tree without positions, without the guard mark of an `if`, the mark of a one-line `def` and the mark of a last expression that gives the value of its def, and the words of the comments, which formatting never changes.

## Bytecode cache

`agentica FILE.agc`, `agentica compile` and `agentica test` keep the compiled program of each root file in `_build/bytecode/` and read it back while the sources are the same.

- An entry holds the SHA-256 of every source file (`agentica.toml` and `agentica.lock` too), how each import was found, and the version and build of the binary. Any change compiles the program again and replaces the entry.
- `_build/` is in the project folder (the nearest `agentica.toml`) or, for a file outside a project, beside the file. Nothing deletes old entries: remove the folder when you like, and put `_build/` in your `.gitignore`.
- The entry is bytecode that runs with your rights, so it is used only when `_build/`, `_build/bytecode/` and the file are real folders and files (no links) owned by you, with no write bit for the group or others. The cache makes the folder with mode 0700. A folder that fails the checks is skipped with no message, so `/tmp` is a poor place for it. A folder you make yourself must pass `chmod go-w DIR`. On Windows only the link and file-kind checks apply.
- `AGENTICA_BUILD_DIR` names another folder in place of `_build/`. `--no-cache` neither reads nor writes the cache for one run. `--dump`, `--dump-ir`, `compile` with a `--deny-*` flag or `--sandbox`, and `run -- FILE.agcb` do not use it, and a program that does not compile is never cached. The compiler uses the cache even under `--deny-*`.
- If a run stops with `invalid bytecode` from a cached entry, remove `_build/bytecode/`.

## Check cache

`agentica check` and `agentica type-at` keep what they learn about each imported file in `_build/check/`, so an editor that runs them on every keystroke does not check the same imports again. A file whose entry matches (its text and everything it imports are unchanged) is not checked again; any other change is a miss and the file is checked in full. The answer, diagnostics and spans included, is the one a run without the cache gives.

- The root file and the text of `--stdin` are always checked in full. Entries are written only after a program checks.
- It follows the rules of the bytecode cache: the same folder choice, the same ownership checks, and `--no-cache` turns it off. A damaged entry is ignored. `outline`, `refs` and `symbol` do not use it.
- The first run after a change writes the entries; the next ones read them.

## Test

```sh
agentica test                                    # test/ and specs/
agentica test test/ports_test.agc --only port    # only tests whose name has "port"
agentica test --jobs 4                           # up to 4 scenarios or test files at once
agentica test --timing                           # and the time of each file and the slowest scenarios
agentica test --coverage                         # and the line coverage in coverage/lcov.info
```

Runs `*_test.agc` files ([Test](/library/testing/test/)) and `.feature` specs ([BDD](/library/testing/bdd/)). `--jobs N` (1 to 1024, default 1) runs up to `N` jobs at the same time: each scenario of a feature file (each row of a Scenario Outline) and each test file is one job. The report keeps the order of the files and of the scenarios in each file. Scenarios or files that share a port, a path or a database need `--jobs 1`, and a high `N` makes per-test timeouts likelier under CPU load. `--timing` adds, before the totals, the time of the run (wall time, less than the files add up to with `--jobs`), one line for each file with the sum of its scenarios' times and its scenario count, and the 5 slowest scenarios, in milliseconds; it changes nothing in `--json`. The `--json` report always has `duration_ms` (an additive field, whatever the flags): on the report the wall time of the run, on each file the sum of its scenarios' times, and on each scenario its own. `--coverage` writes the line coverage of the sources that the tests ran to `coverage/lcov.info` ([Coverage](/library/testing/#coverage)).

## Editor support

- [agc-tmlanguage](https://github.com/agentica-lang/agc-tmlanguage) is a TextMate grammar for `.agc` files, tested with vscode-textmate, the highlighter of VS Code and Shiki.
- [tree-sitter-agentica](https://github.com/agentica-lang/tree-sitter-agentica) is a tree-sitter grammar with highlight queries. The [Neovim setup](https://github.com/agentica-lang/agc-tmlanguage/blob/main/docs/neovim.md) uses it.
- [agc-lsp](https://github.com/agentica-lang/agc-lsp) is a language server: it runs `agentica check` on the file on disk when it is opened or saved and reports the first error.
