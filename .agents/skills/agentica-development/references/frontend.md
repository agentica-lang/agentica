# Front-end recipes and gotchas

Read before editing `compiler/`. The front end is Agentica code in `compiler/`,
the only one (the Racket front end is gone; tag `bootstrap-racket` keeps it).
Every language change is made there with a golden: syntax, checker rule,
builtin row, builtin record or enum entry, registry line, std-only or reserved
name, message text.

## The front end in Agentica

### Stages and files

Each stage takes the previous stage's data and returns its typed outcome
(data or one diagnostic). For example, `Lexer.lex` returns `Diag.Outcome`; other
stages may use `Result` with a packed `Problem`. `try` stops at the first error.

`compiler/` has one folder per context: `app/`, `io/`, `syntax/`, `modules/`,
`packages/`, `check/`, `catalog/`, `lower/`, `bytecode/`, `diagnostics/`,
`docs/`, `query/`, `bdd/` and `embedded/`, with `front_end.agc` at the root. A new file
goes in the folder of its context. Names below are bare; the folder is in each
label (`references/repo-map.md` has every file). An import inside a folder is
the bare name (`"lexer"`); across folders it is relative (`"../syntax/types"`).

- Data: `syntax/source.agc`, `syntax/token.agc`, `syntax/types.agc` (the
  `Type` enum), `diagnostics/diagnostic.agc`, `diagnostics/problem.agc` (the
  packed `Problem` every stage returns). `syntax/suggest.agc` holds the
  did-you-mean help that the linker and the checker share.
  `syntax/source_file.agc` holds the strict UTF-8 rules for a source file
  (`LEX-INVALID-UTF8` at the first bad byte); `io/source_reader.agc` reads the
  file with them, with no size limit. `syntax/text.agc` holds the
  quoting and span printing.
- Lexer (`syntax/`): `lexer.agc`, `unicode.agc` and the hand-edited
  `unicode_table.agc` (graphic ranges, Unicode 17.0). Entries: `lex.agc`,
  `lex_text.agc`.
- Parser (`syntax/`): `ast.agc`, `parse_base.agc`, `parser.agc`; entries
  `parse.agc`, `parse_text.agc`.
- Linker (`modules/`): `workspace.agc` (the port),
  `modules.agc` (loader; walks imports with an explicit stack in a fixed
  order), `resolve_import.agc`, `import_path.agc` (`std/`, `pkg/`, relative),
  `resolve.agc`, `rewrite.agc` (linked name of every name), `linker.agc`
  (`Linker.link_file`, `Linker.program`), `declarations.agc`
  (`CHECK-DECL-ORDER`), `import_help.agc` (the help of an unknown import
  name), `link_env.agc` (`Env`
  and `Settings`: `stdlib/` and environment, passed in, never read inside; a
  new environment variable gets a `--name=V` flag in `link.agc`, `check.agc`,
  `lower.agc` and `bytecode.agc`, and a value in the hermetic environment of
  the tests), `link_failure.agc`.
- Packages (`packages/`, §45): the manifest, the lock, the git source rules, the
  cache and the package import, all pure. The rules are in
  `docs/grammar/05b-modules.md`; the file list is in `repo-map.md`. They read
  the disk only through the `Workspace` and the environment only through `Env`.
- Catalog (`catalog/`): `builtin_model.agc` (`Builtin`, `Record`, `EnumDef`,
  the `Rule` enum), `builtins.agc` (lookups), `builtins_data.agc`
  (hand-edited rows, records, enums, reserved names), `catalog.agc`,
  `catalog_text.agc`.
- Checker (`check/`): `check_register.agc`, `check_stmt.agc`, `check_expr.agc`,
  `check_call.agc`, `check_method.agc`, `check_rules.agc`, `check_list.agc`,
  `check_collections.agc`, `check_args.agc`, `check_help.agc`,
  `check_names.agc`, `check_flow.agc`, `check_unused.agc`, `check_state.agc`,
  `check_types.agc`, `check_tables.agc` (hand-edited method and help tables),
  `checker.agc` (`Checker.check(linked)`).
- Lowering (`lower/`): `ir.agc` (IR data), `lower_tables.agc` (`VM_BUILTINS`,
  operator tables), `lower_state.agc`, `lower_expr.agc`, `lower_data.agc`,
  `lower_stmt.agc`, `lower_scan.agc`, `lower_const.agc`, `lower_program.agc`,
  `lowering.agc` (`Lowering.lower(linked, checked, catalog)`).
- Writer (`bytecode/`): `bytecode_writer.agc` (`Writer.write`),
  `bytecode_function.agc`, `bytecode_types.agc`, `bytecode_spans.agc`,
  `bytecode_pool.agc`, `bytecode_bytes.agc`, `bytecode_tables.agc`
  (`FORMAT_VERSION`, limits, `OPCODES`), `bytecode_failure.agc`, runner
  `bytecode.agc`.
- Docs (`docs/`, §32.5): `agentica doc`. It lexes and parses one module and
  imports only `syntax/` and `diagnostics/`: `doc.agc` (`of_text`),
  `doc_model.agc` (the exported items; the doc of an export is on its
  `ExportDecl`), `signature.agc`, `doc_json.agc`, `doc_text.agc`. The command
  is `app/cli_doc.agc`; the tests are `tests/test_spec_doc.py`.
- Query (`query/`, §39): `agentica outline`. It parses one file and lists its
  declarations, private ones too, from the items of `docs/doc_model.agc`:
  `query_options.agc` (`--json`, `--ai`, `--stdin FILE` after the command,
  `QUERY-USAGE`), `query_files.agc` (the one file, read through the
  `Workspace`, and the name an answer gives it), `outline.agc`,
  `outline_json.agc`, `outline_text.agc`. The command is `app/cli_query.agc`;
  the tests are `tests/test_spec_outline.py`.

### Pure core, one port

Every folder of `compiler/` except `io/`, `app/`, `bdd/` and `embedded/`
(`syntax`, `modules`, `packages`, `check`, `catalog`, `lower`, `bytecode`,
`diagnostics`, `docs`, `query`)
is pure: it never calls `File`, `Dir`, `Path` (only `Path.join`, which is
string work), `System`, `Process`, `FrontEnd`, `IO`, `TCP`, `TLS`, `HttpWire`,
`Time`, `Random`, `Task`, `Channel`, `Profile`, `LogRegistry` or a bare `puts`,
and it never imports `io/`, `app/`, `bdd/`, `embedded/` or a `std/` module that
is not on `PURE_STD_MODULES` in the test (a new std module is forbidden by
default).
When a stage needs the machine it calls a function of
`Workspace` (`modules/workspace.agc`), a record of function values that
travels in `Env.Settings.workspace`: `read_text`, `file_exists`,
`directory_exists`, `real_path`, `resolve_path`, `std_source`, `list_folder`
and `read_bytes` (the last two serve the package hash). The
environment variables and the host (`windows`) are data in `Env.Env`.
`io/host.agc` builds the real `Workspace` and `process_env`; a test can build
a `Workspace` over an in-memory tree. `app/` (the command line), `bdd/` (the
`agentica test` driver, which runs processes) and `io/` are the only folders
that do I/O; `embedded/` holds the two programs of `agentica test` that the
binary carries. The entry programs (`syntax/lex.agc`, `syntax/parse.agc`,
`modules/link.agc`, `check/check.agc`, `lower/lower.agc`,
`bytecode/bytecode.agc`, `catalog/catalog.agc`) may call `System.args`, print
with `puts` and import the `io/` adapters (`bytecode.agc` writes its output
through `SaveFile`). `tests/test_style_core_purity.py` runs the real lexer
over the stage folders and fails on a call (`Module.name` as tokens, so
strings, comments and builtin data rows do not count) or an import; a new
entry program needs a line in its `ENTRY_PROGRAMS`. A new need of the machine
is a new `Workspace` field, built in `io/host.agc`. The linker (`modules/`,
`packages/`) imports no later stage. `catalog/` imports only `syntax/` and
itself, so every later stage reads it; the code that reads and checks the
prelude files is `check/prelude_files.agc`.

Order inside a `compiler/` file: imports and module doc, structs and enums,
exported functions, private functions. Code style follows the speed rules:
build lists with `push`, strings with `join`, and loops rather than recursion
over the input.

## Text forms and runners

Each stage has a text form that the goldens compare.

```sh
dist/agentica compiler/syntax/lex.agc file.agc        # lexer tokens: `== path`, then one line per token or ERROR
dist/agentica compiler/syntax/parse.agc file.agc      # parser tree, one node per line
dist/agentica compiler/modules/link.agc --stdlib=$PWD/stdlib dir/root.agc   # --ids: id ranges per module
dist/agentica compiler/check/check.agc --stdlib=$PWD/stdlib file.agc      # types and resolutions
dist/agentica compiler/lower/lower.agc --stdlib=$PWD/stdlib file.agc      # IR; --burn=N starts N calls deeper
dist/agentica compiler/bytecode/bytecode.agc --stdlib=$PWD/stdlib file.agc -o out.agcb  # several `FILE -o OUT` pairs allowed
```

Goldens: `tests/fixtures/frontend/<stage>/` (`NAME.input` and `NAME.tokens` for
the lexer; `NAME.input` and `NAME.ast` for the parser; `NAME.agc` or a folder
with `root.agc`, and `NAME.linked`, `NAME.checked`, `NAME.ir`). They hold
message and help text on purpose: a deliberate exception to "tests assert
codes, not messages". Modules fixtures are folders in `modules/`: `root.agc`,
optional `fixture.env` (`AGENTICA_PATH=`, `XDG_DATA_HOME=`, where `@/` is the
fixture folder) and `fixture.links` (`LINK TARGET`, made as symlinks in a copy).

Text-form notes:

- Lexer: `kind start-end "lexeme" value`; spans `offset:line:column`. Token
  kinds are Strings and must match the kind list in `references/stages.md`.
- Parser: `role: kind #id span attrs`, two spaces per level. Node ids are dense
  and post-order (a child has a smaller id than its parent; `program` is last).
  `Parser.parse(tokens, first_id)` numbers from `first_id`;
  `Ast.next_free_id(program)` gives the next file's first id.
- Linked program: `program #id span`, then `module "path"` per file. A struct
  update prints `visible=[...]`. Paths are the stored names
  (`Paths.stored_name`).
- Checked: each expression ends with ` type=DEBUG-TYPE`; builtin methods print
  `resolved=self(T)|text(T)|inspect(T)|call("List.map", T)`.
- Lowering: `program SPAN entry=N globals=N`, `fnN "name" ...`, `LN:` labels,
  `op ARGS @ SPAN` instructions. It is its own form, not `--dump-ir`.
- Failures print an `ERROR CODE SPAN "message" "help"|-` line with
  `file="path"`.

## Rules for the code

- Positions count characters; lines and columns are 1-based; span ends are
  exclusive.
- Node ids follow post-order; the writer and lowering rely on the order the
  function table, registers and first-named sources take. Keep them.
- Parser tables are module constants (`NESTING_LIMIT`, `LEVELS`,
  `COMPOUND_OPERATORS`, `LITERAL_KINDS`, `GRAPHIC_RANGES`). Do not rebuild them
  in zero-argument functions.
- Lexer: text is a `List[String]` of characters (`text.split("")`), followed by
  three `""` sentinels, so scans need no bounds test. Every stop set includes
  `""`; keep cached `top` and `depth` in sync with `delimiters`, and recompute
  `column_base` whenever `line_start` changes. Calls cost more than assignments
  on the VM: measure before restyling hot functions. Tail-recursive
  `state.with(...)` was measured 3-6% slower.
- Depth limits: parser `PARSE-TOO-DEEP` at 1,000 levels; checker
  `CHECK-TOO-DEEP` at 1,000; lowering uses at most 3 VM frames per level; the
  writer recurses only on JSON field types (1 frame per level, at most 1,024).
  The VM call limit is 10,000 frames. The linker's rewrite is about one VM call
  per level.
- The checker's `Cx` is immutable; state is a threaded `St`; scopes are one
  persistent `Map` that a scope snapshots and restores. `Checked.types` is a
  `List[Type]` indexed by node id (a `Map` took 50% longer). A builtin method
  call is checked as a call with the receiver as an `Ast.Expr.Typed` first
  argument, added by the checker, never by the parser.
- Module constants (`ConstDecl`, read node `ConstRef`, which only the linker
  makes): the parser reads a top-level `NAME = ...`; `NAME.x` parses as a module
  call; the linker turns a receiver `ConstRef` into a `FieldAccess` when the
  call has no parentheses and no arguments. `const_walk.agc` is shared by the
  checker and lowering. `check_const.agc` runs after `main`; the order is
  `Checked.constants`; `lower_const.agc` plans them.
- Default parameters: `Param.default`. The linker rewrites it with the declaring
  module's names. `check_defaults.agc` checks order and shape; `defaults.agc`
  gives the function `Shape` and which parameter an argument fills. The checker
  and `lower_argument` use the same functions, so they agree. Compiler code must
  not use defaults until `bootstrap/stage0.agcb` can compile them (the two-step
  refresh in `references/ci.md`).
- Import forms: `import Alias from "path"`, `import {a, B as C} from "path"`.
  `ImportDecl` has `alias` and `names`; the linker keeps a `named` table
  (`bind_names`, `CHECK-IMPORT-NAME`, `CHECK-IMPORT-RENAME`). The path-first
  form is `PARSE-UNEXPECTED-TOKEN`.
- Type aliases: `Ast.Decl.TypeAlias`, with the target `TypeRef` and the
  `type_parameters` of a generic one. The parser reads contextual `type` only
  at top level. `check_register.agc` registers the aliases before signatures;
  `check_types.agc` expands them (`CHECK-TYPE-ALIAS-CYCLE`): the arguments
  first, then the target with only the alias's own parameters in scope, then
  the arguments put in, as plain substitution (a name in the target is never an
  enum parameter of the use).

## Common tasks

Run the stage's tests after each change: `make test
TESTS="tests/test_frontend_<stage>.py"`, then refreeze the goldens the change
touches on purpose and read the diff.

### Add a keyword or operator

Edit the `compiler/syntax/lexer.agc` tables: keywords go in `WORD_ACTIONS` (1, 2
for block openers, 3 for `end`); operators go in `OPERATOR_KINDS` and
`SINGLE_LEXEMES` or `PAIR_LEXEMES`, with characters in `CLASSES` (and
`PAIR_SECONDS` for a new second character). If the parser acts on it, handle it
in `parser.agc` or `parse_base.agc`. Add a golden in
`tests/fixtures/frontend/lexer/`; add a spec case in `tests/test_spec_<area>.py`
if syntax changes.

### Add an AST node

Add a struct to `ast.agc` with `id` first and `span` last, plus a variant in
`Expr`, `Stmt` or `Decl`. Construct it in `parser.agc` with the span from the
first to last consumed token (`Base.span_from`) and the next free id. Update
every walker: `rewrite.agc`, `const_walk.agc`, the checker, lowering,
`parse_text.agc`. Parser golden: `tests/fixtures/frontend/parser/NAME.input`.

### Add syntax

Add tokens first if needed, then the node, then a parse function called from
the right place (statement, primary or program parser). Add a valid test and a
rejection test asserting the code in `tests/test_spec_<area>.py`.

### Add a diagnostic code

Pick a stage prefix (`LEX-`, `PARSE-`, `CHECK-`, `LOWER-`, `BYTECODE-`,
`RUNTIME-`). Raise it with the stage helper (`Base.bail`, `Failure.problem`)
and a span. Test code and location (`start`, `covers` from `--json check`), as
in `tests/test_spec_checker_rest.py`.

### Add a builtin rule

Add a `Rule` variant in `builtin_model.agc`, an arm in `check_rule`
(`check_rules.agc`), an arm in `rule_name` or `later_rule_name`
(`catalog_text.agc`; otherwise the text prints `?`), and a calling fixture (a
fast test requires one). Edit `frozen/check/builtin-rules.expected` by hand.

### Add an opcode

Add an entry in `OPCODES` in `bytecode_tables.agc` and `agc_opcode` in
`vm/value.h`, in the same order; lower it in `lower_*.agc`, `vm/loader.c` and
`vm/interp.c`. See "Refreeze" for stage order.

### Add a pipeline stage

Create `compiler/<context>/<stage>.agc` with one entry point returning next
data or one diagnostic. Require only the previous stage's modules; wire it in
`compiler/app/pipeline.agc`; add an entry program printing its text form (like
`check.agc`), `tests/test_frontend_<stage>.py` and a spec module. `make test`
discovers them; CI needs no change.

### Add tests

Use `tests/test_<area>.py` with `tests.agentica_test.TestCase`. A language rule
runs `cli() + ["--json", "check", path]`; assert the code and, when relevant,
`start` and covered text, never message text. Put many small cases in
`tests/fixtures/spec/checker-rest.json` (program lines, `code`, optional
`start`, `covers`, `help`, `expected`, `actual`, `function`, `callee`,
`labels`).
Cover happy path, error path and the introduced behavior.

### Speed change to a stage (differential run against master)

Keep every token, span, diagnostic and byte. Compare master's stage with the
branch's on the same binary:

  ```sh
  mkdir -p /tmp/master-src && git archive origin/master compiler | tar -x -C /tmp/master-src
  dist/agentica compiler/syntax/lex.agc $(git ls-files '*.agc') > /tmp/new.out
  dist/agentica /tmp/master-src/compiler/syntax/lex.agc $(git ls-files '*.agc') > /tmp/old.out
  cmp /tmp/old.out /tmp/new.out
  ```

  The repo's 1,055 `.agc` files take about 6 s per run. Add generated inputs
  (CRLF, bare CR, non-ASCII, bad escapes, unclosed brackets, interpolation) and
  every prefix of one construct-rich text, which covers each end-of-text
  position. Finish with `make fixed-point` and `make goldens`, which must leave
  `git status` clean. Record the result in `docs/vm-benchmarks.md`.

## Refreeze: `tools/refreeze.py`

`poetry run python tools/refreeze.py` reruns pytest modules
`tests.test_frontend_<stage>` with `AGENTICA_REFREEZE=1`: a golden mismatch
rewrites the golden and logs the change. Run it in the Poetry test environment,
which provides pytest. Flags: `--fast-only` (skip the slow tier), `--stage lower` or
`--stage lexer,parser`, `--jobs N`. It prints what changed: manifest entries
(key, sizes, hash prefixes) or a unified diff for a text golden. Other
assertions still fail. It freezes whatever the stage prints, so read `git diff`
and judge each change. A manifest keeps only hashes; to see an output, run the
stage by hand.

- Default stage order: lexer, parser, modules, check, lower, catalog, bytecode.
  With a new opcode, run refreeze twice, or run `bytecode` first
  (`--stage bytecode`) and then the rest; `lower` reads the frozen opcode table.
  Run with `--jobs 1` so stages execute in dependency order. The second run
  must print `nothing changed` for every stage.
- A stage whose tests are all skipped (a missing tool) freezes nothing: the
  tool exits 1.
- Two goldens have no Agentica source, so refreeze never changes them. Edit by
  hand in the same PR as the code or builtin that adds a line:
  `frozen/check/codes.expected` (the `CHECK-` codes) and
  `frozen/check/builtin-rules.expected`.

### Frozen comparisons (step 8c)

The slow tiers compare the Agentica stages with outputs frozen from the old
Racket stages (removed; the tag keeps them). `tests/test_frontend_<stage>.py`
for `lexer`, `parser`, `modules`, `check`, `lower`, `catalog`, `bytecode` run
the stage with the product CLI and compare with
`tests/fixtures/frontend/frozen/`.
Fast cases are the ones that were fast before (bytes of examples, id ranges,
invalid UTF-8, limit scenarios, id numbering); the rest are `@slow`.
`tests/frontend_support.py` is the helper; `tests/frontend_cases.py` holds
shared inputs built from formulas.

- `frozen/corpus/*.json`: a fixed snapshot of inputs (examples, stdlib,
  fixtures,
  `compiler/`, old checker programs, code blocks of the site). It does not
  follow those folders: a new `stdlib/` file is not in it.
- Seeded inputs are checked in (`lexer/generated.json`, `parser/generated.json`,
  `check/mutated.json`, `modules/mutated.json`). Formula inputs (nesting shapes,
  chains of 3,000 files, files over 1 MiB, programs of 300 and 1,000 functions)
  are rebuilt by Python; the manifest's SHA-256 of each input must match, or the
  test fails as a test bug.
- Manifests `frozen/<stage>/<set>.sha256`: per input, the output's SHA-256 and
  size, the input's SHA-256 and the key. Small outputs are text (`*.expected`).
  `.agcb` files hash without the length and the version text, so a release
  does not change the freeze.
- Other frozen lists: `frozen/lexer/graphic-ranges.expected`,
  `frozen/modules/stdlib-registry.expected` (a new `stdlib/` file is one line),
  `frozen/check/tables.expected` (copy of `check_tables.agc`),
  `frozen/check/codes.expected`, `frozen/check/builtin-rules.expected`,
  `frozen/lower/vm-builtins.expected`, `frozen/catalog/rules.expected`,
  `frozen/bytecode/opcodes.expected`.
- Phase 2 (goldens next to fixtures) runs in the same modules: every input has
  a golden and no golden is left over.
- Accepted losses: `builtins_data.agc` is not compared with a fresh generation
  (hand-edited now, 106 KB). Section and opcode coverage read the lowering
  goldens, which cannot tell the `types` and `decodable` sections apart.
- Fixtures read live by Python are frozen with derived results:
  `modules/<name>/` (hashes in `modules/ids.sha256`) and
  `limits/limits.agc` (imports
  live `compiler/`; output `bytecode/limits.expected`),
  `parser/synthetic.input` and `hello.input`, and `bytecode/*.agc`
  (`bytecode/fast.sha256`). Editing one, or a `compiler/` file imported by
  `limits.agc`, changes a frozen hash: refreeze and inspect the diff.

## Agentica gotchas

- `CHECK-DECL-ORDER` fixes declaration order per file: imports, constants,
  structs and enums, `export def`, `def`.
- A `##` doc block sits directly above its declaration. A `#` comment goes in
  the body or above the block, never between the block and the `def`
  (`PARSE-DETACHED-DOC`).
- `==` follows IEEE 754 on Floats (`nan != nan`, `0.0 == -0.0`). Compare types
  with `Types.same`; an enum cannot be compared with `==`.
- `s = s + piece` in a loop is quadratic. Use `push` and `join`.
- The VM call depth is 10,000 frames. Recurse on the tree only with a bounded
  depth, or use an explicit stack and loops.
- A value that cannot happen is a `*-INTERNAL` diagnostic, not a crash.

## Lexer gotcha: stray NL tokens

The lexer emits one `NL` per LF or CRLF outside `()`, `[]`, `{}`, including
blank and comment lines. Several `NL` can appear between statements. The parser
skips stray `NL` at top level and between statements; keep that skip when adding
statement forms.

A line that starts with `.name` drops the NL before it (`dot_follows?`, in the
`CharClass.Newline` arm of `lex_from`), when the last token is in
`ENDS_EXPRESSION` and is not a type name after `->` or `:` (`ends_in_type?`).
The look-ahead skips `#` comment lines; a blank line or a `##` line stops it.
A block head (`if`, `elsif`, `while`, `case`, `for` as the first token of the
statement, tracked by `head_at`) never joins. Any other leading dot stays and
the parser rejects it (`PARSE-UNEXPECTED-TOKEN` at the dot, except after an
operator, where it is at the line break). Do not use the form in `compiler/`
until `bootstrap/stage0.agcb` lexes it.

Top-level declarations need a blank line after `end`
(`PARSE-MISSING-BLANK-LINE`).
A `##` block is one `DOC` followed by the NL of its last line, not a blank line;
a blank line and a `#` line both give one `NL`. Stray text after `end` is
`PARSE-TOP-LEVEL-STATEMENT`. Inline test programs end top-level `end` with
`end\n\n`.

## Error handling

- A failing test: read the subtest name (a spec case prints its program) and
  the code the CLI gave.
- Smoke test exits 1: the CLI printed `file:line:column error[CODE]` with a
  caret excerpt on stderr. That is a stage diagnostic, not a crash.
- `*-INTERNAL` or a `RUNTIME-` error with a trace in `compiler/` means a stage
  assumed something false or indexed out of range. Find the token or index and
  turn it into a diagnostic; the roadmap requires Agentica diagnostics, never
  host tracebacks.
- A stage returns a diagnostic it should not: check the first-error rule and
  that the caller passes the failure on.

## Comments

- `compiler/**/*.agc`: a `#` comment where the code is complex or a rule is easy
  to break (name the rule). Each `def`, `struct` or `enum` you add or touch gets
  a `##` block, as in `stdlib/queue.agc`. The file's first `##` block, followed
  by a blank line, is its module doc.
## Code style

- Lines are at most 119 characters, comments included (`compiler/agentica.toml`
  `[style]`, checked by `tests/test_style_line_width.py`). Break a call or list
  one item per line with a trailing comma; wrap a long expression in
  parentheses.
- Build strings with interpolation, not `+` or `.to_s`.
- Several steps on one value are a pipe chain in parentheses, one `|> f(args)`
  per line, not `x = f(x, args)` repeated three or more times.

## The command line in Agentica (step 8a, the product since 8d-2)

`Cli.run(settings, words, hand_off) -> Int` reads the options
(`cli_options.agc`, first error wins; `--version` and `-h` answer at once) and
runs `check`, `compile`, `help`, `test` or a source file through `pipeline.agc`,
which the BDD driver shares. A command never prints: it returns a `Reply` (code,
stdout, stderr) and `cli.agc` writes it. Diagnostics print as plain text
(`diagnostic_plain.agc`), `--ai` (`diagnostic_ai.agc`) or JSON
(`diagnostic_json.agc`). `hand_off` calls `FrontEnd.hand_off`
(`front_end_cli.agc`), so an ordinary run stays in the binary's process with no
child or temporary file. `agentica run` is answered in C (`vm/agentica.c`) when
it is the first word; `cli.agc` answers a later `run` with a usage error.
`test` runs the BDD driver in the same process and starts the runner as
`settings.self_path run ...`; without `--self` it exits 2.
`tests/test_cli_forms.py`
pins the binary's command line against `tests/fixtures/cli/forms.json`.
`cli_text.agc` keeps the help texts as data.

To run a `compiler/` change without the build chain:
`dist/agentica run --allow-run -- build/stage/stage2.agcb --version V --stdlib
stdlib --self PATH -- WORDS`
(`tests.agentica_test.front_end_command` builds it).
