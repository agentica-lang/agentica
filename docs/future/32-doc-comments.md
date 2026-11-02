## 32. Doc comments

**Status:** 22a, `agentica doc` (§32.5) and `agentica help` for `std/` (§32.6)
are built (roadmap [row 22b](../roadmap/README.md)).
Decided on 2026-10-12: documentation comments are `##` lines, in the style of
Rust's `///`. The `##` syntax, the `DOC` token and the `std/`
docs of 22a are in the grammar
([`04-lexical.md`](../grammar/04-lexical.md#doc-comments) for the token and
section 5 for where a block may stand); the parser keeps each block in the `doc`
field of its declaration, field or variant (`Program.module_doc` for the module
doc; `compiler/syntax/ast.agc`), so the bytecode and the VM do not change and a
program with doc comments runs as before. The doc of an exported `def`,
`struct`, `enum` or alias is on its `ExportDecl`, not on the declaration inside
it.

Docs are `##` lines before a declaration (`#` stays an ordinary comment). A
`##` run at the top of a file documents the module. `agentica doc` prints a
module's exported API with its docs; `agentica help` is to learn `std/`
functions. No tags such as `@param` are needed, because the types are in the
signature.

### 32.3 Content

- The text is CommonMark. Tools print it as it is written, with the `##` markers
  removed.
- The first paragraph is the **summary**: one sentence that says what the
  declaration does. `agentica doc` and `help` show it in lists.
- Code examples go in fenced blocks marked `agentica`. Phase 22 does not run
  them; doctests are an option to evaluate later (§32.8).
- There are no tags. Parameter names, types and the result come from the
  signature. When a parameter needs explaining, the text names it in backticks.
- Docs are optional. No diagnostic asks for them. One repo test requires a
  module doc in every `stdlib/*.agc` and a doc on each of its exports.
- Example of a documented module:

```agentica
## Immutable FIFO queue of strings.
##
## Every operation returns a new queue; nothing is changed in place.

## A queue value. Build one with `new`.
export struct QueueState
  ## The items, oldest first.
  items: List[String]
end

## Returns an empty queue.
export def new() -> QueueState
  return QueueState(items: [])
end
```

### 32.5 `agentica doc`

The command, its exit codes and the Markdown form are in
[`06b-builtins.md`](../grammar/06b-builtins.md). The `--json` form is the
contract that `compiler/docs/doc_json.agc` and `tests/test_spec_doc.py` cite:

- `agentica doc PATH --json` prints the same data as one JSON object. The format
  is stable, so agents and a future site generator can read it. Each field means
  the same wherever it appears:
  - top level: `{module, doc, items}`;
  - `module`: `PATH` as the user typed it, a file path or a `std/` name;
  - `doc`: the whole doc text with the `##` markers removed and its leading and
    trailing blank lines dropped, or `null`. At the top level it is the module
    doc;
  - `summary`: the first paragraph of `doc` on one line, each line trimmed, or
    `null` when there is none;
  - `items`: one object per export, in source order:
    `{kind, name, signature, summary, doc, span}`;
  - `kind`: `"function"`, `"struct"`, `"enum"`, `"alias"` or `"constant"`;
  - `signature`: the line above; an alias is `type Grid[T] = List[List[T]]`
    and a constant is `LIMIT: Int` (`LIMIT` without a written type);
  - `span`: the declaration's span, from `export` to the end of the
    declaration, not its `##` block: an object
    `{file, range: {start: {line, column}, end: {line, column}}}`, the two keys
    a diagnostic JSON puts at its top level, in an object of their own. Lines
    and columns start at 1 and `end` is exclusive, as in a diagnostic;
  - a function item also has `parameters`, a list of `{name, type, default}`
    (`default` is the source text of the default value, or `null`), and
    `result`, its result type;
  - a struct item also has `fields`: `[{name, type, default, doc}]`, with
    `default` as for a parameter;
  - an enum item also has `variants`: `[{name, payload: [type], doc}]`, with
    `payload` empty for a variant without one;
  - every type is a string, printed as written.

Decisions:

- **Parse only.** It lexes and parses one module and does not resolve imports or
  type-check, so it cannot fail on a dependency. A module that re-exports a name
  is linked to list the original declaration with its doc; if it does not link,
  it lists no re-export. A `std/` name reads the copy embedded in the binary,
  and a `PATH` that starts with `std/` always names an embedded module
  (`std/prelude/` and paths with `.`, `..` or empty parts exit 2).
- **Signatures** are one normalized line built from the AST in the form the
  builtin catalog uses (`add(a: Int, b: Int = 2) -> Int`, `struct QueueState`,
  `enum Option[T]`); types print as written, so an import alias such as
  `Models.User` stays.
- An export without a doc is still listed, with its signature only; private
  declarations are left out (their docs are for readers of the code); a `span`
  covers the declaration from `export`, not its `##` block.

### 32.6 `agentica help` for `std/`

`agentica help std/MODULE[.NAME] [--json]` reads a module as `doc` does and uses
the builtin help fields that apply, with `description` set to the whole doc and
`summary` added, and no `effects` (grammar, `06b-builtins.md`). An unknown
module or name exits 2, with "did you mean" over the module's exports. Builtins
keep the catalog help; user files are served by `agentica doc file.agc`.

### 32.8 Later, to evaluate

- **Doctests:** run the fenced `agentica` examples of `std/` docs in a test, as
  the site examples test does for the site. They would need an `output` block
  convention.
- **Site pages:** generate the Library pages of `std/` modules in
  `site/content/library/` from `agentica doc --json`, instead of writing them by
  hand.
- **Builtin docs:** move the builtin catalog descriptions to doc comments, once
  more builtins become `std/` wrappers.
- **Editors:** hover text in an editor, if a language server is built
  ([§43](43-language-server.md)).
- **Rejected for now:**
  - An Elixir-style `@doc` attribute. It needs attribute syntax and multi-line
    strings, and it would put docs into the compiled program, which no current
    tool needs.
  - YARD-style `@param` tags. The types are already in the signature.
