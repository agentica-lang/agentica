## 32. Doc comments

**Status:** 22a is built; 22b (§32.5, §32.6) waits until after the bootstrap
(roadmap [row 22b](../roadmap/README.md)). Decided on 2026-10-12: Agentica has
documentation comments written as `##` lines, in the style of Rust's `///`, so
that a later tool generates documentation from the code. The `##` syntax, the
`DOC` token, the parser side table and the `std/` docs of 22a are in the grammar
([`04-lexical.md`](../grammar/04-lexical.md#doc-comments) for the token and
section 5 for where a block may stand); the parser keeps each block with its
declaration in a side table, so the AST, the bytecode and the VM do not change
and a program with doc comments runs as before.

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
- `PATH` is a source file or a `std/` module name (`std/http`).
- **Parse only.** `agentica doc` lexes and parses one module. It does not link
  it, resolve its imports or type-check it, so it cannot fail on a dependency.
  For a `std/` name the source is the copy embedded in the binary.
  - A lex or parse error gives that diagnostic and exit 1.
  - An unknown file or `std/` module gives exit 2, as `help` does.
- **Signatures.** A signature is one normalized line built from the AST, in the
  form the builtin catalog uses:
  - a function: `add(a: Int, b: Int) -> Int`;
  - a struct: `struct QueueState`;
  - an enum: `enum Option[T]`.

  Types are printed as written, so an import alias such as `Models.User` stays
  as it is.
- `agentica doc PATH --json` prints the same data as one JSON object. The format
  is stable, so agents and a future site generator can read it. Each field means
  the same wherever it appears:
  - top level: `{module, doc, items}`;
  - `module`: `PATH` as the user typed it, a file path or a `std/` name;
  - `doc`: the whole doc text with the `##` markers removed, or `null`. At the
    top level it is the module doc;
  - `summary`: the first paragraph of `doc`, or `null`;
  - `items`: one object per export, in source order:
    `{kind, name, signature, summary, doc, span}`;
  - `kind`: `"function"`, `"struct"` or `"enum"`;
  - `signature`: the line above;
  - `span`: the declaration's span, an object
    `{file, range: {start: {line, column}, end: {line, column}}}`, the two keys
    a diagnostic JSON puts at its top level, in an object of their own;
  - a function item also has `parameters`, a list of `{name, type}`, and
    `result`, its result type;
  - a struct item also has `fields`: `[{name, type, doc}]`;
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

- One PR in `compiler/`: `agentica doc PATH [--json]` and
  `agentica help std/MODULE[.NAME] [--json]`; lex and parse only, from the
  embedded `stdlib/`; the objects of §32.5 and §32.6; exit 1 for a lex or
  parse error, 2 for an unknown file, module or name.
- Tests: Markdown and JSON for a fixture module (documented and
  undocumented exports, a private declaration left out, fields, variants,
  an import alias); a file whose import does not exist;
  `help std/http.get` and `help std/http`; the exit codes and
  "did you mean".
- Docs: the `agentica help` paragraph of `docs/grammar/06b-builtins.md`,
  the programming skill, `site/content/getting-started.md`, the development
  skill.
- Done when: `agentica doc std/http` prints its API, and the doc tests pass.
