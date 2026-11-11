# Pipeline stages reference

Contracts of the Agentica front end in `compiler/`. Read this when adding or
renaming a token, AST node, or diagnostic code. The goldens in
`tests/fixtures/frontend/<stage>/` pin each stage's text form
(`references/frontend.md`).

## Conventions

- A span end is exclusive; offsets count code points; lines and columns are
  1-based.
- A failed internal assumption is a `*-INTERNAL` diagnostic, never a crash
  (stage contract: `AGENTS.md`).
- The diagnostic forms (`compiler/diagnostics/diagnostic_{plain,ai,json}.agc`)
  render from the same data; `vm/diag.c` prints the same forms for runtime
  errors.

## Source and tokens

`Token` (`compiler/syntax/token.agc`) has the kind (a String), lexeme, `Value`
and span. A `DOC` token's lexeme is the raw block, and its span runs from the
first `##` to the end of the last line. Its `Value` is a `DocBlock`: `text` is
the doc lines without the `##` markers and one optional space; `next` (`blank`,
`comment`, `eof` or `code`) says what follows. The lexer works `next` out
itself, because the `NL` tokens of a blank line and of a `#` comment line look
the same.

Token kinds are Strings, listed in `OPERATOR_KINDS` and `WORD_ACTIONS` of
`compiler/syntax/lexer.agc`; a reserved word is its own kind. Two easy to get
wrong:

- `&&`, `||` and `!` are the kinds `and`, `or` and `not`; a `!` glued to a name
  stays in the name.
- The parser desugars `x op= e` into `binding x #f (binary op ...)`, and reads
  `true`, `false` and `nil` from their kind, not from `value`.

## Diagnostics

`Diagnostic` (`compiler/diagnostics/diagnostic.agc`) has a code, message, span
and optional expected, actual, callee, signature, labels and help. List the
codes in use with:

```sh
rg -oNI --no-filename '\b(LEX|PARSE|CHECK|PKG|QUERY|RUNTIME|LOWER|BYTECODE)-[A-Z0-9]+(-[A-Z0-9]+)*' compiler stdlib vm/*.c | sort -u
```

- `LEX-INVALID-UTF8` is made by `compiler/syntax/source_file.agc` when a file is
  read, not by the lexer; its span is the first byte that does not decode.
- `RUNTIME-` codes come from the VM; `RUNTIME-NATIVE-DENIED` and
  `RUNTIME-NATIVE-UNSUPPORTED` are raised at load (exit 2).
- **Packages** (`packages/`): manifest, lock, stale and conflict errors carry a
  key path (`Failure.fail_key`); a missing or unreadable file has none
  (`Failure.fail_file`). The locked packages' manifests are checked before any
  file loads (`check_manifests`). A build reads a package only from
  `deps/<name>/` (missing: `CHECK-IMPORT-PACKAGE`) and hashes it, except a
  workspace member (`packages/members.agc`, found from the root's `[workspace]`
  table): it is read from its folder with no hash and locked with
  `workspace = true`. Hash and link errors are at the import.
- **Query** (`query/`): `QUERY-USAGE`, `QUERY-NOT-FOUND` and
  `QUERY-AMBIGUOUS-NAME` exit 2 at `<arguments>` (line 1, column 1);
  `QUERY-NO-EXPRESSION` is at the position. `outline` lexes and parses, and
  links only a file with re-exports. `type-at` and `refs` link and check, so any
  `LEX-`, `PARSE-`, `PKG-` or `CHECK-` code can come (exit 1); `symbol` exits 1
  only when no file links.

Network and protocol failures otherwise return Results; handler and producer
diagnostics keep their original code and span.

## Lexer (`compiler/syntax/lexer.agc`)

`lex: String -> Outcome[List[Token]]`. One pass over the source:

- CRLF normalizes to one newline; a lone carriage return is
  `LEX-UNEXPECTED-CHAR`. `NL` is suppressed inside `()`, `[]` and `{}`; a final
  `NL` is synthesized before `EOF`.
- A line whose first non-blank characters are `##` starts a doc block: the lexer
  looks back over blanks to the line break and reads the consecutive doc lines
  into one `DOC` token (`###` keeps its third `#`). A `##` after code is a plain
  comment. A bare carriage return after a doc line is still
  `LEX-UNEXPECTED-CHAR`. A `DOC` inside brackets is emitted; the parser rejects
  it there.
- A lowercase name may end in `?` or `!`; `!` followed by `=` stays an operator,
  so `a!=b` is `a != b`. The parser rejects suffixes on bindings, parameters and
  fields.
- Number literals drop the `_`s from the value; `LEX-INVALID-NUMBER` spans the
  literal as written. A `.` followed by a digit or `_` continues a number, so
  `1_000.times` and `1_000..2_000` are not Floats. The text conversions
  (`String.to_int`, JSON) reject `_`.
- Heredoc `<<~NAME` yields the string tokens at the opener's place, all with the
  span of `<<~NAME`; `#{...}` pieces in a body are lexed by the main loop
  (`lex_from`, `stop_depth`) and keep their real positions, so spans inside a
  body lie after the spans of the nodes that hold them. No token or node field
  marks a heredoc: `Base.heredoc?` reads the opener text for the `case` pattern
  and the `import` path.
- A `/` starts a `regex` token (`scan_regex`) unless the token before it is in
  `ENDS_EXPRESSION`, or the `/` is part of `//`, `/*` or `*/`. The parser builds
  `RegexLit` with its `call` (`<compile>((?flags)body).unwrap!`, name "" until
  the linker, `rewrite_regex`, fills in std/regex's `compile` for a file that
  imports it); the checker (`check/check_regex.agc`) runs std/regex on the
  pattern, `check_const` orders std/regex's constants first, and lowering makes
  each literal a constant `regex#<id>` (`hoisted_regexes`).

## Syntax tree (`compiler/syntax/ast.agc`)

Every node is a struct with `span` last and an `id` that is dense across the
files of a program. Read the definitions for the fields. Rules the types do not
show:

- `Program.docs` maps the span of each documented node to its doc text. The key
  is the span of the node as it stands in its list: the `ExportDecl` for an
  exported declaration (not the `def` inside), the `FieldDecl`, the
  `EnumVariant`. Other nodes know nothing of docs, so later stages see the tree
  as before.
- Exactly one of `ImportDecl.alias` and `names` is set.
- The linker makes `ConstRef` for a read of a constant, fills
  `StructUpdate.visible` and `EnumConstructor.named`, and clears
  `ConstDecl.exported`.
- `name_span` (on declarations, `FieldAccess` and `MethodCall`) is not printed
  by `parse_text` or the linker text, so the goldens do not carry it.
- `FieldAccess` and `MethodCall` have `resolved`; `TypedTarget` is the receiver
  the checker makes. `TypeName` carries JSON type arguments only.

## Parser (`compiler/syntax/parse_base.agc`, `compiler/syntax/parser.agc`)

`parse: List[Token] -> Result[Program]`: recursive descent, with the context
(`Env`), a position and the next free node id threaded through.

- The pipe (`x |> f(a)`) is left-associative and builds a `Call` with `piped`
  set; the call's span is the right side. The right side must be a parenthesized
  `name(...)`, `Alias.name(...)` or `Result.Ok(...)` call that is not already
  piped, else `PARSE-PIPE-TARGET`. Every pass that rebuilds a `Call` (the
  linker, the `do` block) must pass `piped` along.
- Nesting: `enter` counts each statement, expression, prefix operator and type;
  each link of a binary chain, pipe or postfix suffix adds one (`deepen`). Past
  `nesting_limit` (1000) it is `PARSE-TOO-DEEP`. This bounds the parser's calls,
  not the tree depth (a chain's first operand hangs below the whole chain), so a
  pass that recurses on the tree needs its own stack or limit.
- The checker's limit (`check_state.agc`, 1000) counts each expression and
  statement, so it bounds the tree depth: `CHECK-TOO-DEEP`. Alias expansion
  stops after 1,000 type references. The checker needs up to 5 VM frames per
  level, about 5,000 of the VM's 10,000 at the limit.
- A case arm body is a NL and a block, or one simple statement on the arrow line
  followed by more statements. A qualified function name without `(` is a
  `Call` with no arguments.
- `from` and `as` stay usable as names. Module nodes must pass through the
  linker before `check`.
- `.with(` (exactly `with`, then `(`) makes a `StructUpdate` with named
  arguments only, at least one; `value.with` without `(` is a field access.
- A statement that starts with `name` is a binding when the next token is `=` or
  `:`, else an expression. For stray `NL` tokens see "Lexer gotcha: stray NL
  tokens" in `references/frontend.md`.
- Doc blocks: a `DOC` attaches to the next declaration, field or variant only
  when its `next` is `code` and one `NL` precedes the member's first token; the
  text goes under the member's span. A top-level `blank`-followed block before
  any declaration, with no module doc yet, is the module doc. Anything else is
  `PARSE-DETACHED-DOC`, and so is a `DOC` that `bail` meets in a function body,
  inside brackets or before `end`, except `PARSE-MISSING-BLANK-LINE` (a block
  right after an `end`, since the check counts a `DOC` as a declaration start).

## Linker (`compiler/modules/`)

`link_file` links imports before `check`: `modules.agc` reads the files (with an
explicit stack); `resolve.agc` and `rewrite.agc` give every name its linked
name.

- The std-only guard: a two-part name whose module is in the catalog's std-only
  set (`HttpWire`, `LogRegistry`, `RegexEngine`) and that no import alias names
  is `CHECK-UNKNOWN-NAME`, unless the module was embedded from `stdlib/`.
  `HttpWire` is also left out of `help`, its JSON and every "did you mean".
- The linked program carries the root's `docs` and module doc; nothing after the
  parser reads them.
- `link_programs` (the query commands) links several roots into one program; a
  root whose load or rewrite fails is dropped whole (`Linker.Left`), so the
  others still link.
- `import {a, B as C}` names live in a per-file `named` table (`bind_names`),
  filled once the module is loaded, since the checks need its exports. Per
  entry, in order: `CHECK-IMPORT-NAME` at the original name;
  `CHECK-IMPORT-RENAME` at the local name; `CHECK-REDEFINED-NAME` at the local
  name. A dotless name found in the table resolves to the export, with the same
  kind check as `Alias.name`. The rewrite turns `Color.Red` and `Color.Red(x)`
  into an enum value when `Color` is an enum in the table. The `visible` list of
  `.with` also takes its targets.
- `export Alias.name` is `Ast.Decl.Reexport`, bound by `bind_reexports` after
  the file's imports. `Module.reexports` keeps the original module key and name
  (a chain is already followed). Every linked name taken from an export comes
  from `Modules.linked_name`, never `prefix + name`. Nothing reaches the checker
  or lowering.
- `import_use.agc` runs after the rewrite of each file: `CHECK-UNUSED-IMPORT`
  (a regex literal or `<<~EAG` template uses the import of `std/regex` or
  `std/eag`) and `CHECK-IMPORT-NAME` for an alias written without a member.
  `Settings.unused_imports` is off for the query commands, for the root file
  only, so an imported file stays strict and still enters the check cache. It
  reads the parser's tree, so a file read from a check cache stub
  (`Module.stubbed`) is skipped.

## Checker (`compiler/check/checker.agc` and the `check_*.agc` files)

`check(linked, settings) -> Checking.Done(Checked) | Failed(Problem)`:
registration first (`check_register.agc`), then bodies.

- Enum names register before struct fields resolve; enum payload templates after
  all struct names; function signatures last. This allows forward references and
  generic enum payloads.
- Catalogued builtin function names cannot be redefined. `ok` and `error` are
  also reserved for locals, parameters, loop variables and fields.
- A piped builtin call whose first parameter's type has a method form is
  `CHECK-PIPE-METHOD` at the call span, after the call's own checks. The help
  text is cut from the source.
- Builtin module calls keep their dotted name. Arity, signature and fixed types
  come from the catalog (`builtins_data.agc`); generic rules are explicit
  functions (`check_rules.agc`, `check_list.agc`, `check_collections.agc`,
  `check_args.agc`). Lowering reads the same entry's implementation key and
  trusts checked arity.
- Expected types must reach builtin calls for contextual ok/error and
  unwrap/default. An untyped error is `CHECK-RESULT-TYPE`; `Channel.new` or
  `ATS.new` with no expected type is `CHECK-EXPECTED-TYPE`.
- `CHECK-UNUSED-VARIABLE` (`check_variables.agc`): `State.introduce_local`
  watches a variable, `for` variable, block parameter or pattern name (a
  function parameter is never watched); `Variables.check` runs at the end of
  `check_function_body` and of each constant and skips a file of `Cx.lenient`:
  the roots of a query (`Settings.unused` false, the flag of the unused import).
- `CHECK-UNREACHABLE-CODE`: `check_block` fails at the statement after one that
  `Flow.ends?` (`check_flow.agc`), after each statement, so errors before the
  terminator come first and the dead statement is not checked. Query commands
  keep it strict.
- `try` also works in a block whose expected `Fn` has a fixed `Result` type
  (`Test.test`, `File.each_line`). There the last expression is a completion
  value, so a Void or non-Result one is `CHECK-TYPE-MISMATCH`, not
  `CHECK-VOID-VALUE`. Every such mismatch gets the help `give a Result with ok()
  or error("message")` (`ok(...)` when `T` is not Void).
- A block with an inferred `Result[T]` (`Task.map`, `File.open` blocks) gets its
  expected type from the call rule (`check_task_map` in
  `check_collections.agc`), else `Result[Unknown]`, which becomes the
  `Slot.InferResult` slot (`check_state.agc`). The first `return` or the last
  expression must be a `Result` and fixes the type; later values must agree. An
  `error(...)` alone infers nothing, so `check_block_in` first checks a block
  that gives one (`Flow.gives_error?`) with `St.probe`, learns the type from its
  `ok(...)`, then checks it again as annotated. With no `ok(...)` at all it
  stays `CHECK-RESULT-TYPE` (annotate the variable). This holds for every block
  of unknown result (`map`, `Native.memory_pointer`).
- A plain binding to a visible name is an update and keeps its type; an
  annotated one is `CHECK-ANNOTATION-ON-EXISTING`.
- `Checked` holds the type of each expression and block by node id (the literal
  2^63 under unary minus is never recorded; lowering handles it by rule), what
  each method call or field access resolved to, and the linked names of module
  constants in initialization order. Lowering trusts it and does not re-check
  types.

## Compiler prelude implementation

A prelude method is a builtin written in Agentica
(`stdlib/prelude/`). Its catalog row has `Rule.Prelude`
and an empty implementation key. `prelude_data.agc` says which file and function
run it: `plain`, `limited` (for a variable only some types may take) or `chosen`
(one function per type of the variable). The body is a `def` in
`stdlib/prelude/<file>.agc` that names its type variables (`A`, `B`, `K`, `V`)
in annotations. Adding one takes the row (sorted by name in
`builtins_data.agc`), the `prelude_data.agc` entry, the body, and the tests
(`docs/vm/03-ir-and-bytecode.md` §4.7): a spec case per rule, a VM golden, and
a step count in `tests/fixtures/vm/prelude-cost.agc`.

- `Rule.Prelude` (`check_prelude.agc`) checks the arguments left to right, binds
  the type variables (a block gets the types known so far), checks the limits
  (`CHECK-TYPE-MISMATCH` at the argument that bound the variable), and records
  the body by call id (`St.bodies`, `Checked.bodies`).
- After the program, `Prelude.attach` (`check/prelude_files.agc`) parses
  `std/prelude/<file>.agc` for the files the program used, from the next free
  node id. It keeps the called functions (named `@prelude::file::name`) and
  checks them with `Cx.prelude` set (type variables may be Map keys or Set
  elements; `__fail_arg` is known). A program that calls no prelude method reads
  no prelude file. `std/prelude/...` is not importable.
- Lowering makes a plain `call` (never `tail-call`), gives each argument a span
  after the call's, adds the files as sources `<prelude>/file.agc` with no text,
  and pins their spans 1:1. The VM flags these functions (format 6) and reports
  an error inside a run of prelude frames at the program's call
  (`docs/vm/03-ir-and-bytecode.md`).
- A body calls builtins only, never another prelude function, and must not call
  `concat`, `take`, `drop`, `reverse`, `sort`, `Map.keys`, `Map.values` or
  `Map.delete` inside a loop or a callback (`tests/test_stdlib_prelude.py`).
  `__fail_arg(code, index, message)` fails at argument `index`. A program sees
  it as `CHECK-UNKNOWN-NAME`, and `agentica help` hides it.
- The compiler itself must not call a prelude method until
  `bootstrap/stage0.agcb` is refreshed.

## Lowering (`compiler/lower/lowering.agc` and the `lower_*.agc` files)

`lower(linked, checked, catalog) -> Lowered.Done(Ir.Program) | Failed(Problem)`.
One IR function per function declaration in declaration order, then one per kept
module constant in initialization order, then `<start>` when the program has
globals, then the block functions. `entry` is `main`, or `<start>` when it
exists (`references/vm-lowering.md`). Slots are parameters first, then locals
(resolved statically, freed at scope end), then temporaries in stack order, so a
call window is always the highest live slots. A new local is lowered straight
into its slot; an assignment to an existing local goes through a temporary and
`move`.

- Unsupported forms or types are `LOWER-UNSUPPORTED` at the node span; a failed
  internal assumption is `LOWER-INTERNAL` at the program span.
- A `MethodCall` or `FieldAccess` with `resolved` set lowers its resolved node
  and checks the outer node's type, since the checker's synthetic call is not in
  the types table. A `TypedTarget` lowers its expression and checks its recorded
  type.
- Builtin records the VM finds by name (`agc_builtin_struct`, e.g. `FileInfo`,
  `HttpWire.Response`) are appended to the program's structs when a checked
  type mentions them, with the records they need (`HttpWire.Response` needs
  `HttpWire.Header`).

## Bytecode writer implementation

`write(root_dir, program, version) -> Written.Done(bytes) | Failed(Problem)`
resolves labels, merges adjacent `step`s (split above 65535), and builds the
constant pool, builtin imports (name and arity) and the span table (span 0 is
the program span; multi-span instructions take consecutive entries). The format
is `docs/vm/03-ir-and-bytecode.md` 4.6; the C loader is its only reader.

- `tests/test_frontend_bytecode.py` compares `OPCODES` with `agc_opcode` in
  `vm/value.h`.
- The header version is the `VERSION` file, an input of the writer (`Settings`
  in `compiler/modules/link_env.agc`), never a constant. The format version is
  `FORMAT_VERSION` in `bytecode_tables.agc`.
- `BYTECODE-LIMIT` (at most 65535 each) covers structs, enum variants, fields in
  one struct, payload items, module constants, JSON field types, struct updates
  and registers in one function, and more than 1024 nested List and Map levels
  in a JSON field type. An impossible IR is `BYTECODE-INTERNAL` at the program
  span.

## Builtin catalog implementation

One hand-edited catalog (`builtins_data.agc`; lookups in `builtins.agc`). It
serves the checker, lowering and help; the shared type printer and
`did_you_mean` (`suggest.agc`) keep them consistent. Effects are informational,
except that a builtin with no effects whose result is unused is
`CHECK-UNUSED-VALUE`: the `Test` assertions carry the effect `test`, so they are
not that error (they still return a `Result`, so a dropped one is
`CHECK-UNUSED-RESULT`). `Test.eq` uses the rule `TestEq`: both arguments have
one data type (the types with `to_s`, the types with value equality plus
`Json`). `TestCase` is opaque and `Test` is reserved.

- Every implementation key must be in `VM_BUILTINS` of
  `compiler/lower/lower_tables.agc` (`tests/test_frontend_catalog.py` checks it)
  and run in a golden fixture. Do not add test-only exports.
- A builtin can have several signatures (alternatives by arity); the checker and
  lowering use the same selection, and only catalog initialization fills the
  alternatives field. `Map.get/2` returns `Optional[V]`; `Map.get/3` returns `V`
  with an eagerly evaluated default. Text help lists both signatures, and JSON
  help carries an `overloads` array. There is no user-function overloading.
- A Plain or Prelude builtin may instead give its trailing parameters a default
  (`Model.Named.default`, `references/frontend.md`, "Builtin defaults");
  lowering fills the rest at the call site.

## Command line (`compiler/app/cli.agc` and `cli_*.agc`)

`run(settings, words, hand_off) -> exit status`. `agentica help` and
`tests/fixtures/cli/forms.json` (`tests/test_cli_forms.py`) freeze the forms;
read them, not a list. `hand_off` calls `FrontEnd.hand_off`, so an ordinary run
stays in the binary's process.

- A diagnostic prints in the plain form on stderr with exit 1; a missing file or
  bad usage exits 2. A `QUERY-` problem exits 2 (`reject` takes the status).
- Options of other commands precede the command or file, so program args stay
  intact. `--max-steps` reaches only the VM. The `--deny-*` flags and
  `--sandbox` go to the VM as typed (`Options.deny`); `test` passes them to the
  driver (`references/bdd.md`).
- `doc` and the query commands read their words by hand
  (`query/query_options.agc`). `--stdin FILE` goes through `with_buffer` in
  `cli.agc`.
