---
title: Code analysis (std)
weight: 8
description: The std/analysis module, which answers the questions of check, outline, type-at, symbol and refs from a program.
---

`std/analysis` answers, inside a program, the questions that the command line answers: `import Analysis from "std/analysis"`. The answers are plain structs. The `*_json` functions give the same bytes as the `--json` output of `agentica outline`, `type-at`, `symbol` and `refs` ([Command line](/cli/#query-the-code)), and `Analysis.diagnostic_json` gives what `--json check` prints on stderr.

```ruby
Analysis.workspace() -> Analysis.Workspace
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session: Analysis.Session, path: String, text: String) -> Analysis.Session
Analysis.close(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.refresh(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.entry(session: Analysis.Session, path: String) -> Result[Analysis.Entry]
Analysis.adopt(session: Analysis.Session, entry: Analysis.Entry) -> Analysis.Session
Analysis.check(session: Analysis.Session, path: String) -> Analysis.Checked
Analysis.outline(session: Analysis.Session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.type_at_partial(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.symbol(session: Analysis.Session, name: String, paths: List[String]) -> Result[Analysis.Symbols]
Analysis.refs(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.refs_partial(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.native_modules(session: Analysis.Session, path: String) -> Result[Analysis.NativeModules]
Analysis.bodies(session: Analysis.Session, path: String) -> Result[Analysis.Bodies]
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found: Analysis.Outline) -> JSON.Value
Analysis.type_at_json(found: Analysis.TypeAt) -> JSON.Value
Analysis.symbols_json(found: Analysis.Symbols) -> JSON.Value
Analysis.refs_json(found: Analysis.Refs) -> JSON.Value
Analysis.native_modules_json(found: Analysis.NativeModules) -> JSON.Value
Analysis.bodies_json(found: Analysis.Bodies) -> JSON.Value
Analysis.diagnostic_json(found: Analysis.Diagnostic) -> JSON.Value
```

## Sessions and buffers

A `Session` reads files from the disk under the working folder, except files that have a buffer: text an editor has open and has not saved. `Analysis.update(session, path, text)` returns a session where `path` has `text`, whether or not the disk has the file. `Analysis.close` removes the buffer. Two spellings of one file are one buffer. Create the folder of a new file before `update`, and `close` it with the spelling you gave. A buffer answers for its own file and for every file that imports it.

`Analysis.open` takes a `Workspace`: `Analysis.workspace()` gives an empty one, or build one whose `buffers` map holds paths and texts. Its `version` must be 1. When two paths name one file, the later one wins.

A session is a value. Tasks may share one and ask it at once; an `update` in one task leaves the copies of the others unchanged. Its fields are not API. A new session has no cache: each question runs the stages from the start, until `refresh` fills it (next section).

## Refresh and the cache

`Analysis.refresh(session, path)` returns a session whose cache holds the linked and checked program of `path`, and the parsed modules it reads. A loop that keeps one session runs `update`, then `refresh`, then the questions, which then skip parsing and checking about `path`.

`check`, `type_at` and `refs` use the checked program in the cache; `symbol` links each file it searches and uses only its parsed modules. Each question reads the files again, starting at its own file, and uses the cache only where the modules and their texts are the ones the cache was made from. Buffer edits, `close`, changes on disk, new and removed files, and a change of `agentica.toml` that changes what an import means all count. So the answers are the same with or without `refresh`: a stale cache costs time, never a wrong answer. A refresh checks again only when a module changed, and parses only the modules whose text changed. A module whose text is the same, with every module it imports, is not checked again: the check takes what the last program of `path` that checked left for it, so an edit of `path` costs about the file itself, and an edit of an imported module checks that module and those that import it. The answers are those of a check from the start. A file that cannot be read or linked leaves the cache as it was, and the questions say why.

The cache keeps at most 16 checked files, the least recently refreshed leaving first, with the parsed modules they reach. It lives in the value: there is no task, channel or lock, so the caller owns the loop. Run one `refresh` at a time per session and keep the session it returns. Two refreshes from one session make two caches, and keeping one drops the other's work, which costs time only. A program that refreshes in a task and calls `update` on its own copy meanwhile adopts the refreshed session only if no `update` or `close` came after the refresh started; otherwise it keeps its own session and refreshes again later.

## Sharing the cache between tasks

A `Session` holds functions, so an `ATS` table cannot hold one. An `Analysis.Entry` is what `refresh` kept for one file, as plain data. `Analysis.entry(session, path)` takes it from a refreshed session; it is an error when the cache holds none for `path` (not refreshed, a file that does not link, or an entry that left the cache). Give `entry` the same spelling of the path as `refresh`: a file that only has a buffer is not canonicalized, so another spelling finds nothing. `Analysis.adopt(session, entry)` returns the session with the cache of that entry alone, and the same buffers. A refresh or a question about that file then takes the program from the entry when the files and buffers are as they were, and else checks again only the modules that changed or import one that did. A stale entry costs time, never a wrong answer. The fields of an `Entry` are not API.

So tasks that refresh different files lose nothing. Each task refreshes its own session, puts `Analysis.entry(refreshed, path)` in an `ATS[String, Analysis.Entry]` under the path, and a task that asks about a file adopts the entry of that file first. Entries of two files are separate caches: the table shares the checked program of each file, not the modules that two files both import. The program decides when an entry leaves the table, for instance when the file is closed.

```ruby
def refresh_into(entries: ATS[String, Analysis.Entry], session: Analysis.Session, path: String) -> Void
  found = Analysis.entry(Analysis.refresh(session, path), path)
  if found.ok?
    entries.put(path, found.unwrap!)
  end
end

def check_from(entries: ATS[String, Analysis.Entry], session: Analysis.Session, path: String) -> Analysis.Checked
  found = entries.get(path)
  return Analysis.check(Analysis.adopt(session, found.unwrap!), path) if found.ok?
  return Analysis.check(session, path)
end
```

## Answers

The answers are structs of strings, ints, bools and lists, with no enum. Their fields are the keys of the `--json` forms, with the same names, except that `range` is a `Region` with `start` and `stop` (JSON `end`). An absent value is `""`, or an empty list for a struct: `Outline.doc`, `Item.doc` and `Import.alias` are `""` where the JSON has `null`. `TypeAt.definition` is empty or holds one `Definition`. A `kind` is a string, an open set: a program accepts a kind it does not know.

The types are aliases of the library's own. A program reads their fields but cannot build them by name: `Analysis.Position(line: 3, column: 9)` is `CHECK-UNKNOWN-TYPE`. To get a `Diagnostic`, for a timeout say, read one from JSON with `Analysis.diagnostic`.

A file is named as on the command line: by its canonical path, relative to the working folder when it is below it. A diagnostic keeps the root file as the path you gave, as `check` does, so `Checked.file` and the `file` of its diagnostic may be spelled differently.

- `Analysis.check` links and checks the file. `Checked.passed` is true when there is no problem; `diagnostics` holds the first one, if any.
- `Analysis.outline` lists what the file declares. The file is only parsed. A module block is an `Item` of kind `"module"` whose `items` are its declarations; `items` is empty for every other kind.
- `Analysis.type_at` gives the type and the definition at a position. Line and column count from 1.
- `Analysis.symbol` finds where `name` is declared in the files and folders of `paths` (`.` when the list is empty). A folder means every `*.agc` file below it. The files are linked together, and those that do not link are listed in `Symbols.skipped`. `Symbol.module` is the file (`""` for a builtin), and `help` is the object of `agentica help NAME --json` for a builtin, JSON null for the others. Every file with a buffer in the session is searched too, first, as `--stdin FILE` does, whether or not `paths` names it, so a query cannot be scoped to a folder while other buffers are open. Buffers come in the bytewise order of their canonical paths, whatever order they were put in, so `matches` does not depend on the history of `update` calls. Folders are listed on the disk: a folder that exists only as buffers (buffer `newdir/new.agc` with `paths` `["newdir"]`) is a `QUERY-USAGE` "cannot read". Name the buffer's file, or leave `paths` empty.
- `Analysis.refs` gives the declaration of the name at the position and every reference to it, as `agentica refs` does. It links and checks the file as `type_at` does, and sees the file and what it imports; a file that only imports it is not seen. `Refs.definition` is empty for a builtin, which `Refs.builtin` names (`""` for anything else). A `Reference` is the `range` of the name in its `file`.
- `Analysis.type_at_partial` and `Analysis.refs_partial` are `type_at` and `refs` with `--partial`: when some functions do not check, they answer from the others, with `partial` true and the failures in `diagnostics`; a declaration, `main` or constant that does not check, or a field or builtin for `refs_partial`, is still the first problem as an error. `TypeAt.type` is `""` for a name inside a function that did not check, and in such a function a position the link cannot name gives the first problem as the error.

## Native modules

`Analysis.native_modules(session, path)` describes the `extern module "NAME"` blocks of a file for a tool that generates code for a [native module](/library/io-and-system/native/modules/), such as a C header, without its own parser or type rules. The file is linked and checked as for `type_at`, and needs no `main`. It has no command line form; `native_modules_json` gives the JSON of the answer, with `command` `native-modules`.

A `NativeModules` has the `blocks` of the file, in source order, two blocks of one library being one. A `NativeBlock` has:

- `library`, the `NAME` as written, and the `range` of its declarations, from the first to the last, without the `extern module` line and the `end` (the syntax tree keeps no place for them). Blocks of one library are one block, so its range may cover the declarations of another block, and two ranges may overlap;
- `functions`, each with its `name` as written (`empty?`), its `mode` (`short` for a `def`, `dirty` for a `compute def`), `parameters` (`name` and canonical `type`), `result`, `signature`, `exported`, `doc` and `range`, and `types_in` and `types_out`, the names of the structs, enums and resources that the parameters and that the result reach, through the fields and payloads too, each once, each list in the order of its own walk, which is not a subsequence of the order of the block's `types`: for a parameter `A{b: B}`, `B{c: C}` and a result `C` the block lists A, C, B but `types_in` is A, B, C, so do not merge them by position (a type in `types_out` only is made by the module and never read, and one in `types_in` only is read and never made);
- `resources`, the `resource Name` lines, with `exported`, `doc` and `range`;
- `types`, the structs and enums that cross, each with its `kind` (`struct` or `enum`), its bare `name`, its `members` (fields or variants, with their canonical `types`) and its `shape`;
- `api_major` and `api_minor`, the least version of the C API (`AN_API_MAJOR` and `AN_API_MINOR` of `agentica_native.h`) that has what the block uses: 1.0 for scalars and collections, 1.1 when a struct or enum crosses, 1.2 for a resource.

A `doc` is `""` in the record when there is none, and null in the JSON. A `signature` is the text the module's function table must have, `(List[Float]) -> Optional[Summary]`, and a `shape` the text its type table must have, `count: Int, mean: Float` or `Empty | Number(Float) | Text(String)`. They are written by the code that the compiler binds a call with, so they are the bytes the loader compares. A `shape` is the text after `=` in the `{S<index>=...}` or `{E<index>=...}` that the compiler writes, whose `<index>` is the type's place in the program and is not part of the answer.

## Function bodies

`Analysis.bodies(session, path)` gives the functions of a file with their bodies as a typed tree, for a tool that translates them, such as a prover. **It is experimental:** until a first tool works with it, its shape may change between releases without a breaking mark, though the answer has a `version`. The file is linked and checked as for `type_at`, and needs no `main`. A `std/` name without a buffer, such as `std/binary`, is that module as the binary carries it, and the answer names it `std/binary.agc`. It has no command line form; `bodies_json` gives the JSON of the answer, with `command` `bodies`.

A `Bodies` has the `functions` of the file that have a body, private ones too, in source order, and the `modules` of the linked program, each a `BodyModule` with its `prefix` (the `@N::` that the linked names of its declarations start with, `""` for the file itself) and its `file`. A `Body` has its `name` as written, its `linked` name (the one a call targets), `exported`, its `range` and `name_range`, its `generics`, its `params`, its `result` and its `body`, a list of `Node`. A parameter has a `name`, `type`, `range` and `default`: its default value as one node, or an empty list. Arguments are positional: a call may have fewer arguments than parameters, and the ones it leaves out take their defaults, in order; a trailing block (`do ... end`) always fills the last parameter. A type is a `TypeShape`: `kind` is `builtin` (`name` is `Int`, `Bytes`, `List`, `Result`, `Fn`, ...), `struct`, `enum` or `opaque` (`name` is the linked name), `var` (a type parameter) or `none` (a node with no value), and `args` are its type arguments.

A `Node` has a `kind`, its `type`, its `range`, a `text`, a `target`, `new` and its `children`, in source order:

- `int`, `float`, `string`, `bool`, `nil`: a literal, with its value in `text`. `local`: a read of a name, in `text`.
- `let`: `text = value`, with `new` true when it makes a new local and false when it changes one. `discard` is `_ = value`.
- `call`: the `target` is what the checker resolved: a function by its linked name, or a builtin, such as `Int.shift_left`, `Bytes.length` for `data.size`, `Bytes.at` for `data[i]`, `ok` or `some`. The children are the arguments, the receiver of a method first. `index` is `target[index]` on a `List` or `Map`.
- `op`: a binary operator, written in `text` as in the source (`+`, `<=`, `==`, `!=`, ...); its two children have their types. `and`, `or`, `not` (`text` `!`) and `neg` (unary minus, `text` `-`) are kinds of their own. `-9223372036854775808`, which only fits under its minus, is one `int` node.
- `try`, `return`, and `interpolation`, whose children are `string` parts and typed expressions.
- `if`: a `branch` (the condition, then a `block`) for each `if` and `elsif`, then a `block` for `else`. `case`: the value, then an `arm` each: its pattern, a `guard` when written, and a `block`. A `case` that gives a value has its type, and the last node of each arm's block is that arm's value. A pattern is a `wildcard`, a `literal` or a `variant` (`target` `Shape.Square`, `ok`, `error`, `some` or `none`) whose children are its slots: `bind`, `skip` or a nested pattern. An arm of several patterns (`"ex", "px" ->`) has an `alternatives` node whose children are those patterns.
- `other`: a node that this version does not describe yet (loops, lists, maps, struct and enum values, blocks and lambdas, constants), with its syntax in `text` (`block`, `lambda`, ...) and no children.

A `Body` is `pure` when no call it makes, through every function it calls, has an effect or reads state that another task or the system may change. A builtin has an effect when `agentica help NAME --json` lists one in its `effects` (`stdout`, `filesystem`, `network`, ...), and the reads of shared state have one too: `concurrency` for a read of an `ATS` or a `Channel` and for `ch.lazy`, `filesystem` for `File.foreach` and `File.chunks`, `clock` for `System.Profile.steps`. So `+`, `b[i]` and `unwrap!` are pure: they may halt, but do nothing else. A call of a function of an `extern module` has the effect `native`. A call that may run a function value has the effect `function-value`: `f.call(x)`, a call of an `Fn` field (`h.run(x)`), a builtin given a function value that is not a block or `&name` (`xs.map(f)`), and a terminal of a `Lazy` (`to_a`, `first`, ...), which runs the source and the steps that made it. A method call the checker did not resolve has the effect `unresolved`. A reference `&name` counts as a call of `name`. `impure` gives each reason once, as a `Reason`: the `effect`, the `call` (a builtin, a linked function name, or `call`), its `range`, and `through`, the linked names of the functions from the first one called to the one that makes the call (empty when the function makes it itself). The call is in the file of the last name's prefix. Recursion and cycles are followed once.

A `block` runs from its first statement to its last. Some ranges are coarse: a `string` part of an interpolation has the range of the interpolation, a `skip` slot that of its variant, and an `if` or `case` statement runs to the start of the next line. The type arguments of a call of a generic function are not in the answer yet.

## Errors

`outline`, `type_at`, `type_at_partial`, `symbol`, `refs`, `refs_partial`, `native_modules` and `bodies` return a `Result` whose error message is the diagnostic as one JSON object, the `--json` form, so `try` works. `Analysis.diagnostic` reads it back into an `Analysis.Diagnostic`. The codes are those of the command line: `LEX-`, `PARSE-`, `CHECK-` and `PKG-`; `QUERY-NO-EXPRESSION` for a position on no expression; `QUERY-NOT-FOUND` for a `symbol` name that nothing declares; and `QUERY-USAGE` for a file that cannot be read, a position below line 1 or column 1, or a `symbol` with an empty name or a path that names no `*.agc` file. For `outline`, `type_at` and `refs` the diagnostic names the file; for `symbol` its `file` is `<arguments>`, as on the command line. Unlike the command line, `QUERY-USAGE` has no usage `help` line; `QUERY-NOT-FOUND` keeps its `help` (the files not searched).

```agentica {mode="check"}
import Analysis from "std/analysis"

def main() -> Void
  session = Analysis.open(Analysis.workspace())
  session = Analysis.update(session, "app.agc", "def twice(n: Int) -> Int\n  return n * 2\nend\n")
  outline = Analysis.outline(session, "app.agc")
  if outline.ok?
    for item in outline.unwrap!.items
      puts("#{item.kind} #{item.signature}")
    end
  else
    puts(Analysis.diagnostic(outline.message).unwrap!.code)
  end
end
```

## Cost

The compiler is part of the program that imports `std/analysis`: its pure core is carried by the binary as the private `std/internal/compiler/`, and only `std/` modules may import that. A program that imports `std/analysis` therefore checks and lowers the files of `stdlib/CORE` too when it runs from source, and the checker and the catalog of builtins it asks are the ones of the binary that compiled it, frozen in the compiled program. The binary refuses a `.agcb` file of another Agentica version, so recompile a tool after upgrading agentica. A program that runs often can pay the compile time once: `agentica compile tool.agc -o tool.agcb`, then `agentica run -- tool.agcb`.
