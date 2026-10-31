# Front-end recipes and gotchas

Read before editing `compiler/`. The front end is Agentica code in `compiler/`,
the only one. Every language change is made there with a golden: syntax, checker
rule, builtin row, builtin record or enum entry, registry line, std-only or
reserved name, message text.

## The front end in Agentica

### Stages and files

`compiler/` has one folder per context (`references/repo-map.md` lists the
files); a new file goes in the folder of its context. An import inside a folder
is the bare name (`"lexer"`); across folders it is relative
(`"../syntax/types"`). Each stage returns its typed outcome, data or one
diagnostic: `Lexer.lex` returns `Diag.Outcome`, and other stages may use
`Result` with a packed `Problem` (`references/stages.md`).

- `modules/link_env.agc` (`Env` and `Settings`): `stdlib/` and the environment
  are passed in, never read inside. A new environment variable gets a `--name=V`
  flag in `link.agc`, `check.agc`, `lower.agc` and `bytecode.agc`, and a value
  in the hermetic test environment.
- Packages (`packages/`, §45): rules in `docs/grammar/05b-modules.md`. Docs
  (`docs/`, §32.5): `agentica doc` links a module only when it has re-exports
  (`docs/doc_origins.agc`); tests in `tests/test_spec_doc.py`.
- Query (`query/`, §39): `outline`, `type-at`, `symbol`, `refs`
  (`app/cli_query.agc`). `type-at` and `refs` link and check
  (`analysis/front.agc` `query_file`; a missing `main` is not `CHECK-MAIN`);
  `symbol` links only. A local comes from `locals.agc` and `Checked.bound`, kept
  apart from `Checked.types` so lowering never sees it. The tree has no span for
  a name inside a call or a pattern, so `written` reads the dotted name from the
  text. Tests: `tests/test_spec_{outline,type_at,symbol,refs}.py`.
- Analysis (`analysis/`, §39, `std/analysis`): `analysis.agc` is the one
  implementation of `check`, `outline`, `type-at`, `symbol` and `refs`, called
  by `app/` and `stdlib/analysis.agc`. It returns the plain structs of
  `model.agc` (no enum; `""` and empty lists for absent values), which `query/`
  prints. `stdlib/analysis.agc` compiles `stdlib/CORE` as
  `std/internal/compiler/`, so anything the library needs must be there.
  - Session cache (`cache.agc`): node ids have gaps and are not in
    walk order, so nothing reads a node id except through a node it holds
    (`Linker.parser_ids` is the highest `next_free_id`). A cached root is
    used only when `Cache.find` sees the same fingerprint and texts
    (`test_std_analysis.py` compares cached and uncached answers).
    `Analysis.entry` and `adopt` move a root between sessions with
    `Cache.alone`, never merged, since two caches' ids can overlap.
    `check_reuse.agc` copies the entries of an unchanged module from the
    root's last checked program (`Cache.Good`).
  - Check cache (`modules/check_cache.agc`, `io/check_cache.agc`;
    `check` and `type-at` only): one file per imported source in
    `_build/check/`, holding the text digest, the tree digest at which it
    passed, a same-length stub (bodies and private functions blanked) and
    the constant types. A module whose tree digest the entry vouches for
    is `clean`: its bodies are not checked, and it is parsed from the
    stub. A walk with a stubbed module that is not clean is redone without
    stubs, and a problem in a stubbed file falls back to `query_cached`,
    so the answer is always the cold one. Anything the core or the CLI
    adds to `Modules` or `Checker` that new entries depend on must be in
    the tree digest (`Modules.shape_of`). `test_check_cache.py` compares
    cold, warm and `--no-cache` runs.

### Pure core, one port

The pure folders (the AGENTS.md rule) may import only the `std/` modules on
`PURE_STD_MODULES` of the test; a new std module is forbidden by default. When a
stage needs the machine, it calls a function of `Workspace`
(`modules/workspace.agc`), a record of function values that travels in
`Env.Settings.workspace`. `io/host.agc` builds the real `Workspace` and
`process_env`; a test can build one over an in-memory tree. A new need of the
machine is a new `Workspace` field, built in `io/host.agc`.

The entry programs (`syntax/lex.agc`, `syntax/parse.agc`, `modules/link.agc`,
`check/check.agc`, `lower/lower.agc`, `bytecode/bytecode.agc`,
`catalog/catalog.agc`) may call `System.args`, print with `puts` and import the
`io/` adapters. A new entry program needs a line in `ENTRY_PROGRAMS`.
`tests/test_style_core_purity.py` runs the real lexer over the stage folders and
fails on a call (`Module.name` as tokens, so strings, comments and data rows do
not count) or an import. The linker (`modules/`, `packages/`) imports no later
stage. `catalog/` imports only `syntax/` and itself, so every later stage reads
it.

Code style follows the speed rules: build lists with `push`, strings with
`join`, and loops rather than recursion over the input.

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
message and help text on purpose: a deliberate exception to "tests assert codes,
not messages". Module fixtures are folders in `modules/`: `root.agc`, an
optional `fixture.env` (`AGENTICA_PATH=`, `XDG_DATA_HOME=`, where `@/` is the
fixture folder), and `fixture.links` (`LINK TARGET`, made as symlinks in a
copy).

The exact text of each stage is what its golden holds (above).

## Rules for the code

- Spans and positions: `references/stages.md` ("Conventions"). Node ids follow
  post-order; the writer and lowering rely on the order of the function table,
  registers and first-named sources. Keep them.
- Parser tables are module constants (`NESTING_LIMIT`, `LEVELS`,
  `COMPOUND_OPERATORS`, `LITERAL_KINDS`, `GRAPHIC_RANGES`); do not rebuild them
  in zero-argument functions.
- Lexer: text is a `List[String]` of characters (`text.split("")`) followed by
  three `""` sentinels, so scans need no bounds test. Every stop set includes
  `""`. Keep cached `top` and `depth` in sync with `delimiters`, and recompute
  `column_base` whenever `line_start` changes. Calls cost more than assignments
  on the VM: measure before restyling hot functions (a tail-recursive
  `state.with(...)` measured 3-6% slower).
- Depth limits: the parser and the checker stop at 1,000 levels
  (`references/stages.md`); lowering uses at most 3 VM frames per level; the
  writer recurses only on JSON field types (1 frame per level, at most 1,024).
  The VM call limit is 10,000 frames. The linker's rewrite is about one VM call
  per level.
- The checker's `Cx` is immutable; state is a threaded `St`; scopes are one
  persistent `Map` that a scope snapshots and restores. `Checked.types` is a
  `List[Type]` indexed by node id (a `Map` measured 50% slower). A builtin
  method call is checked as a call with the receiver as an `Ast.Expr.Typed`
  first argument, added by the checker, never by the parser.
- Module constants: the parser reads a top-level `NAME = ...`; `NAME.x` parses
  as a module call; only the linker makes `ConstRef`, turning a receiver one
  into a `FieldAccess` when the call has no parentheses and no arguments.
  `const_walk.agc` is shared by the checker and lowering; `check_const.agc` runs
  after `main`, in `Checked.constants` order; `lower_const.agc` plans them.
- Default parameters: `Param.default`, rewritten by the linker with the
  declaring module's names. `check_defaults.agc` checks order and shape;
  `defaults.agc` gives the `Shape` and which parameter an argument fills. The
  checker and `lower_argument` share these functions. Compiler code must not use
  defaults until `bootstrap/stage0.agcb` can compile them (the two-step refresh
  in `references/ci.md`).
- Builtin defaults: a catalog parameter may have
  `default: Model.Default.Whole(0)` (`Model.Named`; also `Real`, `Text`, `Flag`,
  `Nothing`, `EmptyList`, `EmptyMap`, `EmptyBytes`, `Variant("LogLevel.Info")`).
  `Defaults.builtin_shape` gives the shape, and `Builtins.form_for` picks the
  form for each count. `check_plain` and `check_prelude` map arguments with
  `Defaults.param_of`; `lower_call` fills the omitted ones
  (`lower_builtin_default`) and emits `call-builtin` with the full count, so the
  VM never sees a short call. A default is only for a Plain or Prelude row with
  no alternatives (`Builtins.default_problem`, checked by
  `test_frontend_catalog.py`). The signature, `help`, its JSON (`default`) and
  the CHECK-ARITY range (`Builtins.arity_text`) show it. A builtin has no
  function value.
- Import forms and the linker's `named` table: `references/stages.md` (Linker).
- Type aliases: `Ast.Decl.TypeAlias`. `check_register.agc` registers them before
  signatures; `check_types.agc` expands them (`CHECK-TYPE-ALIAS-CYCLE`): the
  arguments first, then the target with only the alias's own parameters in
  scope, then the arguments put in as a plain substitution (a name in the target
  is never an enum parameter of the use).

## Common tasks

Run the stage's tests after each change:
`make test TESTS="tests/test_frontend_<stage>.py"`, then refreeze the goldens
the change touches on purpose, and read the diff.

### Add a keyword or operator

Edit the `compiler/syntax/lexer.agc` tables: keywords go in `WORD_ACTIONS` (1 or
2 for block openers, 3 for `end`); operators go in `OPERATOR_KINDS` and
`SINGLE_LEXEMES` or `PAIR_LEXEMES`, with characters in `CLASSES` (and
`PAIR_SECONDS` for a new second character). If the parser acts on it, handle it
in `parser.agc` or `parse_base.agc`. Add a golden in
`tests/fixtures/frontend/lexer/`, and a spec case in `tests/test_spec_<area>.py`
if syntax changes.

### Add an AST node

Add a struct to `ast.agc` with `id` first and `span` last, plus a variant in
`Expr`, `Stmt` or `Decl`. Construct it in `parser.agc` with the span from the
first to the last consumed token (`Base.span_from`) and the next free id. Update
every walker: `rewrite.agc`, `const_walk.agc`, the checker, lowering,
`parse_text.agc`. Parser golden: `tests/fixtures/frontend/parser/NAME.input`.

### Add syntax

Add tokens first if needed, then the node, then a parse function called from the
right place (statement, primary or program parser). Add a valid test and a
rejection test that asserts the code, in `tests/test_spec_<area>.py`. The syntax
is Ruby's when Ruby has one; another habit gets a diagnostic with a `help:`.

### Add a diagnostic code

Pick a stage prefix (`LEX-`, `PARSE-`, `CHECK-`, `LOWER-`, `BYTECODE-`,
`RUNTIME-`). Raise it with the stage helper (`Base.bail`, `Failure.problem`) and
a span. Test the code and the location (`start`, `covers` from `--json check`),
as in `tests/test_spec_checker_rest.py`. A `help:` writes builtins in the Ruby
form (`s.strip`), never the internal name.

### Add a builtin rule

Add a `Rule` variant in `builtin_model.agc`, an arm in `check_rule`
(`check_rules.agc`), and an arm in `rule_name` or `later_rule_name`
(`catalog_text.agc`; otherwise the text prints `?`). Add a calling fixture (a
fast test requires one), and edit `frozen/check/builtin-rules.expected` by hand.

A trailing option of a Plain row is a default, not a second row:
`Model.Named(name: "seed", type: Types.Type.Int, default: ...Whole(0))` (see
"Builtin defaults" above). Use an alternative form only for another rule or
another result type (`Map.get`).

### Add an opcode

Add an entry in `OPCODES` in `bytecode_tables.agc` and `agc_opcode` in
`vm/value.h`, in the same order. Lower it in `lower_*.agc`, `vm/loader.c` and
`vm/interp.c`. See "Refreeze" for the stage order.

### Add a pipeline stage

Create `compiler/<context>/<stage>.agc` with one entry point that returns the
next data or one diagnostic. Wire it in `compiler/app/pipeline.agc`. Add an
entry program that prints its text form (like `check.agc`), and the tests
(`tests/test_frontend_<stage>.py`, a spec module). `make test` discovers them.

### Add tests

A language rule runs `cli() + ["--json", "check", path]` in
`tests/test_spec_<area>.py`. Assert the code and, when relevant, `start` and the
covered text, never message text. Many small cases go in
`tests/fixtures/spec/checker-rest.json` (program lines, `code`, optional
`start`, `covers`, `help`, `expected`, `actual`, `function`, `callee`,
`labels`). Cover the happy path, the error path and the new behavior.

### Speed change to a stage (differential run against master)

Keep every token, span, diagnostic and byte. Compare master's stage with the
branch's on the same binary:

```sh
mkdir -p /tmp/master-src && git archive origin/master compiler | tar -x -C /tmp/master-src
dist/agentica compiler/syntax/lex.agc $(git ls-files '*.agc') > /tmp/new.out
dist/agentica /tmp/master-src/compiler/syntax/lex.agc $(git ls-files '*.agc') > /tmp/old.out
cmp /tmp/old.out /tmp/new.out
```

Add generated inputs (CRLF, bare CR, non-ASCII, bad escapes, unclosed brackets,
interpolation), and every prefix of one construct-rich text, which covers each
end-of-text position. Finish with `make fixed-point` and `make goldens`, which
must leave `git status` clean. Record the result in `docs/vm-benchmarks.md`.

## Refreeze: `tools/refreeze.py`

`poetry run python tools/refreeze.py` reruns the pytest modules
`tests.test_frontend_<stage>` with `AGENTICA_REFREEZE=1`: a golden mismatch
rewrites the golden and logs the change. Run it in the Poetry test environment.
Flags: `--fast-only` (skip the slow tier), `--stage lower` or `--stage
lexer,parser`, `--jobs N`. It prints what changed (manifest entries, or a
unified diff for a text golden) and freezes whatever the stage prints, so read
`git diff` and judge each change. Other assertions still fail. A manifest keeps
only hashes; to see an output, run the stage by hand.

- Default stage order: lexer, parser, modules, check, lower, catalog, bytecode.
  With a new opcode, run refreeze twice, or run `bytecode` first (`--stage
  bytecode`); `lower` reads the frozen opcode table. Use `--jobs 1` so stages
  run in dependency order. The second run must print `nothing changed` for every
  stage.
- A stage whose tests are all skipped (a missing tool) freezes nothing: the tool
  exits 1.
- Two goldens have no Agentica source, so refreeze never changes them. Edit them
  by hand in the same PR as the code or builtin that adds a line:
  `frozen/check/codes.expected` and `frozen/check/builtin-rules.expected`.

### Frozen comparisons

The slow tiers compare the stages with the frozen outputs in
`tests/fixtures/frontend/frozen/` (`tests/test_frontend_<stage>.py`, run through
the product CLI). Fast cases: the bytes of examples, id ranges, invalid UTF-8,
limit scenarios and id numbering; the rest are `@slow`. Helpers:
`tests/frontend_support.py`, and `tests/frontend_cases.py` for inputs built from
formulas.

- `frozen/corpus/*.json` is a fixed snapshot of inputs (examples, stdlib,
  fixtures, `compiler/`, old checker programs, site code blocks). A new
  `stdlib/` file is not in it.
- Seeded inputs are checked in (`lexer/generated.json`, `parser/generated.json`,
  `check/mutated.json`, `modules/mutated.json`). Formula inputs (nesting shapes,
  chains of 3,000 files, files over 1 MiB, programs of 300 and 1,000 functions)
  are rebuilt by Python; the SHA-256 in the manifest must match, or the test
  fails as a test bug.
- Manifests `frozen/<stage>/<set>.sha256` hold, per input, the output's and the
  input's SHA-256 and size, and the key. Small outputs are text (`*.expected`).
  `.agcb` files hash without the length and the version text, so a release does
  not change the freeze. Other lists: `frozen/modules/stdlib-registry.expected`
  (a new `stdlib/` file is one line), `frozen/check/tables.expected` (a copy of
  `check_tables.agc`).
- Every input has a golden next to its fixture, and no golden is left over.
  `builtins_data.agc` is not compared with a fresh generation (it is
  hand-edited). Section and opcode coverage read the lowering goldens, which
  cannot tell the `types` and `decodable` sections apart.
- Fixtures that Python reads live are frozen with derived results:
  `modules/<name>/` (hashes in `modules/ids.sha256`), `limits/limits.agc` (it
  imports the live `compiler/`), `parser/synthetic.input`, `hello.input`, and
  `bytecode/*.agc` (`bytecode/fast.sha256`). Editing one, or a `compiler/` file
  that `limits.agc` imports, changes a frozen hash: refreeze and inspect the
  diff.

## Agentica gotchas

- Declaration order (`CHECK-DECL-ORDER`) and doc placement
  (`PARSE-DETACHED-DOC`): `agentica-code-guidelines`.
- `==` follows IEEE 754 on Floats (`nan != nan`, `0.0 == -0.0`). Compare types
  with `Types.same?`; an enum cannot be compared with `==`.
- The VM call depth is 10,000 frames. Recurse on the tree only with a bounded
  depth, or use an explicit stack and loops.
- A value that cannot happen is a `*-INTERNAL` diagnostic, not a crash.

## Lexer gotcha: stray NL tokens

The lexer emits one `NL` per LF or CRLF outside `()`, `[]`, `{}`, including
blank and comment lines, so several `NL` can appear between statements. The
parser skips stray `NL` at top level and between statements; keep that skip when
adding statement forms.

A line that starts with `.name` drops the NL before it (`dot_follows?`, in the
`CharClass.Newline` arm of `lex_from`) when the last token is in
`ENDS_EXPRESSION` and is not a type name after `->` or `:` (`ends_in_type?`).
The look-ahead skips `#` comment lines; a blank line or a `##` line stops it. A
block head (`if`, `elsif`, `while`, `case`, `for` as the first token of the
statement, tracked by `head_at`) never joins. Any other leading dot stays, and
the parser rejects it (`PARSE-UNEXPECTED-TOKEN` at the dot, or at the line break
after an operator). Do not use the form in `compiler/` until
`bootstrap/stage0.agcb` lexes it.

Top-level declarations need a blank line after `end`
(`PARSE-MISSING-BLANK-LINE`). A `##` block is one `DOC` followed by the NL of
its last line, not a blank line; a blank line and a `#` line both give one `NL`.
Stray text after `end` is `PARSE-TOP-LEVEL-STATEMENT`. Inline test programs end
their top-level `end` with `end\n\n`.

## Comments and style

Style and comments follow `.agents/skills/agentica-code-guidelines/`. Each
`def`, `struct` or `enum` you add or touch in `compiler/**/*.agc` gets a `##`
block, as in `stdlib/queue.agc`; the first `##` block, followed by a blank line,
is the module doc. Lines are at most 119 characters, comments included
(`[style]` of `compiler/agentica.toml`: `CHECK-LINE-TOO-LONG` in the build and
in `make check-compiler`). The pipe-chain rule is not linted; reviews
check it.

## The command line in Agentica

`Cli.run(settings, words, hand_off) -> Int` reads the options
(`cli_options.agc`, first error wins) and runs a command through `pipeline.agc`,
which the BDD driver shares. A command never prints: it returns a `Reply` (code,
stdout, stderr), and `cli.agc` writes it. `hand_off` calls `FrontEnd.hand_off`,
so an ordinary run stays in the binary's process, with no child or temporary
file. `agentica run` is answered in C (`vm/agentica.c`) when it is the first
word; `cli.agc` answers a later `run` with a usage error. `cli_text.agc` keeps
the help texts as data. Forms: `references/stages.md`.

To run a `compiler/` change without the build chain:
`dist/agentica run -- build/stage/stage2.agcb --version V --stdlib stdlib --self PATH -- WORDS`
(`tests.agentica_test.front_end_command` builds it).
