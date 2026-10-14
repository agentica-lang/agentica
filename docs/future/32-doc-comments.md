## 32. Doc comments

**Status:** 22a is built (§32.2 to §32.4: the `##` syntax, the parser side table and the `std/` docs); 22b (§32.5, §32.6) is planned (roadmap [phase 22](../roadmap/22-doc-comments.md)). Decided on 2026-10-12: Agentica gets documentation comments written as `##` lines, in the style of Rust's `///`, so that a later tool can generate documentation from the code. Phase 22 is front end only. It comes after 7i, HTTP 20b, task crash isolation (§37), unit tests (§36) and HTTP 20c (roadmap order step 7.2.1), and after the evaluation pilot (order step 7.2.2, §32.7).

The idea in one paragraph: a run of lines that start with `##` documents the declaration on the next line. `#` stays an ordinary comment that tools ignore. The text is Markdown. A `##` run at the top of a file documents the module. The parser keeps each run with its declaration, and two tools read it: `agentica doc`, which prints a module's exported API with its docs, and `agentica help`, which learns to show `std/` functions. No tags such as `@param` are needed, because the types are in the signature.

### 32.1 Today

Checked at `650f689`:

- A comment starts with `#` and ends at the end of the line (`docs/grammar/04-lexical.md`). The lexer drops it (`src/lexer.rkt:166-168`), so nothing after the lexer sees comments.
- A line with only a comment counts as blank for the blank-line rule between declarations (`docs/grammar/05-syntax.md`, `PARSE-MISSING-BLANK-LINE` at `src/parser.rkt:114`).
- `agentica help NAME [--json]` shows only builtins, from the catalog in `src/builtins.rkt` (`src/main.rkt:199-212`). It cannot show a function of a `std/` module or of a user file.
- `stdlib/*.agc` documents itself with plain `#` comments, if at all (`stdlib/queue.agc:1`). The CLI holds a copy of each file in `stdlib-sources` (`src/stdlib.rkt:17`).
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
- The **module doc** is the first doc block of the file when only blank lines and ordinary `#` comment lines come before it. A blank line must follow it. A `#` comment line right after it does not count as that blank line, so that case is `PARSE-DETACHED-DOC`. A file has at most one module doc.
- Any other doc block is an error, `PARSE-DETACHED-DOC`, at its first line. That covers:
  - a doc block followed by a blank line (other than the module doc);
  - a doc block followed by an ordinary `#` comment line;
  - a doc block followed by an `import`;
  - a doc block inside a function body;
  - a doc block at the end of the file.

  Agentica has no warnings (§26), so a detached doc is an error rather than a silent comment.
- **Blank-line rule:** a doc line does not count as blank, because it belongs to the declaration after it. The blank line that `PARSE-MISSING-BLANK-LINE` asks for goes before the doc block. When a doc block follows a declaration's `end` without a blank line, `PARSE-MISSING-BLANK-LINE` is reported at the doc block's first line.

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
- The first paragraph is the **summary**: one sentence that says what the declaration does. `agentica doc` and `help` show it in lists.
- Code examples go in fenced blocks marked `agentica`. Phase 22 does not run them; doctests are an option to evaluate later (§32.8).
- There are no tags. Parameter names, types and the result come from the signature. When a parameter needs explaining, the text names it in backticks.
- Docs are optional. No diagnostic asks for them. One repo test (22a) requires a module doc in every `stdlib/*.agc` and a doc on each of its exports.
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
- The docs do not go into the existing AST structs. The parser returns them in a side table on `program`: a map from the span of each documented declaration, field or variant to its doc text, plus the module doc. So the checker, lowering and the bytecode see the same AST as before, and the `.agcb` format does not change.
- `agentica doc` and `help` read the table straight from the parser (§32.5), so they need no linking. `src/modules.rkt` only copies the root file's table and module doc into the linked `program`.

### 32.5 `agentica doc`

- `agentica doc PATH` prints the exported API of one module as Markdown:
  1. the module doc;
  2. then each exported declaration in source order: its signature, its doc, and for a struct or enum its fields or variants with their docs.
- An export without a doc is still listed, with its signature only.
- `PATH` is a source file or a `std/` module name (`std/http`).
- **Parse only.** `agentica doc` lexes and parses one module. It does not link it, resolve its imports or type-check it, so it cannot fail on a dependency. For a `std/` name the source is the embedded copy in `stdlib-sources`.
  - A lex or parse error gives that diagnostic and exit 1.
  - An unknown file or `std/` module gives exit 2, as `help` does.
- **Signatures.** A signature is one normalized line built from the AST, in the form of `builtin-signature` (`src/builtins.rkt:264-272`):
  - a function: `add(a: Int, b: Int) -> Int`;
  - a struct: `struct QueueState`;
  - an enum: `enum Option[T]`.

  Types are printed as written, so an import alias such as `Models.User` stays as it is.
- `agentica doc PATH --json` prints the same data as one JSON object. The format is stable, so agents and a future site generator can read it. Each field means the same wherever it appears:
  - top level: `{module, doc, items}`;
  - `module`: `PATH` as the user typed it, a file path or a `std/` name;
  - `doc`: the whole doc text with the `##` markers removed, or `null`. At the top level it is the module doc;
  - `summary`: the first paragraph of `doc`, or `null`;
  - `items`: one object per export, in source order: `{kind, name, signature, summary, doc, span}`;
  - `kind`: `"function"`, `"struct"` or `"enum"`;
  - `signature`: the line above;
  - `span`: the declaration's span, an object `{file, range: {start: {line, column}, end: {line, column}}}`, the two keys `diagnostic->jsexpr` puts at the top level of a diagnostic (`src/diagnostic.rkt:130`), in an object of their own;
  - a function item also has `parameters`, a list of `{name, type}`, and `result`, its result type;
  - a struct item also has `fields`: `[{name, type, doc}]`;
  - an enum item also has `variants`: `[{name, payload: [type], doc}]`, with `payload` empty for a variant without one;
  - every type is a string, printed as written.
- Private declarations are left out. Their docs exist for readers of the code.

### 32.6 `agentica help` for `std/`

- `agentica help std/http.get` (module path, `.`, export name) shows that function's signature and doc, in text or `--json`. It reads the module the same way as `agentica doc` (§32.5).
- `agentica help std/MOD.NAME --json` uses the builtin help fields that apply (`src/builtins.rkt:274-283`): `name`, `arity`, `parameters`, `result` and `signature`, with `description` set to the whole doc (or `null`) and `summary` added (§32.5). It has no `effects`.
- `agentica help std/http` lists the module's exports with their summaries. With `--json` it prints `{module, doc, items: [{kind, name, summary}]}`, with the fields of §32.5.
- An unknown module or name gives exit 2, with "did you mean" over that module's exports for a name.
- Builtins keep today's help, from the catalog.
- User files are not covered: `agentica doc file.agc` serves them.

### 32.7 Order and the evaluator

- **Front end only.** Doc comments change only the lexer, the parser and the CLI, and the AST keeps its shape (§32.4).
- **When.** Decided by the user on 2026-10-13: 22a and 22b come after 7i, at roadmap order step 7.2a: after order step 7.2.1 (HTTP 20b, task crash isolation (§37), unit tests (§36), then HTTP 20c, which also took what was left of 20d; placed there by the owner on 2026-10-13) and after the evaluation pilot (order step 7.2.2, added by the owner on 2026-10-13), and before digit separators (§33) and before `Task.map` (order step 7.3); channels come earlier, at row 7.2.1e. They are no longer an exception to "new features are VM-only and come after 7i".
  - `stdlib/http.agc` (HTTP 20a and 20c) is documented in 22a.
- **How the VM is affected.** It runs programs with doc comments as before, because docs never reach it.

### 32.8 Later, to evaluate

- **Doctests:** run the fenced `agentica` examples of `std/` docs in a test, as `tests/site-examples-test.rkt` does for the site. They would need an `output` block convention.
- **Site pages:** generate the Library pages of `std/` modules in `site/content/library/` from `agentica doc --json`, instead of writing them by hand.
- **Builtin docs:** move the builtin catalog descriptions to doc comments, once more builtins become `std/` wrappers.
- **Editors:** hover text in an editor, if a language server is ever built.
- **Rejected for now:**
  - An Elixir-style `@doc` attribute. It needs attribute syntax and multi-line strings, and it would put docs into the compiled program, which no current tool needs.
  - YARD-style `@param` tags. The types are already in the signature.
