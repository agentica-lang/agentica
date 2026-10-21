# Language rule notes

What the checker enforces and the VM keeps for each core language area: Result
and `try`, collections, ranges, file modules, methods, interpolation, blocks,
hints, enums, function values. VM internals are in `references/vm.md`. Read the
section for the area you are changing.

## Result, propagation, and runtime bounds

- `Result[T]` is builtin, with String errors and contextual `ok`/`error` typing.
  Forward expected types through the shared call path; do not add global
  inference or dummy payload types. Untyped errors are `CHECK-RESULT-TYPE`.
- `try` is a unary expression node. It requires a Result-returning function
  (`CHECK-TRY-CONTEXT` otherwise), unwraps successes, and returns errors through
  the current function's escape. It does not guarantee a return.
- `IO.gets` returns Result[String]; `IO.gets!` is the String-returning form that
  halts. Non-bang conversions recover only their documented failures.
- `--max-steps` counts every expression/statement entry, including loop
  conditions, per run. The CLI validates the input; check never executes. This
  is not a blocking-I/O timeout.
- A rebase changing AST/diagnostic layouts may leave a stale `dist/agentica`.
  Use `make clean` and rebuild the binary with make before evaluation.

## Collections and algorithm examples

- `List.map/filter/reduce` infer input element types from exact callback
  signatures, including empty lists. Reduce is a left fold with accumulator
  first; its callback result must equal its accumulator type and supplies
  context for the initial value. Map rejects Void results. Traversals preserve
  inputs and order and cost O(n) excluding callback work.
- `List.sort/sort_by` are stable, order strings by code point and put NaN last.
  The checker allows only Int, Float or String elements/keys. sort_by calls the
  key once per element, then sorts the cached keys; the key callback's parameter
  type types an empty input list.
- String search and conversion builtins: index_of returns character positions
  (empty part is ok(0)); at/code/from_code report errors at the argument span;
  from_code rejects surrogates. Float.to_int/to_int! share `fallible`:
  NaN/infinity give RUNTIME-INVALID-NUMBER, out-of-range truncation
  RUNTIME-INTEGER-OVERFLOW. `Float` works as a builtin module prefix because
  catalog names are full dotted strings.
- Time and Random: each run seeds its generator from `--seed` (0..2^31-1) or OS
  randomness; the VM uses xoshiro256** with one generator per task
  (`references/vm-core.md`). Random.int is uniform over the full Int range; min
  > max is RUNTIME-INVALID-RANGE at the call. `agentica --seed N test` passes
  `--seed N` to the runner, each scenario VM and each program under test, so
  handlers and programs under test draw the same sequence.
- `List.concat/take/drop/at` go through the catalog and generic checker. Concat
  propagates expected types and can infer an empty first list from the second.
  Take/drop accept all nonnegative Int counts, clamp to length, and report
  RUNTIME-INVALID-COUNT at negative counts. At propagates the expected element
  type and reuses RUNTIME-INDEX-OUT-OF-RANGE at the index argument. Inputs stay
  immutable; concat costs O(length of first list), and take/drop/at are O(n).
- `List.append`, `set`, `repeat`, and `reverse` preserve inputs. Indexing and
  updates remain O(n); repeat is capped at 1048576 and reports
  RUNTIME-INVALID-COUNT at the count argument. List.set uses the existing index
  diagnostic at the index argument.
- Catalog entries with several signatures (Map.get): `references/stages.md`
  (Builtin catalog).
- Generic rules propagate expected types into list construction/updates and
  Map.get. Keep false/nil lookup payloads distinct from absent keys. Map.delete
  updates both the hash and insertion-order keys; reinsertion goes last.
  Map.values follows Map.keys order.
- A step-limit stop is not an "unsolvable" answer: the algorithm examples
  (`knight-tour`, `traveling-salesman`, `maze-bfs`) keep their sizes small and
  their tests validate complete routes and known optimal costs. A queue built
  on Map.delete is O(n), so BFS alone does not show linear runtime.

## Ranges

- `a..b` / `a...b` are `Binary` nodes with the operator kinds `dot-dot` /
  `dot-dot-dot`; ranges bind looser than `or` and do not chain. The checker type
  is `Type.Range` (a reserved type name, printable, `==` allowed, not
  encodable). `for` over a Range binds an `Int`. `Range` and `Int` are method
  modules, so `r.size` is `Range.size(r)` and `3.times` is `Int.times(3, f)`;
  the catalog rows use the generic `#f` rule (a block gets its `Fn[Int, Void]`
  from the parameter).
- VM: see `references/vm-lowering.md` (counter loops, `RANGE`/`RANGE_BOUNDS`,
  counting native frames).

## Sets

- `Set[T]` is the checker type `Type.Set(T)` with `T` `Int` or `String`
  (`CHECK-SET-ELEMENT-TYPE`; `Set` is a reserved type name). Printable, not
  encodable, no `==`; `Test.eq` accepts it. `Set` is a method module
  (`method_modules` in `check_tables.agc`), so `s.add(x)` is `Set.add(s, x)`.
  The catalog rows carry rules (`set-new`, `set-add` for add and delete,
  `set-include`, `set-query`, `set-to-a`, `set-combine`, `set-subset`) because
  their generic types need the expected type: `Set.new([])` with none is
  `CHECK-EMPTY-SET-TYPE`, and the first argument of `add`, `delete`, `union`,
  `intersection` and `difference` takes the expected set type.
- `for x in set` lowers to `Set.to_a` into the hidden list slot and then the
  list loop (`compiler/lower/lower_stmt.agc`). The VM keeps a set as an
  `agc_map` with nil values under `AGC_T_SET` (`references/vm-core.md`).

## File modules

- The linker (`compiler/modules/declarations.agc`, called by `modules.agc`)
  checks the declaration order of each file (`CHECK-DECL-ORDER`: imports,
  constants, structs and enums, `export def`, `def`) when it visits it, before
  linking, so the root, imported files, `std/` modules and BDD files all follow
  it. The checker never sees it: the linked program has lost the file
  boundaries. `compiler/` files and every new `.agc` keep the order.
- The linker (`compiler/modules/modules.agc`, `resolve.agc`, `rewrite.agc`)
  links parsed files before checking: canonical paths deduplicate imports and
  detect cycles; aliases resolve only exported declarations. Dependencies get
  unique internal identities while root names remain stable for CLI entrypoints.
  Preserve every original span when rewriting nodes; never restart evaluation
  for imported calls/tasks. Imports resolve relative to their source, not cwd.
  An import path has no extension: `module_file` (`import_path.agc`) appends
  `.agc` before resolving, so module keys, std/ registry keys and span source
  names stay real `.agc` file names; a path ending in `.agc` gives
  `CHECK-IMPORT-PATH` with a help showing the path without it, and an empty
  path, a trailing `/` or a dot in the last part give the same code. Imported
  types get an internal `@N::Name` identity; human text (printing,
  `to_s`/`inspect`, checker messages through the type printer and `display_name`
  on struct, enum and function names, the VM tables) shows it through
  `display_name` in `compiler/syntax/types.agc`, so `Point` from any module
  prints `Point`; `did_you_mean` keeps only candidates with the same `@N::`
  prefix as the name (builtins are shared) and suggests their display names.
  Keys stay linked: `JSON.schema` `$defs` keys and `$ref`s keep the `@N::` name
  so two imported `Point`s never collide. Alias/declaration collisions and
  builtin-name redefinitions are rejected before renaming. as is contextual,
  import/export are keywords.
- CLI check/run/dump/compile and the BDD driver's step program share this
  resolver. Raw import/export nodes passed directly to check give
  CHECK-MODULE-CONTEXT. Exported signatures may mention private types; importers
  cannot name/construct those types. `std/` reads the Agentica sources embedded
  in the binary (`stdlib/MODULES`, `gen-embedded.sh`), with virtual source names
  and no filesystem fallback. Add shipped modules to `stdlib/MODULES`. `pkg/`
  searches entrypoint-local agc_libs, absolute AGENTICA_PATH roots, user data
  and Unix system data (`library_roots` in resolve_import.agc holds the Windows
  rules: `;`, drive and UNC roots, LOCALAPPDATA, no system roots); first
  existing file wins. Skip missing candidates before normalizing the path (it
  fails for absent parent directories); validate namespace components and
  canonical symlink containment. Other paths remain source-relative, unless
  their first part is a package name the importing file declares (the project's
  manifest, or the package's own for a package file; `package_import.agc`). Then
  the files come from the cache folder of the locked commit, hashed once per
  build, and a package file may not import outside its package. `agc_libs/` of
  `pkg/` sits beside `agentica.toml` when there is one. No package registry,
  wildcard imports, module state, cycles, or receiver attachment.
- Linking/visibility and cross-file diagnostics are tested through `--json
  check` in the `tests/test_spec_*.py` modules and against the frozen goldens in
  `tests/test_frontend_modules.py`. Unknown dotted calls without a matching
  import alias pass to the checker so misspelled builtin calls retain
  CHECK-UNKNOWN-NAME; unknown qualified type aliases remain CHECK-IMPORT-NAME.

## Methods on builtin types

- The parser makes `MethodCall` for `x.name(args)` (except `.call(`, which
  stays `Invoke`, and `.with(`, which is the `StructUpdate` node) and
  `FieldAccess` for `x.name`. Method names may carry `?`/`!`.
- The checker resolves methods by the receiver's static type (`check_names.agc`,
  with the tables of `check_tables.agc`). A catalog function is a method only
  when its first parameter has the receiver's type head. Resolution builds a
  synthetic call whose first argument is a `TypedTarget` (the receiver plus its
  already-known type, so chains are checked once) and stores it in
  `Checked.resolved` by node id; `to_s` on String stores the `TypedTarget`
  itself. Lowering lowers only the resolved node; a `TypedTarget` does not count
  a step. Builtin diagnostics keep working because they read the argument spans
  from the synthetic call.
- `value.with(f: x)` is checked in `check_call.agc` with the field rules of
  construction: a receiver that is not a struct is `CHECK-UNKNOWN-METHOD`, a
  struct hidden from the importing module is `CHECK-IMPORT-NAME` (the linker
  sets the node's `visible` list: own structs plus the exported structs of
  directly imported modules), and a field of `Fn` type named `with` is
  `CHECK-REDEFINED-NAME` because the update would hide it.
- Field access on a struct is unchanged; on anything else it is a zero-argument
  method. Unknown methods are `CHECK-UNKNOWN-METHOD` with did-you-mean or the
  method list.
- `CHECK-UNUSED-VALUE`: an expression statement whose (resolved) call is a
  builtin with no effects, a non-`!` name and a non-Void result. The
  `FieldAccess` and `MethodCall` nodes have an auto `resolved` field that the
  parser leaves absent and the linker and checker fill.

## String interpolation

- The lexer scans string text; `#{` emits `interp-start`/`interp-middle` with
  the text so far and pushes a `#` frame on `delimiters`; the `}` that meets
  that frame resumes string scanning, and the resumed
  `interp-middle`/`interp-end` token starts at that `}` so parse errors point at
  it, and the closing quote emits `string` (no interpolation) or `interp-end`.
  Newlines and EOF inside an open frame are `LEX-UNTERMINATED-STRING` at the
  string start. `\#` escapes `#`.
- The parser builds `Interpolation` with text and expression parts (empty text
  pieces dropped). The checker checks each expression with no context (Void is
  rejected, and `ensure_printable` rejects types without `to_s`: functions,
  tasks, handles) and types the node as String; the VM inserts each value in its
  `to_s` form (strings raw, `Json` as JSON text, others in the inspect form).
- `puts`/`print`/`IO.puts`/`IO.print`/`IO.warn` take `T` with the `show` rule
  tag, which only calls `ensure_printable`; the VM writes the `to_s` form.
  `x.to_s` resolves through the method tables for String/Int/Float; for any
  other printable type the checker records a one-part `Interpolation` node, so
  `x.to_s`, `"#{x}"` and `puts(x)` share one text form. The printable check
  requires printable type arguments and checks each struct or enum declaration
  once by name (type variables count as printable), so non-regular recursive
  enums terminate. Only `.to_s` (a resolved interpolation) is
  `CHECK-UNUSED-VALUE` as a statement; a written `"#{x}"` statement is not. A
  struct field named `to_s` stays a field. `x.inspect` follows the same path but
  records an inspection (`State.Resolved.Inspect`), which prints the inspect
  form; a struct field named `inspect` also stays a field.

## Blocks and closures

- Lexer: `def struct enum if while for do` push a keyword frame on
  `delimiters` and `end` pops it, so NL is emitted when the stack is empty or
  its top is a keyword frame. That keeps statement newlines inside a block
  written within `(...)`. Keyword frames left open at EOF are not a lexer error
  (the parser reports `PARSE-UNCLOSED-BLOCK`); a `)` that meets a keyword frame
  is `LEX-UNMATCHED-DELIMITER`. `|` is the `pipe` token; `||` stays `or`.
- Parser: `parse_postfix` turns `do` after a `Call`, `MethodCall` or bare
  `FieldAccess` into a `BlockLit` appended as the last argument. `allow_blocks`
  is off while parsing a `case` scrutinee, a `while` condition and a `for`
  iterable, and back on inside `(...)`, `[...]` and argument lists. Only the
  direct statements of a block body may end at `end` instead of NL, which
  allows `do |x| x * 2 end`; `parse_block`/`parse_case_body` reset the block
  depth to 0 for nested bodies. A block that meets a non-`Fn` last parameter is
  `CHECK-BLOCK-TARGET` (`check_builtin_call` in `check_rules.agc`), before any
  rule runs.
- Checker: `check_block_body` takes known parameter types and result (or none).
  With no known result, the first `return` or the last expression fixes it.
  The checker keeps the scope depth at the block; assigning to a name found
  below it is `CHECK-CAPTURED-ASSIGNMENT`. List callback rules check the list
  first when the callback is a block, then the block with the element type; the
  `&f` path is unchanged.

## Hints for foreign habits

- `foreign_names` and `foreign_methods` (`check_tables.agc`) map names from
  other languages to a help text. They win over did-you-mean for
  `CHECK-UNKNOWN-NAME` (names and calls), `CHECK-UNKNOWN-METHOD` and a bare type
  name such as `None`. `conversion_help` explains a `Result[T]` found where `T`
  is expected. `foreign_kind_methods` maps a (receiver kind, method name) pair
  to a help text for names that need more than one method (`chars`, `matches?`);
  `missing_return_help`, the `same!` operand help, and the
  `CHECK-NOT-INDEXABLE`/`CHECK-EMPTY-*` helps are concrete too. The lexer hints
  `'` and the parser hints `//`, `/*`, a top-level statement or extra `end`,
  `elif`/`elseif` and `else if`, `let`/`var`/`val`/`const`/`match` used as
  keywords, `when`, `then`, lambdas, `loop do`, and other habits (`rg 'bail'
  compiler/syntax/`; the parser's `bail` takes a help). Tests assert the code
  and a regexp on the help, never the full text. For an unknown plain name the
  checker prefers did-you-mean over `foreign_names`, so `next` near a visible
  `nexts` still suggests `nexts`. The linker's failures take a help too (an
  unknown alias in expression position says it is neither an import nor a local
  enum; `Result.X` without parentheses names the Result spellings; in a type or
  pattern it only suggests the import).
- `break`/`next` are contextual: the parser makes a `LoopControl` node only when
  the name is followed by NL, `end` or EOF, so they still work as variable
  names. The checker's loop depth is reset per function and per block
  (saved/restored in `check_block_body`), so they cannot cross a block.
- Two spellings for Result: the parser turns `Result.Ok(...)`/`Result.Err(...)`
  into `ok`/`error` calls (in `parse_base.agc`/`parser.agc`), and the patterns
  `ok(v)`/`error(m)` into a `VariantPattern` of `Result` (the case arm lookahead
  knows them). `gets`/`gets!` without `(` parse as zero-argument calls. A
  two-part `Enum.Variant` with no parentheses is a `TypeName` until the linker's
  rewrite turns it into an `EnumConstructor` when the first part is a local
  enum; three parts (`M.Enum.Variant`) parse directly. Programs checked without
  linking keep `CHECK-TYPE-MISMATCH` for `Enum.Variant`.
- Ruby headers: a case arm may hold one simple statement on the arrow line
  (parsed at block depth 0, so it needs its NL); the arm lookahead needs the
  pattern followed by `->`, or by `if` and a guard that reaches a `->` on the
  same line (the look-ahead is iterative, with an open-paren count, so a deep
  pattern costs no stack). `Module.fn` without `(` is a zero-argument `Call`.

## Enums and pattern matching

- `EnumDecl` and `EnumVariant` live in `ast.agc`; `CaseStmt`, `CaseArm`,
  `WildcardPattern`, `LiteralPattern`, `VariantPattern`, and `EnumConstructor`
  are the matching nodes. The parser maps `true`/`false`/`nil` patterns to
  literal values, just like expression literals. `VariantPattern.slots` is a
  `List[Slot]`: `Bind(name)`, `Skip` (`_`) or `Nested(pattern)`. Names and `_`
  have no node ids, so a program without nested patterns numbers its nodes as
  before; a nested pattern node gets its id before its parent variant
  (post-order), and `CaseArm.guard` is parsed after the pattern ids and before
  the body. A nested variant counts one nesting level in `parse_base.agc`
  (`PARSE-TOO-DEEP`). The lowering tests a nested slot by reading the payload
  into a temporary register (`read_payload`) and testing that, then binds; the
  guard is lowered after the bindings with a `jump-if-false` to the same skip
  label as a failed test.
- Generic type variables exist only while resolving an enum's payload
  declarations. Preserve those names while the module linker rewrites type
  references; otherwise `T` becomes a module-qualified ordinary type and generic
  enum registration fails. Imported enum references resolve `Alias.Enum`;
  variants need `Alias.Enum.Variant`.
- Nullary enum construction with `Option.None()` is parsed as a general
  `Construct` node (empty argument list); module linking, checking and lowering
  must recognize the enum prefix. Payload variants parse as `EnumConstructor`.
  Imported nullary calls have three segments and must be rewritten before
  ordinary struct constructor resolution.
- Checker enum types are nominal and retain their enum name plus resolved type
  arguments. Infer type variables structurally from payload types and seed
  inference from a matching expected enum type. `Result[T]` is still the builtin
  Result, but case patterns use tags `Result.Ok` and `Result.Err`;
  `Result[Void]` can only discard its Ok payload with `_`.
- Enum cases require every variant or `_`. All non-enum scrutinees—including
  Bool and Nil—require `_`. Reject repeated/covered arms, require an unguarded
  `_` last (a guarded arm, or one with a literal or nested slot, covers nothing
  and may repeat a pattern), and validate pattern payload arity/types before
  checking each arm in a fresh scope. Exhaustive case branches participate in
  all-path return analysis.
- Keep the independent module-linker tests for exported/private enums and
  imported patterns.

## Function values

- `&name` creates a named `FunctionRef`; `Fn[A, ..., R]` uses the final
  argument as return type, and `.call(...)` is a dedicated `Invoke` node.
  Resolve only declared functions; no closures, builtin references, function
  equality or JSON encoding. Inspect is `<Fn>`.
- The `agentica test` step handlers and their rules are in `references/bdd.md`.
