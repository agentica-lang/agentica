# Pipeline stages reference

Contracts of the Agentica front end in `compiler/`. Read this when adding or
renaming a token, AST node, or diagnostic code. Each stage has an entry program
that prints its text form (`lex.agc`, `parse.agc`, `link.agc`, `check.agc`,
`lower.agc`, `bytecode.agc`); the goldens in `tests/fixtures/frontend/<stage>/`
pin those texts (`references/frontend.md`).

## Conventions

- A span end is exclusive; offsets count characters (code points); line and
  column are 1-based.
- Every stage takes the previous stage's data and returns the next data or one
  diagnostic (`Outcome[T]` or `Result[T]` with a packed diagnostic), stops at
  the first error, and never prints. A failed internal assumption is a
  `*-INTERNAL` diagnostic, never a crash.
- The diagnostic forms (`compiler/diagnostics/diagnostic_plain.agc`,
  `diagnostic_ai.agc`, `diagnostic_json.agc`) render a located header, message,
  source marks/labels, and grounded help from the same data; `vm/diag.c` prints
  the same forms for runtime errors.

## Source and tokens

`compiler/syntax/source.agc` holds `Position` (offset, line, column) and `Span`
(source, start, end). `compiler/syntax/token.agc` holds `Token` (kind string,
lexeme, `Value`, span); `Value` is the decoded literal (`Text`, `Whole`, `Huge`,
`Real`) or `NoValue`, or a `DocBlock` for a `DOC` token: `text` is the doc lines
with the `##` markers and one optional space removed, joined by newlines; `next`
says what the line after the block is: `blank`, `comment`, `eof` or `code`. The
lexer works this out because the `NL` tokens of a blank line and of a `#`
comment line look the same.

### Token kinds

Kinds are Strings, listed in `OPERATOR_KINDS` and `WORD_ACTIONS` of
`compiler/syntax/lexer.agc`; a reserved word is its own kind. Notes:

- `name` starts with a lowercase letter or `_`; `type-name` with an uppercase
  letter. `integer` and `float` are decimal literals; `string` holds the decoded
  contents; `interp-start`, `interp-middle` and `interp-end` hold the decoded
  text before, between and after `#{...}` pieces, and the expression tokens
  come between them.
- `dot-dot` and `dot-dot-dot` are ranges; `1..5` stays two integers, since a
  Float needs a digit after the dot.
- `pipe` is `|` (block parameters) and `pipe-forward` is `|>` (longest match,
  so `do |x|` and `||` are unchanged). `&&`, `||` and `!` are the kinds `and`,
  `or` and `not`; a `!` glued to a name stays in the name, and `!=` stays
  `not-equal`.
- The parser desugars `x op= e` (`plus-assign` and the like) into `binding x #f
  (binary op ...)`.
- `DOC` is one block of `##` doc lines: the lexeme is the raw block, the span
  covers it from the first `##` to the end of the last line, and the `NL` of
  the line break after it follows as usual.

The parser reads the keyword literals from their kind, not from `value`: `true`,
`false` and `nil` are literals.

## Diagnostics

`compiler/diagnostics/diagnostic.agc` holds `Diagnostic` (code, message, span,
optional expected, actual, callee, signature, labels and help). The codes by
stage:

- **Stage:** lexer
  - **Codes:** `LEX-UNEXPECTED-CHAR`, `LEX-UNCLOSED-DELIMITER`,
    `LEX-UNMATCHED-DELIMITER`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`,
    `LEX-INVALID-NUMBER`, `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`,
    `LEX-HEREDOC-ONE-LINE`, `LEX-INVALID-UTF8` (raised by
    `compiler/io/source_reader.agc` when a source file is read, not by the
    lexer: the span is one character at the first byte of the first sequence
    that does not decode)

- **Stage:** parser
  - **Codes:** `PARSE-PIPE-TARGET`, `PARSE-UNEXPECTED-TOKEN`,
    `PARSE-UNCLOSED-BLOCK`, `PARSE-TOP-LEVEL-STATEMENT`,
    `PARSE-CHAINED-COMPARISON`, `PARSE-INVALID-ASSIGNMENT-TARGET`,
    `PARSE-CONSTANT-NAME`, `PARSE-MISSING-BLANK-LINE`, `PARSE-DETACHED-DOC`,
    `PARSE-TOO-DEEP`, `PARSE-EXTERN-TYPE`, `PARSE-EXTERN-NAME`,
    `PARSE-EXTERN-DEFAULT`, `PARSE-EXTERN-ARITY`, `PARSE-EXTERN-LIBRARY`

- **Stage:** checker
  - **Codes:** `CHECK-CONSTANT-CYCLE`, `CHECK-CONSTANT-EXPRESSION`,
    `CHECK-CONSTANT-TYPE`, `CHECK-VOID-TYPE`, `CHECK-VOID-VALUE`,
    `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-REDEFINED-NAME`,
    `CHECK-ARITY`, `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`,
    `CHECK-TYPE-MISMATCH`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`,
    `CHECK-EMPTY-SET-TYPE`, `CHECK-RESULT-TYPE`, `CHECK-EXPECTED-TYPE`,
    `CHECK-TRY-CONTEXT`, `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`,
    `CHECK-MISSING-FIELD`, `CHECK-UNKNOWN-METHOD`, `CHECK-PIPE-METHOD`,
    `CHECK-UNUSED-VALUE`, `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET`,
    `CHECK-CAPTURED-ASSIGNMENT`, `CHECK-NOT-A-HANDLE`, `CHECK-NOT-A-LIST`,
    `CHECK-NOT-INDEXABLE`, `CHECK-MAP-KEY-TYPE`, `CHECK-SET-ELEMENT-TYPE`,
    `CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`, `CHECK-SHADOWED-NAME`,
    `CHECK-ANNOTATION-ON-EXISTING`, `CHECK-IMMUTABLE-ASSIGNMENT`,
    `CHECK-MISSING-RETURN`, `CHECK-MAIN`, `CHECK-INT-RANGE`, `CHECK-INTERNAL`,
    `CHECK-MODULE-CONTEXT`, `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`,
    `CHECK-IMPORT-CYCLE`, `CHECK-IMPORT-NAME`, `CHECK-IMPORT-RENAME`,
    `CHECK-IMPORT-PACKAGE`,
    `CHECK-DECL-ORDER`, `CHECK-TYPE-ALIAS-CYCLE`, `CHECK-UNKNOWN-VARIANT`,
    `CHECK-ENUM-POSITIONAL-ARGS`, `CHECK-ENUM-TYPE-INFERENCE`,
    `CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE`,
    `CHECK-UNREACHABLE-CASE-ARM`, `CHECK-LOOP-CONTROL`, `CHECK-TOO-DEEP`

- **Stage:** packages (`packages/`, `package_import.agc`)
  - **Codes:** `PKG-MANIFEST-INVALID`, `PKG-LOCK-INVALID`, `PKG-LOCK-MISSING`,
    `PKG-LOCK-STALE`, `PKG-SOURCE-CONFLICT`, `PKG-HASH-MISMATCH`, `PKG-SYMLINK`.
    Manifest, lock, stale and conflict errors are at a key path
    (`Failure.fail_key`, `Problem.key_path`); a TOML syntax error is at its line
    and column; a missing or unreadable file has no key (`Failure.fail_file`).
    The manifests of the locked packages are checked before any file loads
    (`check_manifests`). The hash and link errors are at the import.
    `agentica install` (`app/cli_install.agc`, `io/package_fetch.agc`) adds
    `PKG-FETCH`, `PKG-TAG-MOVED`, `PKG-PATH-COLLISION` and
    `PKG-MANIFEST-MISSING`, and also reports `PKG-HASH-MISMATCH` and
    `PKG-SYMLINK`, all at a key of `agentica.lock` (`package[N].tag`, ...).
    `agentica vendor` (`app/cli_vendor.agc`, `io/package_vendor.agc`) reports
    those at the lock too, `PKG-SYMLINK` for an agc_libs/ that is a link and
    `PKG-WRITE` at the file it cannot write. A vendored copy `agc_libs/<name>/`
    is read before the cache (`package_import.agc`, `source_of`) and hashed.
    `agentica add` and `update` (`app/cli_add.agc`, `io/package_resolve.agc`)
    report the fetch codes of a new pin at `dependencies.<name>.git` of the
    manifest that asks for it, and add `PKG-DEPENDENCY-EXISTS`,
    `PKG-DEPENDENCY-UNKNOWN`, `PKG-MANIFEST-EDIT` and `PKG-WRITE`.

- **Stage:** query (`query/`, `outline`, `type-at`, `refs`, `symbol`)
  - **Codes:** exit 2, at `<arguments>` (line 1, column 1): `QUERY-USAGE` (bad
    arguments, `--stdin` without a file, a bad `FILE:LINE:COL`, an unreadable
    path, a folder with no `*.agc`), `QUERY-NOT-FOUND` (`symbol` or `refs` NAME
    is in no linked module and no builtin), `QUERY-AMBIGUOUS-NAME` (a `refs`
    NAME that several declarations answer to, `refs_name.agc`).
    `QUERY-NO-EXPRESSION`, at the position, exit 2: `type-at` or `refs` on no
    expression or name (`refs` also on a module alias or a path of an import
    line). The stage reads the words (`query_options.agc`), picks and names the
    file (`query_files.agc`) and lists the declarations (`outline*.agc`).
    `outline` only lexes and parses, so its `LEX-` or `PARSE-` keeps its code,
    exit 1; it reuses `docs/` for the items. `type-at` and `refs` link and
    check, so they can fail with any `LEX-`, `PARSE-`, `PKG-` or `CHECK-` code,
    exit 1; `symbol` exits 1 only when no file links.

- **Stage:** runtime (VM)
  - **Codes:** `RUNTIME-PROCESS-CLOSE`, `RUNTIME-DIVISION-BY-ZERO`,
    `RUNTIME-INTEGER-OVERFLOW`, `RUNTIME-INDEX-OUT-OF-RANGE`,
    `RUNTIME-KEY-NOT-FOUND`, `RUNTIME-INVALID-NUMBER`,
    `RUNTIME-INVALID-CHARACTER`, `RUNTIME-INVALID-RANGE`,
    `RUNTIME-END-OF-INPUT`, `RUNTIME-UNWRAP-ERROR`, `RUNTIME-JSON-ENCODE`,
    `RUNTIME-STEP-LIMIT`, `RUNTIME-STACK-OVERFLOW`, `RUNTIME-UNREACHABLE`,
    `RUNTIME-INTERNAL`, `RUNTIME-INVALID-DURATION`, `RUNTIME-TASK-CANCELLED`,
    `RUNTIME-TASK-AWAIT-CYCLE`, `RUNTIME-TASK-CRASHED`,
    `RUNTIME-HANDLE-NOT-OWNED`, `RUNTIME-TEST-ASSERTION`, `RUNTIME-TEST-ERROR`,
    `RUNTIME-TEST-NAME`, `RUNTIME-TEST-PENDING-TASKS`, `RUNTIME-TEST-RUN`,
    `RUNTIME-TEST-TIMEOUT`, `RUNTIME-NATIVE-LOAD`, and at load (exit 2)
    `RUNTIME-NATIVE-DENIED`, `RUNTIME-NATIVE-UNSUPPORTED`

- **Stage:** lowering (VM)
  - **Codes:** `LOWER-UNSUPPORTED`, `LOWER-INTERNAL`, `BYTECODE-LIMIT`,
    `BYTECODE-INTERNAL` (`compiler/lower/lowering.agc`,
    `compiler/bytecode/bytecode_writer.agc`; see `docs/vm/03-ir-and-bytecode.md`
    3.5)

Network and protocol failures otherwise return Results; handler and
producer diagnostics retain their original code and span.

## Lexer (`compiler/syntax/lexer.agc`)

`lex: String -> Outcome[List[Token]]`. One pass over the source:

- CRLF normalizes to one newline; a lone carriage return is
  `LEX-UNEXPECTED-CHAR`.
- `NL` is suppressed inside `()`, `[]`, and `{}`; each LF/CRLF outside them
  emits one NL, including blank/comment lines.
- A final `NL` is synthesized before `EOF` when the file does not end with one.
- `#` starts a comment that runs to the end of the line.
- A line whose first non-blank characters are `##` starts a doc block
  (`compiler/syntax/lexer.agc` looks back over blanks to the line break): the
  lexer reads the consecutive doc lines into one `DOC` token, with the text
  after `##` and one optional space (`###` keeps its third `#` in the text). A
  `##` after code on the line is a plain comment. A bare carriage return after a
  doc line is still `LEX-UNEXPECTED-CHAR`, found by the main loop. The token is
  emitted inside brackets too; the parser rejects it there.
- A lowercase name may end in `?` or `!` regardless of whitespace before `(`;
  `!` followed by `=` stays an operator, so `a!=b` is still `a != b`. The parser
  rejects suffixes on bindings, parameters, and fields. `try` is a keyword.
- Number literals read digits and `_` in both parts (`1_000.000_5`), drop the
  `_`s for the value and keep them in the lexeme. `LEX-INVALID-NUMBER` (a
  trailing `_`, a `__`, or a `_` next to the dot) spans the literal as written.
  A `.` followed by a digit or `_` continues the number; a letter or another `.`
  ends it (`1_000.times`, `1_000..2_000`). The text conversions
  (`String.to_int`, JSON) stay strict and reject `_`.
- A heredoc `<<~NAME` is the `CharClass.Less` arm of the main loop.
  `scan_heredoc` reads the body lines from the line after the opener (or from
  the `Resume` that an earlier heredoc of the same line left), takes the common
  indentation off, and emits the string tokens at the place of the opener, all
  with the span of `<<~NAME`. Each `#{...}` is lexed by `lex_from`, the main
  loop itself, started inside the line with the `#` frame pushed and
  `stop_depth` set to the frame count, so the `}` that finds that depth ends the
  run; its tokens keep their real positions. The main loop keeps a `resume`
  point: at the line break of the opener line it emits the `NL` and jumps over
  the bodies. No field on the token or the node says that a string is a
  heredoc: its lexeme is the opener (`<<~NAME`), which `Base.heredoc?` reads for
  the `case` pattern and the `import` path (`PARSE-UNEXPECTED-TOKEN`). Spans
  inside a body lie after the spans of the nodes that hold them.

## Syntax tree (`compiler/syntax/ast.agc`)

Every node is a struct with `span` as the last field and an `id` that is dense
across the files of a program. `Program` holds the declarations, `docs` (a map
from the span of each documented node to its doc text) and the module doc. The
key is the span of the node as it stands in its list: the `ExportDecl` for an
exported declaration (not the `def` inside), the `FieldDecl` in a struct, the
`EnumVariant` in an enum. The other nodes do not know about docs, so the
checker, lowering and bytecode see the tree as before.

The node lists are in `ast.agc`. Fields that are not obvious:

- `ImportDecl` has `path`, `alias` and `names` (a list of `ImportName`: name,
  local, span, local span); exactly one of alias and names is set.
- `ConstDecl.exported` is true for `export NAME = ...`, and the linker clears
  it. `ConstRef` is made by the linker for a read of a constant.
- `Param.default` is an optional expression.
- A function, struct, enum, constant, field, variant and type alias holds the
  `name_span` of its name, as do `FieldAccess` and `MethodCall`; `parse_text`
  and the linker text do not print it, so the goldens do not carry it.
- `StructUpdate` (the `value.with(f: x)` copy) has `visible`: the linked struct
  names the file may update, set by the linker.
- `FieldAccess` and `MethodCall` have `resolved`; `TypedTarget` (expression,
  type) is the receiver the checker makes. `TypeName` carries JSON type
  arguments only.

Design points: one `TypeRef` covers `Int`, `List[Int]`, and `List[List[Int]]`;
one `Literal` covers integers, floats, strings, booleans, and `nil`; grouping `(
expr )` produces no node; `Call`/`Construct` store the name as a string;
`Unary`/`Binary` store the operator as the token kind (`plus`, `and`, `equal`);
`Absent` is `Optional.Absent`.

## Parser (`compiler/syntax/parse_base.agc`, `compiler/syntax/parser.agc`)

`parse: List[Token] -> Result[Program]`. Recursive descent over the token list,
with the context (`Env`), a position and the next free node id passed and
returned:

- Precedence ladder: or → and → equality → comparison → pipe → additive →
  multiplicative → unary → postfix → primary.
- The pipe (`x |> f(a)`) is left-associative and builds a `Call` with `piped`
  set (the call's span is the right side, the inserted argument keeps the left
  span); `try` on the right wraps the piped call. The parser records each call
  it builds from `name(...)`, `Alias.name(...)` or `Result.Ok(...)` as
  parenthesized (a `do` block rebuild keeps the mark); the right side must be
  one of those and not already piped, else `PARSE-PIPE-TARGET` at the right
  side. Every place that rebuilds a `Call` (the linker, the `do` block) must
  pass `piped` along.
- Arithmetic levels are left-associative; equality and comparison take a single
  optional operator, so `a < b < c` and `a == b == c` are
  `PARSE-CHAINED-COMPARISON`, while `a < b == c < d` is valid.
- Nesting limit (`nesting_limit`, 1000): `enter` counts each statement,
  expression, prefix operator and type. A chain of binary operators or pipes and
  each suffix of a postfix expression counts as one more level, and what is
  parsed after the k-th link starts k levels deeper (`deepen`); beyond the limit
  is `PARSE-TOO-DEEP` at the current token. The limit bounds the calls of the
  parser, not the depth of the tree: the right operand of the first link of a
  chain hangs below the whole chain, so nested chains can build a tree far
  deeper than 1,000 (measured: 1,990 for two nested chains, about 89,000 for
  100). A pass that recurses on the tree needs its own stack or limit.
- Nesting limit of the checker (`compiler/check/check_state.agc`,
  `nesting_limit`, 1000): each expression and each statement counts as one
  level, so it bounds the depth of the tree; beyond the limit is
  `CHECK-TOO-DEEP` at the node, with help to split the code. Alias expansion
  also stops after 1,000 type references, so repeated aliases cannot grow
  exponentially in the checker. The parser limit does not bound the tree (a
  nested chain hangs below its first link), and the checker needs up to 5 VM
  frames per level (builtins with the nested call as first argument; 3 for `if`,
  calls and method chains; 6 for each nested block), about 5,000 of the 10,000
  at the limit.
- `type` is contextual: it starts an alias declaration only at the top level
  and remains an ordinary name elsewhere. `case`, `while` and `for` headers
  take an optional `do`. A case arm body is either a NL and a block, or one
  simple statement on the arrow line followed by more statements. A qualified
  function name without `(` is a `Call` with no arguments. `import` has two
  forms, `import Alias from "path"` and `import {a, B as C} from "path"`; a
  string right after `import` (the path-first form) is `PARSE-UNEXPECTED-TOKEN`
  at the string, with a help that shows the first form; `from` and `as` are
  plain `name` tokens read by their text, so they stay usable as names. Module
  nodes must pass through the linker before check.
- `.with(` (the name is exactly `with`, then `(`) makes a `StructUpdate`: named
  arguments only, at least one, a trailing comma and blocks allowed in the
  values; `value.with` without `(` stays a field access, and `with` is not a
  reserved word.
- A statement starting with `name` is a binding when the next token is `=` or
  `:`; otherwise it is an expression.
- Stray `NL` tokens are skipped at the top level and between statements (see
  "Lexer gotcha: stray NL tokens" in `references/frontend.md`).
- Doc blocks: the parser takes an optional `DOC` before a
  declaration, a field or a variant, and accepts the block only when its `next`
  is `code` and one `NL` is followed by the member's first token; the text is
  then stored under the member's span. At the top level, a block with `next`
  `blank`, before any declaration and when there is no module doc yet, becomes
  the module doc. Anything else is `PARSE-DETACHED-DOC` at the block's span.
  Every other place a `DOC` can reach (a function body, inside brackets, before
  `end`) fails through `bail`, which turns any diagnostic whose token is a `DOC`
  into `PARSE-DETACHED-DOC`, except `PARSE-MISSING-BLANK-LINE`. The blank-line
  check counts a `DOC` as the start of a declaration, so a block right after an
  `end` gives `PARSE-MISSING-BLANK-LINE` at its first line.

## Linker (`compiler/modules/`)

`link_file` links imports before `check`: `modules.agc` reads the files (with an
explicit stack), `resolve.agc` and `rewrite.agc` give every name its linked
name. The std-only guard lives in its name resolution: a two-part name whose
module is in the std-only set of the catalog (today `HttpWire` and
`LogRegistry`) and that no import alias names is `CHECK-UNKNOWN-NAME`, with a
help that shows the import of its std module (`import HTTP from "std/http"` for
`HttpWire`, `import Logger from "std/logger"` for `LogRegistry`), unless the
module was embedded from `stdlib/`. A user file, a relative import and a `pkg/`
module all get it. `HttpWire` is also left out of `help`, its JSON and every
"did you mean". The linked program carries the root file's `docs` and module
doc; nothing after the parser reads them. `link_programs` (the query commands)
links several roots into one program: `load_roots` shares one walk, every module
gets an `@N::` prefix, and a root whose load or rewrite fails is dropped as a
whole (`Linker.Left`), so the others still link.

Names imported with `import {a, B as C} from "path"` live in a per-file `named`
table (local name to the module key and the original name; `bind_names`),
filled once the module is loaded, because the checks need its exports. In
order, per entry:
`CHECK-IMPORT-NAME` at the original name (unknown or private),
`CHECK-IMPORT-RENAME` at the local name (a type name must start with a capital
letter, a function name must not), then `CHECK-REDEFINED-NAME` at the local name
against the file's declarations, aliases, other named imports, builtin functions
and the reserved type names. Resolution maps a name without a dot found in the
table to the linked name of the export (with the same kind check as
`Alias.name`), the rewrite turns `Color.Red` and `Color.Red(x)` with `Color` an
enum in the table into an enum value, and the `visible` list of `.with` also
takes the targets of the table.

## Checker (`compiler/check/checker.agc` and the `check_*.agc` files)

`check(linked, settings) -> Checking.Done(Checked) | Failed(Problem)`.
Registration first (`check_register.agc`), then bodies, stopping at the first
error:

- Enum names are registered before struct fields resolve; struct names precede
  field resolution; enum payload templates resolve after all struct names exist;
  function signatures follow. This allows forward references and generic enum
  payloads.
- Catalogued builtin function names cannot be redefined. `ok` and `error` are
  additionally reserved on locals, parameters, loop variables, and fields.
- Types are the `Type` enum of `compiler/syntax/types.agc`: the primitives,
  `List`, `Map`, `Set`, `Result` and `Task` of a type, structs and enums by
  linked name (an enum carries its type arguments), and type variables during
  payload registration.
- A piped builtin call that has a method form for its first parameter's type is
  `CHECK-PIPE-METHOD` at the call span (after the call checks, so type and arity
  errors come first). The kind comes from the builtin entry's first parameter;
  the help text is cut from the source, starting a piped call or piped `try` at
  its piped argument and wrapping it in parentheses.
- Builtin module calls keep their dotted name. The checker reads arity,
  signature and fixed types from the catalog (`builtins_data.agc`); generic
  rules are explicit rule functions (`check_rules.agc`, `check_list.agc`,
  `check_collections.agc`, `check_args.agc`). Lowering reads the same entry's
  implementation key and trusts checked arity.
- String operations count Unicode characters. Numeric conversions accept signed
  decimals: non-bang forms return Result; bang failures remain
  `RUNTIME-INVALID-NUMBER` / `RUNTIME-INTEGER-OVERFLOW`.
- Expected types must reach builtin calls for contextual ok/error and
  unwrap/default. An untyped error is CHECK-RESULT-TYPE, and a `Channel.new`
  with no expected type is CHECK-EXPECTED-TYPE. `try` requires a
  Result-returning function and a Result operand; its payload type may differ
  from the enclosing success type. It does not guarantee a return. `try` also
  works in a block whose expected `Fn` has a fixed `Result` type (`Test.test`,
  `File.each_line`). The last expression of such a block is checked as a
  completion value, so a Void or non-Result last expression is
  `CHECK-TYPE-MISMATCH`, not `CHECK-VOID-VALUE`. The help `give a Result with
  ok() or error("message")` (`ok(...)` when `T` is not Void) is given for every
  mismatch whose expected type is a `Result` and whose actual type is not one, a
  block's last expression or `x: Result[Int] = 5` alike. `try` also works in a
  block whose `Result[T]` has an inferred `T` (`Task.map`; `File.open` blocks
  reuse it): the call rule (`check_task_map` in `check_collections.agc`)
  gives the block the expected `Result[R]` from the expected `List[Result[R]]`,
  else `Result[Unknown]`, and `check_block_body` turns `Result[Unknown]` into
  the `Slot.InferResult` slot (`check_state.agc`): `result_context?` accepts it,
  the first `return` or the last expression must be a `Result` and fixes its
  type, and every later value must agree. A first value of `error(...)` has
  nothing to infer from, so it stays `CHECK-RESULT-TYPE` (annotate the
  variable).
- Scopes are a stack of maps holding `name -> (type, immutable?)`. The `for`
  variable is immutable.
- A plain binding to a visible name is an update and must keep its type; an
  annotated binding to a visible name is `CHECK-ANNOTATION-ON-EXISTING`; a fresh
  name that is already visible is `CHECK-SHADOWED-NAME`.
- The result (`Checked`) holds the type of each expression and block by node id
  (the literal 2^63 under unary minus is never recorded; lowering handles it by
  rule), what each method call or field access resolved to, and the linked names
  of the module constants in initialization order. Lowering trusts it and does
  not re-check types.

## Compiler prelude implementation

A prelude method is a builtin written in Agentica
(`docs/future/25-ruby-typed-idioms.md` 25.6): its catalog row has `Rule.Prelude`
and an empty implementation key, `prelude_data.agc` says which file and function
run it (`plain`, `limited` for a variable that only some types may take,
`chosen` for one function per type of the variable), and the body is a `def` in
`stdlib/prelude/<file>.agc` that names its type variables (`A`, `B`, `K`, `V`)
in annotations. To add one: the row in `builtins_data.agc` (sorted by name), the
entry in `prelude_data.agc`, the body, and the tests of 25.6 (a spec case per
rule, a VM golden, a step count in `tests/fixtures/vm/prelude-cost.agc`).

- `Rule.Prelude` (`check_prelude.agc`) checks the arguments left to right, binds
  the type variables (a block gets the types known so far), checks the limits
  (`CHECK-TYPE-MISMATCH` at the argument that bound the variable) and records
  the body by call id (`St.bodies`, `Checked.bodies`).
- After the program, `Prelude.attach` (`check/prelude_files.agc`) reads
  `std/prelude/<file>.agc` for the files the program used, parses it from the
  next free node id, keeps the functions called (named `@prelude::file::name`
  by `prelude_name` in `syntax/prelude_name.agc`) and checks
  them with `Cx.prelude` set (a type variable may be a Map key or Set element;
  `__fail_arg` is known). A program that calls no prelude method reads no
  prelude file. `std/prelude/...` is not importable.
- Lowering turns the call into a plain `call` (never a `tail-call`) with the
  span of each argument after the span of the call, adds the files as sources
  named `<prelude>/file.agc` with no text, and pins every span of their
  functions to 1:1. The VM reads the name, flags the functions (format 6) and
  reports an error inside a run of prelude frames at the call of the program
  (`docs/vm/03-ir-and-bytecode.md`).
- A body calls builtins only (no other prelude function), never `concat`,
  `take`, `drop`, `reverse`, `sort`, `Map.keys`, `Map.values` or `Map.delete`
  inside a loop or a callback (`tests/test_stdlib_prelude.py`), and uses
  `__fail_arg(code, index, message)` to fail at argument `index` of the call.
  `__fail_arg` is unknown to a program (`CHECK-UNKNOWN-NAME`) and hidden from
  `agentica help`.
- The compiler itself must not call a prelude method until
  `bootstrap/stage0.agcb` is refreshed.

## Lowering (`compiler/lower/lowering.agc` and the `lower_*.agc` files)

`lower(linked, checked, catalog) -> Lowered.Done(Ir.Program) | Failed(Problem)`.
One IR function per function declaration in declaration order, then (with module
constants) one per kept constant in initialization order, then `<start>` when
the program has globals, then the block functions; `entry` is `main`, or
`<start>` when it exists (`references/vm-lowering.md`). A read of a constant is
`global`, or a `const` for a scalar literal. Slots: parameters first, then
locals, which are resolved statically and freed when their scope ends, then
temporaries with a stack discipline so a call window is always the highest live
slots. A new local is lowered straight into its slot; an assignment to an
existing local goes through a temporary and `move`. Unsupported forms or types
are `LOWER-UNSUPPORTED` at the node span; a failed internal assumption is
`LOWER-INTERNAL` at the program span. A `MethodCall` or `FieldAccess` with
`resolved` set lowers its resolved node without a step and checks the outer
node's type, because the synthetic call that the checker builds is not in the
types table; a `TypedTarget` lowers its expression and checks its recorded type.
`lower_text.agc` prints the IR (`--dump-ir`).
Builtin records the VM knows (`FileInfo`, `Header`, `HttpResponse`,
`HttpClientOptions`, `ProcessOutput`, fields in record order) are appended to
the program's structs when a checked type mentions them, with the records they
need (`HttpResponse` needs `Header`); the C side finds them by name
(`agc_builtin_struct`).

A change to the lowering (a bug fix, a builtin name in `VM_BUILTINS`) changes
`compiler/lower/lower_tables.agc` or the `lower_*.agc` file and a golden in
`tests/fixtures/frontend/lower/` in the same PR.

## Bytecode writer implementation

`write(root_dir, program, version) -> Written.Done(bytes) | Failed(Problem)`
resolves labels, merges adjacent `step`s (split above 65535), and builds the
constant pool, builtin imports (name and arity) and the span table (span 0 is
the program span; multi-span instructions use consecutive entries). It gives the
`.agcb` bytes of `docs/vm/03-ir-and-bytecode.md` 4.6; the C loader is the only
reader. `tests/test_frontend_bytecode.py` compares the writer with the frozen
bytes of the original writer, and its `OPCODES` with `agc_opcode` in
`vm/value.h`. The version of the header is the `VERSION` file, an input of the
writer (`Settings` in `compiler/modules/link_env.agc`), never a constant. The
format version is `FORMAT_VERSION` in `bytecode_tables.agc`; the sections are
in `docs/vm/03-ir-and-bytecode.md`. `BYTECODE-LIMIT` (at most 65535 each) for
structs, enum variants, fields in one struct, payload items in one variant,
module constants, JSON field types, struct updates and registers in one
function, and for more than 1024 nested List and Map levels in a JSON field
type; an impossible IR is `BYTECODE-INTERNAL` at the program span.

## Builtin catalog implementation

One catalog of name, parameters, result, generic rule tag, implementation key,
effects, and description, as data edited by hand (`builtins_data.agc`) with the
lookups in `builtins.agc`. The std-only modules (`HttpWire`, `LogRegistry`) are
only callable from `stdlib/` (they are left out of help and suggestions). The
catalog serves the checker, lowering and help; the shared type printer and
`did_you_mean` (`suggest.agc`) keep help and checking consistent. Effects are
informational only, except that a builtin with no effects whose result is unused
is `CHECK-UNUSED-VALUE`: the `Test` assertions carry the effect `test` so they
may stand as statements. `Test.eq` uses the rule `TestEq`: both arguments have
one type that is a data type (the types with `to_s`, which are the §25.4
equality set plus `Json`); `TestCase` is an opaque type and `Test` is a reserved
name. Every entry's implementation key must be in `VM_BUILTINS` of
`compiler/lower/lower_tables.agc` (`tests/test_frontend_catalog.py` checks the
catalog) and run in a golden fixture; do not add test-only exports.

A builtin can have several signatures (alternatives by arity): the checker and
lowering use the same selection. Only catalog initialization fills the
alternatives field; `builtin-ref` optionally selects by arity. Map.get/2
returns Result[V]; Map.get/3 returns V with an eagerly evaluated default. Text
help lists both signatures, and its JSON help carries an `overloads` array;
single-signature JSON output is unchanged. There is no user-function
overloading.

## Command line (`compiler/app/cli.agc` and `cli_*.agc`)

`run(settings, words, hand_off) -> exit status`; the program is `dist/agentica`.
`test` runs the BDD driver `compiler/bdd/bdd_driver.agc` (`references/bdd.md`).
It reads the file (a missing file prints one plain line and exits 2), then
links, checks and lowers it, and hands the bytecode to the VM. A diagnostic is
printed in the plain form (header, message, source line, caret run) on stderr
with exit 1. `--dump` pretty-prints the checked tree instead of running it;
`--dump-ir` prints the lowered program. `compile FILE -o OUT` (first argument
only, exactly that shape, else usage exit 2) checks, lowers and writes
bytecode, and it cannot be combined with `--dump` or `--dump-ir` (usage, exit
2); lowering diagnostics exit 1, an unwritable output prints one line and exits
2. Arguments after the source file reach the VM as `System.args`, and the
command exits with the VM's code. No source file exits 2. `check` never runs;
--ai/--json use the same structured diagnostic. `help NAME --json` reads the
catalog without a source file (unknown target exits 2; with no NAME it prints
all entries as a JSON array sorted by name); `help` alone (exit 0) prints the
command summary and the builtin namespaces. `--help` and `help` share one text.
Help and test handle trailing style options; options on other commands precede
the command/file so program args stay intact. --max-steps accepts a positive
integer and reaches only the VM. The --deny-* flags and --sandbox go to the
VM as typed (`Options.deny`); `test` passes them to the driver.
`tests/fixtures/cli/forms.json` freezes the forms (`tests/test_cli_forms.py`).
`install` and `vendor` are `cli_install.agc` and `cli_vendor.agc` (they take
no word); `add` and `update` are
`cli_add.agc` (their words are read by hand there). `doc` and the query commands (`outline`, `type-at`, `refs`) are `cli_doc.agc`
and `cli_query.agc`: the words after the command are read by hand
(`query/query_options.agc`), and `--stdin FILE` (`type-at --stdin
FILE:LINE:COL`, likewise `refs`) goes through `with_buffer` in `cli.agc`, as
`check --stdin` does. `reject` takes the exit status: a `QUERY-` problem exits
2, any other 1.
