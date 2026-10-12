## 32. Doc comments

**Status:** planned (roadmap [phase 22](../roadmap/22-doc-comments.md)). Decided on 2026-10-12: Agentica gets documentation comments written as `##` lines, in the style of Rust's `///`, so that a later tool can generate documentation from the code. The user asked for this as soon as possible: phase 22 is front end only and does not change the evaluator, so it goes before 7i (§32.7).

The idea in one paragraph: a run of lines that start with `##` documents the declaration on the next line. `#` stays an ordinary comment that tools ignore. The text is Markdown. A `##` run at the top of a file documents the module. The parser keeps each run with its declaration, and two tools read it: `agentica doc`, which prints a module's exported API with its docs, and `agentica help`, which learns to show `std/` functions. No tags such as `@param` are needed, because the types are in the signature.

### 32.1 Today

Checked at `650f689`:

- A comment starts with `#` and ends at the end of the line (`docs/grammar.md:59`). The lexer drops it (`src/lexer.rkt:166-168`), so nothing after the lexer sees comments.
- A line with only a comment counts as blank for the blank-line rule between declarations (`docs/grammar.md:146`, `PARSE-MISSING-BLANK-LINE` at `src/parser.rkt:114`).
- `agentica help NAME [--json]` shows only builtins, from the catalog in `src/builtins.rkt` (`src/main.rkt:199-212`). It cannot show a function of a `std/` module or of a user file.
- `stdlib/*.agc` documents itself with plain `#` comments, if at all (`stdlib/queue.agc:1`).
- No `.agc` file in the repo has a line that starts with `##`, so the new rule of §32.2 breaks no existing program here.

### 32.2 Syntax

- A **doc line** is a line whose first non-blank characters are `##`. The text is the rest of the line after `##` and one optional space. `##` alone is an empty doc line, which separates paragraphs.
- Only the first two `#`s are the marker: `### Heading` is a doc line whose text is `# Heading`, a Markdown heading.
- A `##` after code on the same line (`x = 1 ## note`) is an ordinary comment, not a doc line.
- A **doc block** is one or more consecutive doc lines. There is nothing between them; an ordinary `#` comment line ends the block.
- A doc block documents what comes on the next line, which must be one of:
  - a declaration: `def`, `struct`, `enum`, with or without `export`;
  - a field inside a `struct`;
  - a variant inside an `enum`.
- The **module doc** is a doc block at the very start of the file, before any import or declaration, followed by a blank line. A file has at most one.
- Any other doc block is an error, `PARSE-DETACHED-DOC`, at its first line. That covers:
  - a doc block followed by a blank line (other than the module doc);
  - a doc block followed by an ordinary `#` comment line;
  - a doc block followed by an `import`;
  - a doc block inside a function body;
  - a doc block at the end of the file.

  Agentica has no warnings (§26), so a detached doc is an error rather than a silent comment.
- **Blank-line rule:** a doc line does not count as blank, because it belongs to the declaration after it. The blank line that `PARSE-MISSING-BLANK-LINE` asks for goes before the doc block:

```agentica
## Adds two numbers.
def add(a: Int, b: Int) -> Int
  return a + b
end

## Subtracts `b` from `a`.
def sub(a: Int, b: Int) -> Int
  return a - b
end
```

- **Strings:** `##` inside a string literal or an interpolation is text, as today.

### 32.3 Content

- The text is CommonMark. Tools print it as it is written, with the `##` markers removed.
- The first paragraph is the **summary**: one sentence that says what the declaration does. `agentica doc` and `help` show it in lists. The rest is the description.
- Code examples go in fenced blocks marked `agentica`. Phase 22 does not run them; doctests are an option to evaluate later (§32.8).
- There are no tags. Parameter names, types and the result come from the signature. When a parameter needs explaining, the text names it in backticks.
- Docs are optional. No diagnostic asks for them. One repo test (22a) requires a doc on every export of `stdlib/*.agc`.
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

### 32.4 Where the docs live

- The lexer keeps doc lines instead of dropping them and emits one `DOC` token per doc block. The token carries the text and the span of the whole block. Inside parentheses, brackets or braces, where no `NL` is emitted, a doc line is still an error (`PARSE-DETACHED-DOC`).
- The parser attaches each `DOC` token to the declaration, field or variant on the next line, or makes it the module doc.
- The docs do not go into the existing AST structs. The parser returns them in a side table on `program`: a map from each documented declaration's span to its doc text, plus the module doc. So the checker, lowering, the bytecode and the frozen evaluator see the same AST as before, and the `.agcb` format does not change.
- `src/modules.rkt` keeps each module's table, so the tools can read the docs of `std/` and imported modules.

### 32.5 `agentica doc`

- `agentica doc PATH` prints the exported API of one module as Markdown:
  1. the module doc;
  2. then each exported declaration in source order, with its signature as written (a `def` line, or a `struct` or `enum` with its fields or variants) followed by its doc.
- An export without a doc is still listed, with its signature only.
- `PATH` is a source file or a `std/` module name (`std/http`).
- `agentica doc PATH --json` prints the same data as one JSON object:
  - `module`: the path or name;
  - `doc`: the module doc, or `null`;
  - `items`: a list of objects with `kind` (`"function"`, `"struct"`, `"enum"`), `name`, `signature`, `doc` (or `null`), `span`, and for structs and enums `fields` or `variants`, each with its own `doc`.

  The format is stable, so agents and a future site generator can read it.
- The file is lexed, parsed and linked, but not type-checked. A file with a lex or parse error gives that one diagnostic and exit 1; unknown paths give exit 2, as `help` does.
- Private declarations are left out. Their docs exist for readers of the code.

### 32.6 `agentica help` for `std/`

- `agentica help std/http.get` (module path, `.`, export name) shows that function's signature and doc, in text or `--json`.
- The JSON uses the same fields as the builtin help where they apply (`name`, `signature`, `description`), with `description` taken from the doc.
- `agentica help std/http` lists the module's exports with their summaries.
- An unknown name gives exit 2 with "did you mean" over that module's exports.
- Builtins keep today's help, from the catalog.
- User files are not covered: `agentica doc file.agc` serves them.

### 32.7 Order and the evaluator

- **Why it can go before 7i.** "New features are VM-only and come after 7i" exists so that the frozen evaluator gets no new behaviour. Doc comments change only the lexer, the parser, `src/modules.rkt` and the CLI, and the AST that the evaluator reads keeps its shape (§32.4). So the user's request "as soon as possible" is met without touching the evaluator.
- **When.**
  - 22a and 22b go right after the PR that is open now (HTTP 20a) and the two small PRs queued behind it: trimming `AGENTS.md`, then the shorter golden sweep.
  - They go before 20b.
  - 20a's `stdlib/http.agc` is documented in 22a.
- **How the backends are affected.** Both backends run programs with doc comments the same way, because docs never reach them.

### 32.8 Later, to evaluate

- **Doctests:** run the fenced `agentica` examples of `std/` docs in a test, as `tests/site-examples-test.rkt` does for the site. They would need an `output` block convention.
- **Site pages:** generate the Library pages of `std/` modules in `site/content/library/` from `agentica doc --json`, instead of writing them by hand.
- **Builtin docs:** move the builtin catalog descriptions to doc comments, once more builtins become `std/` wrappers.
- **Editors:** hover text in an editor, if a language server is ever built.
- **Rejected for now:**
  - An Elixir-style `@doc` attribute. It needs attribute syntax and multi-line strings, and it would put docs into the compiled program, which no current tool needs.
  - YARD-style `@param` tags. The types are already in the signature.
