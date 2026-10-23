## 32. Doc comments

**Status:** 22a and `agentica doc` (§32.5, part 1 of 22b) are built; `agentica
help` for `std/` (§32.6) is not (roadmap [row 22b](../roadmap/README.md)).
Decided on 2026-10-12: Agentica has documentation comments written as `##`
lines, in the style of Rust's `///`, so that a later tool generates
documentation from the code. The `##` syntax, the `DOC` token and the `std/`
docs of 22a are in the grammar
([`04-lexical.md`](../grammar/04-lexical.md#doc-comments) for the token and
section 5 for where a block may stand); the parser keeps each block in the `doc`
field of its declaration, field or variant (`Program.module_doc` for the module
doc; `compiler/syntax/ast.agc`), so the bytecode and the VM do not change and a
program with doc comments runs as before. The doc of an exported `def`,
`struct`, `enum` or alias is on its `ExportDecl`, not on the declaration inside
it.

The idea in one paragraph: a run of lines that start with `##` documents the
declaration on the next line. `#` stays an ordinary comment that tools ignore.
The text is Markdown. A `##` run at the top of a file documents the module. Two
tools read it: `agentica doc`, which prints a module's exported API with its
docs, and `agentica help`, which learns to show `std/` functions. No tags such
as `@param` are needed, because the types are in the signature.

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

- `agentica doc PATH` prints the exported API of one module as Markdown:
  1. the module doc;
  2. then each exported declaration in source order: its signature, its doc, and
     for a struct or enum its fields or variants with their docs.
- An export without a doc is still listed, with its signature only.
- `PATH` is a source file or a `std/` module name (`std/http`). A `PATH` that
  starts with `std/` always names an embedded standard module, as an import
  does: `std/prelude/` and a path with `.`, `..` or empty parts exit 2.
- **Parse only.** `agentica doc` lexes and parses one module. It does not link
  it, resolve its imports or type-check it, so it cannot fail on a dependency.
  For a `std/` name the source is the copy embedded in the binary.
  - A lex or parse error gives that diagnostic and exit 1.
  - An unknown file or `std/` module gives exit 2, as `help` does.
- **Signatures.** A signature is one normalized line built from the AST, in the
  form the builtin catalog uses:
  - a function: `add(a: Int, b: Int = 2) -> Int`, a default value as written
    in the source;
  - a struct: `struct QueueState`;
  - an enum: `enum Option[T]`.

  Types are printed as written, so an import alias such as `Models.User` stays
  as it is.
- The Markdown form starts with `# PATH`, then the module doc, then for each
  export a heading with its signature, its doc, and a list line per field or
  variant.
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
- Private declarations are left out. Their docs exist for readers of the code.

### 32.6 `agentica help` for `std/`

- `agentica help std/http.get` (module path, `.`, export name) shows that
  function's signature and doc, in text or `--json`. It reads the module the
  same way as `agentica doc` (§32.5).
- `agentica help std/MOD.NAME --json` uses the builtin help fields that apply:
  `name`, `arity`, `parameters`, `result` and `signature`, with `description`
  set to the whole doc (or `null`) and `summary` added (§32.5). It has no
  `effects`.
- `agentica help std/http` lists the module's exports with their summaries. With
  `--json` it prints `{module, doc, items: [{kind, name, summary}]}`, with the
  fields of §32.5.
- An unknown module or name gives exit 2, with "did you mean" over that module's
  exports for a name.
- Builtins keep today's help, from the catalog.
- User files are not covered: `agentica doc file.agc` serves them.

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

### 32.9 Implementation (row 22b)

Pending: `agentica help std/MODULE[.NAME] [--json]` (§32.6), one PR in
`compiler/`, lex and parse only, from the embedded `stdlib/`.
