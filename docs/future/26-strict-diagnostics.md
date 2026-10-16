## 26. Strict diagnostics

**Status:** planned (roadmap phase 16), after 7i deletes the evaluator (order
7.2), as the first items of order step 7.6, before the phase 15 items of that
step, in the order 26.1, 26.3, 26.2, 26.4 (roadmap 16a, 16c, 16b, 16d). Decided
by the user on 2026-10-12; 26.4 was added after review the same day.

This section adds four errors that other languages give as warnings, or do not
check at all: an unused import, an unused variable, unreachable code and an
ignored `Result`. The checks are small and need no new syntax; the decision
behind them is the principle below.

**Principle: no warnings.** Agentica has no warnings, by design, as in Go: a
diagnostic is an error or it does not exist. There are three reasons:

1. **Agents ignore warnings.** An LLM agent reads the exit code and the first
   error. A warning does not stop the run, so the agent does not fix it, and the
   mistake stays in the code.
2. **A warning means "wrong, but allowed".** That is a second accepted way to
   write the code, against the one-way rule of [section
   25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): if a form is wrong, the
   language rejects it; if it is right, the language says nothing.
3. **One diagnostic per stage.** Each stage returns its output or exactly one
   diagnostic, and stops at the first error (`AGENTS.md`, "Conventions"). The
   diagnostic format has only `error` (`src/diagnostic.rkt`). Warnings would
   need a list of diagnostics next to a successful result, which breaks that
   contract for every stage and for `--json`.

**What the principle covers.** It covers the diagnostics of the language stages:
`LEX-`, `PARSE-`, `CHECK-`, `LOWER-`, `BYTECODE-` and `RUNTIME-`. Output of the
runtime and the tools that is not a diagnostic about the program's code is
outside it: the VM tracer's lines (`AGENTICA_VM_TRACE`), the CLI's one-line
fallback notice, and what a program itself writes to stderr with `IO.warn`.

So a new check is either an error with a stable code or it is not added. A check
becomes an error only when the case is almost always a mistake and the fix is
local and mechanical (remove a line, or rename to a `_` name). Checks that fail
this test are not added (26.5).

**Deprecations.** Deprecation warnings may be considered only after 1.0, when
there are users whose code must keep working while they move. Before 1.0, a
change in behavior is a breaking change: it lands as an error, the implementing
PR migrates the repo, and the `CHANGELOG.md` lists it under "Changed".

**No switch to turn them off.** There is no flag such as `--allow-unused`: a
check that can be turned off is a warning by another name, and it would give two
accepted ways again. The discard `_` (`_ = f(...)`, `for _ in ...`, `|_, v|`,
`error(_)`) is the one way to drop a value on purpose, and a name that starts
with `_` is the one way to keep a name that is unused on purpose (26.2).

**How it lands.**

- Each item is its own small PR, in the order 26.1, 26.3, 26.2, 26.4: the two
  small migrations first; 26.2 after 26.3, so a read in dead code never has to
  be counted (26.2, "Code that never runs"); and 26.4 last, because its one
  explicit discard, `_ = f(...)`, comes with 26.2 (before 26.2, `sent = f(...)`
  would silence 26.4 and leave no trace). Each PR comes after 7i (order 7.2), so
  the Racket evaluator and its tests are gone and need no migration. All four
  are front end only: the linker (`src/modules.rkt`) for 26.1, the checker
  (`src/checker.rkt`) for 26.2, 26.3 and 26.4. Only the discard of 26.2 touches
  the parser and `src/lower.rkt`, in a few lines; the bytecode format and the VM
  do not change.
- Each PR is a breaking change and migrates the repo in the same PR: the
  programs in `examples/`, `stdlib/`, `benchmarks/`, `tests/` (the `.agc`
  fixtures and the Agentica programs written inline in the Racket tests), the
  `agentica` blocks of `site/content`, and the examples of the programming
  skill. The impact list at the end of this section says what each item breaks
  today. The `CHANGELOG.md` gets one "Changed" entry per item. The 26.1 entry
  also speaks to package authors: an unused import in a `pkg/` library now fails
  the build of every program that uses the library, so a library should be
  checked with the new release before its users update.
- **Tests** in each PR cover each code three ways: checker or linker tests that
  assert the code and the span (`tests/checker-test.rkt`,
  `tests/modules-test.rkt`), never the message text; an `{expect="CODE"}` site
  example, which `tests/site-examples-test.rkt` runs end to end; and one
  CLI-level check: `racket src/main.rkt --json check file.agc` exits 1 and its
  JSON diagnostic has the code (next to the CLI checks of
  `tests/test_examples.py`, which already runs the CLI with `--json`). There is
  no golden fixture per code: the goldens in `tests/fixtures/vm/` compile and
  run on the VM, and compiling stops with an error on any front-end diagnostic,
  so a program that fails checking cannot be one.
- **Docs** in each PR: `docs/grammar.md` (the rule, and §7 "Diagnostics for
  agents" gets the no-warnings principle with whichever item lands first), the
  programming skill (`references/diagnostics.md` for the code, and one line in
  `SKILL.md`, since these rules apply to every program), the matching site page,
  and the development skill's notes. When an item lands, its text moves to
  `grammar.md` and is deleted here.

| § | Item | Stage | New diagnostic code |
|---|---|---|---|
| 26.1 | Unused imports | linker (`src/modules.rkt`) | `CHECK-UNUSED-IMPORT` |
| 26.2 | Unused variables | checker (`src/checker.rkt`) | `CHECK-UNUSED-VARIABLE` |
| 26.3 | Unreachable code | checker (`src/checker.rkt`) | `CHECK-UNREACHABLE-CODE` |
| 26.4 | Ignored `Result` values | checker (`src/checker.rkt`) | `CHECK-UNUSED-RESULT` |

The codes keep the `CHECK-` prefix, also for the linker's code, as the linker's
other codes do (`CHECK-IMPORT-NAME`, `CHECK-IMPORT-CYCLE`).

### 26.1 Unused imports

```agentica
import Text from "text"
import JsonUtil from "json_util"

def main() -> Void
  puts(Text.shout("hi"))
end
```

`JsonUtil` is never used, so the program is rejected:

```text
app.agc:2:27 error[CHECK-UNUSED-IMPORT]
the import alias "JsonUtil" is never used

2 | import JsonUtil from "json_util"
  |                           ^^^^^^^^
  = help: remove import JsonUtil from "json_util"
```

**Rule:** an import whose alias is never used in its file is
`CHECK-UNUSED-IMPORT`, at the alias.

**Why the linker.** The linker is the only stage that sees import aliases. It
resolves every `Alias.name` of a file through that file's imports (`resolve`,
`src/modules.rkt:151`) and rewrites it to the target's identity (`@N::name`);
the checker then gets one merged program with no imports left, and rejects any
import it finds (`CHECK-MODULE-CONTEXT`, `src/checker.rkt:1562`). So the checker
cannot tell which alias a name came from, and the linker must decide.

**What counts as a use.** Every place where `resolve` finds the alias in the
file's imports (the `target` branch of `resolve`, after
`(hash-ref (hash-ref imports key) alias #f)` at `src/modules.rkt:157`; the alias
is marked there), for any kind of name: a call (`Text.shout(...)`, also without
parentheses), a function value (`&Text.shout`), a type in an annotation, a
parameter, a field or a JSON type argument (`Models.User`), a construction
(`Models.User(name: "Ana")`), an enum variant as a value or a pattern
(`Domain.Option.Some(x)`), and an enum type (`Domain.Option[Int]`). A use inside
a function that is never called still counts: the rule is about the file's text,
not about what runs.

**Re-exports** ([section 25.2](25-ruby-typed-idioms.md#252-re-exports), roadmap
15b): `export Url.parse` counts as a use of `Url`. A facade file that only
re-exports is the main use of re-exports, and it must not need a fake call to
keep its imports. 15b lands after this item (both at order step 7.6), so 15b
marks the alias as used when it resolves a re-export, and its tests include a
facade that only re-exports.

**No side effects to keep.** An import has no effect besides its names: a module
has no top-level statements and no module state (`grammar.md`, "File modules and
imports"). So removing an unused import never changes what a program does.

**Every module.** The rule holds for every linked file: the root, relative
imports, `pkg/` libraries and the embedded `std/` modules. Each file is checked
against its own imports, once, even when several files import it. There is no
exemption for `pkg/` dependencies: one rule everywhere, as in Go, and a package
with a stray import is broken for every user, so the fix belongs in the package,
not in each program that uses it.

**Implementation sketch:**

- `import-decl` (`src/ast.rkt:54`) gains an `alias-span` field, filled by the
  parser from the alias token (`src/parser.rkt:128`); today the node has only
  the span of the whole line.
- `visit` (`src/modules.rkt:102`) keeps, per file, the set of aliases used.
  `resolve` marks an alias in its `target` branch, when the lookup at `:157`
  finds it.
- After every file is rewritten (the `append-map` that builds the merged
  `program`, `src/modules.rkt:266`), the linker walks the files in link order
  (the root first) and, in each file, the imports in source order, and fails at
  the first alias that was never marked.
- **A mistyped alias is not an unused import.** In `import Text from "text"`
  with a call `Txet.shout("hi")`, the alias `Text` looks unused, but the real
  mistake is the call. `resolve` sends a two-part function name whose first
  part is not an alias to the checker unchanged, so the checker can report it
  with its stable code (the comment at `src/modules.rkt:169`). So while
  rewriting, `resolve` also records, per file, the two-part function names whose
  first part is not an alias of that file and that are not builtins
  (`builtin-ref`; `IO.inspect` and `String.length` are valid calls of that
  shape). When a file has any, the unused-import check skips that file, and
  the checker reports the call as `CHECK-UNKNOWN-NAME`, as today, with its
  "did you mean" help over functions and builtins.
- **An alias used without its member.** An import alias is never a name on its
  own: the linker already forbids an alias that collides with a declaration of
  the file or a builtin type name (`src/modules.rkt:128`), so a one-part type or
  enum name equal to an alias is always a mistake, most often a missing member.
  Two shapes reach `resolve` as one-part names:
  - a type, construction or type expression: `u: User`, a parameter
    `def show(u: User)`, `User(name: "Ana")` (a `construct`), or `User` alone as
    a value (a `type-expression`), all with `import User from "user"`; these
    come as one-part `'type` names;
  - an enum variant without the enum's name: with `import Domain from "domain"`,
    the call `Domain.Some(1)` and the pattern `Domain.Some(x)`. The parser reads
    them as the variant `Some` of an enum named `Domain`, so they come as
    one-part `'enum` names.

  Today `resolve` treats such a name as a declaration of the file (its last
  branch, `identity`), and the checker reports `CHECK-UNKNOWN-TYPE` (for the
  enum call, "unknown enum") or `CHECK-PATTERN-TYPE` (for the pattern). The
  alias is never marked, so 26.1 alone would add a wrong "remove import" error.
  So when `resolve` gets a one-part `'type` or `'enum` name that is an import
  alias of the file, the linker stops right away with `CHECK-IMPORT-NAME` at
  that span. The help shows the missing member: `write User.<Type>` or
  `write Domain.<Enum>.Some(...)`. When the imported module exports a
  declaration with that name, the help names it (`write User.User`); for a
  variant, when exactly one exported enum has a variant of that name, the help
  names the enum (`write Domain.Option.Some(...)`). This is better than today's
  diagnostics even without the unused-import rule, so it can land in the 16a PR
  as its own small change.
- **Order.** Errors found while rewriting come first: an unknown or private
  imported name (`CHECK-IMPORT-NAME`) in a file is reported before an unused
  import. A mistyped alias in a call is not a rewriting error; it is the
  checker's `CHECK-UNKNOWN-NAME`, and the rule above keeps the unused import
  from hiding it. Apart from that case, every linker error comes before every
  checker error, since the linker runs first.

**Help idea:** `remove import JsonUtil from "json_util"`, which names the whole
line, as in the example above. There is no "use it" hint: the linker cannot know
what the code meant to call.

**Tests** (`tests/modules-test.rkt`): an unused alias in the root (code and the
alias's span); an unused alias in an imported file and in a `std/` import; an
alias used only in a type annotation, only in a pattern, only as `&Alias.f`,
only in a construction, and only in a function that is never called (all valid);
two unused imports (the first is reported); a file imported by two files where
only one uses its own alias; an unknown imported name (`Text.nope()`) and an
unused import in the same file (`CHECK-IMPORT-NAME` wins); a misspelled alias in
a call (`Txet.shout("hi")`) next to the import it was meant to use
(`CHECK-UNKNOWN-NAME` at the call, not `CHECK-UNUSED-IMPORT`); an alias used
without its member, each `CHECK-IMPORT-NAME` at it and not
`CHECK-UNUSED-IMPORT`: an annotation (`u: User`), a parameter type
(`def show(u: User)`) and a construction (`User(name: "Ana")`), with the help
that names `User.User` when the module exports `User` and `User.<Type>` when it
does not, and an enum variant as a value (`Domain.Some(1)`) and as a pattern
(`Domain.Some(x)`), with the help that names `Domain.Option.Some`; a valid
builtin call such as `IO.inspect(x)` next to an unused import (still
`CHECK-UNUSED-IMPORT`); with 15b, a facade that only re-exports. An
`{expect="CHECK-UNUSED-IMPORT"}` block on the modules page, and the CLI check
(`--json`, exit 1, the code).

**Docs:** `grammar.md` ("File modules and imports"), the programming skill
(`references/modules.md`, `references/diagnostics.md`, one line in `SKILL.md`),
`site/content/tour/modules.md`. The PR also checks the examples in `grammar.md`
and `README.md`, so none shows a form this item now rejects.

### 26.2 Unused variables

```agentica
def total(xs: List[Int]) -> Int
  sum = 0
  count = 0
  for x in xs
    sum += x
    count += 1
  end
  return sum
end
```

`count` is only updated, never read, so the program is rejected at `count = 0`,
with the help "remove it, or name it _count if it is unused on purpose".

**Rule:** a local name that is never read is `CHECK-UNUSED-VARIABLE`, unless the
name starts with `_`.

**Which names.**

- **Variables** introduced by an assignment (`x = 1`, `x: Int = 1`). Yes.
- **`for` variables.** Yes: `for i in 0...n` that never reads `i` is written
  `for _ in 0...n` (the discard, below).
- **Block parameters** (and the parameters of standalone lambdas, 25.5). Yes:
  `xs.each_with_index do |_, i| ... end`, `m.each do |_, v| ... end`. A block is
  written at its one call site and its parameter names are private to it, so
  renaming one costs nothing and changes no signature. Ruby's own linters do the
  same (RuboCop's `Lint/UnusedBlockArgument`).
- **Pattern bindings** in `case` arms. Yes: `error(message) -> puts("failed")`
  is written `error(_) -> puts("failed")`. The pattern discard `_` already
  exists (`grammar.md`, `pattern_binding = NAME | "_"`).
- **Function parameters.** Never. A function's parameters are part of its
  signature, which callers, `&name` callbacks and adapters (structs of `Fn`
  fields) depend on; a callback often must take a parameter it does not need.
  `main` has none.
- Struct fields, functions and types are not variables, and are not checked here
  (26.5).

**What "read" means.** A variable is read when its name is evaluated as an
expression anywhere in its scope: in a condition, an argument, an operand, an
interpolation, an index, a `return`, or the value of an assignment to another
variable. A read inside a block (or lambda) counts for the outer variable it
captures, since a block can read captured values but never assign them
(`CHECK-CAPTURED-ASSIGNMENT`).

- **Compound assignment is not a read.** A read of `x` inside the value of an
  assignment to `x` itself does not count: `x += 1`, `x = x + 1` and
  `xs = xs.push(v)` alone do not make `x` or `xs` used. The parser already turns
  `x += 1` into `x = x + 1` (`parse-compound-assignment`, `src/parser.rkt:517`),
  so both forms get the same answer. This holds in nested blocks too: while the
  value of `x = ...` is checked, a read of `x` inside a block in that value does
  not count either, so `xs = xs.map do |v| v + xs.length end` alone leaves `xs`
  unused. The reason: values are immutable, so the only way the new value of `x`
  leaves such an assignment is through a later read of `x`. A counter that is
  only incremented, or a list that is only appended to, is lost work, and
  usually a bug (the result was meant to be printed or returned). Rust warns the
  same way (`variable is assigned to, but never used`). A call in such a value
  still runs; if a loop calls a function with effects only to feed its own state
  (`n = tick(n)`), the name is `_n`.
- **Reassignment before any read.** The rule is per variable, not per
  assignment: `x = 1`, then `x = 2`, then `puts(x)` is valid. The first value is
  never read, but finding that needs a flow analysis of every path; the checker
  does not do one, and Go does not reject it either. A variable is unused only
  when no read of it exists at all.
- **Code that never runs.** A read in a statement after a `return` does not
  count. 26.3 lands before this item, so the checker rejects that statement
  first and the question never comes up.

**`_` names.** Names that start with `_` and have more after it are already
valid: `NAME = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }` (`grammar.md`,
"Literals"; the lexer at `src/lexer.rkt:169`). A variable whose name starts with
`_` (`_count`) is never reported; reading one stays valid. This is the opt-out
for a name kept on purpose, and it is only about this rule; to drop a value, the
discard below is the form.

**The discard `_`.** Decided by the user on 2026-10-12, as Go's `_ =` and Rust's
`let _ =`. Today a bare `_` is the discard only in patterns
(`pattern_binding = NAME | "_"`); everywhere else it is an ordinary variable, so
two nested `for _ in` loops are `CHECK-SHADOWED-NAME`, and `_ = "s"` after
`_ = 3` is `CHECK-TYPE-MISMATCH`. With this item, a bare `_` is the discard in
every place that binds a name:

- **Assignment:** `_ = f(...)` evaluates the value and drops it. `_` binds
  nothing, so it can be assigned any number of times, with values of any type.
  An annotation (`_: Int = x`) is `PARSE-UNEXPECTED-TOKEN` with the help
  `write _ = x`, since a discard has no type to declare. A `Void` value is still
  `CHECK-VOID-VALUE`, as for any assignment: there is nothing to drop. `_ =` is
  accepted for every type, not only for a `Result`, because a discard is equally
  explicit for every value.
- **`for` variable and block parameter:** `for _ in 0...n` and `do |_, v|` bind
  nothing, like `_` in a pattern, so `|_, _|` and nested `for _` loops are
  valid. A block parameter `_` may keep an annotation (`|_: Int|`), which is
  part of the block's type.
- **Reading `_`** as a value is `CHECK-UNKNOWN-NAME`, at the `_`, with the help
  `_ discards a value and cannot be read; give the value a name`. No new code is
  needed: `_` is never a visible name. `_ += 1` reads `_` (it means
  `_ = _ + 1`), so it gets the same error.
- **Grammar:** the EBNF does not change (`_` is already a `NAME`); `grammar.md`
  "Variables and scope" gets the meaning of `_`, and "Statements and blocks" and
  "Blocks and closures" its use in `for` and block parameters. **Parser:**
  `parse-binding` (`src/parser.rkt:506`) rejects the annotation. **Checker:**
  `check-binding`, `check-for` and `check-block-body` do not introduce `_`.
  **Lowering:** `_ = e` lowers as the expression statement `e`, and a `_` loop
  variable or block parameter gets a slot that nothing reads.
- **What breaks:** a program that reads a `_` variable, or gives `_` an
  annotation. The scan (the impact list) found neither; it found three
  `for _ in` loops (`tests/fixtures/vm/random.agc`), which stay valid as
  discards. Two nested `for _` loops and `|_, _|`, `CHECK-SHADOWED-NAME` today,
  become valid.

**Discarding a value.** `sent = TCP.send(socket, text, 1000)` with `sent` never
read is reported. The help depends on the value's type. For a `Result`, it shows
the forms of 26.4 that handle it (`try`, a `case`, `.unwrap!`) or the discard
`_ = TCP.send(...)`; it never suggests the bare call as a statement, which 26.4
rejects and which would drop the error. For any other value, it suggests
removing the assignment (keeping the call as a statement when the call has
effects) or using the value. The site's network and process examples, which
assign a `Result` from `send` or `close` and never look at it (the impact list),
show why the help matters.

**Span and order.** The span is where the variable is introduced: the assignment
statement that introduces it (the span `CHECK-SHADOWED-NAME` uses today), the
block parameter (`block-param` has a span), the `for` variable or the pattern
binding. The last two have no span of their own today, so `for-stmt`
(`src/ast.rkt:72`) gains a `var-span` field and `variant-pattern`
(`src/ast.rkt:78`) a `binding-spans` field (one span per binding, `_` included),
filled by the parser (`src/parser.rkt:582`, `:351`, `:387`). `bindings` stays a
list of names, with `#f` for `_`, so readers such as `src/lower.rkt` keep
working; the positional `match` patterns in `rewrite` (`src/modules.rkt:214`,
`:247`) gain the field. The check runs at the end of each function
(`check-function`, `src/checker.rkt:1533`), after its body is checked and after
its `CHECK-MISSING-RETURN` check, so every other error in the function comes
first, including the `CHECK-MISSING-RETURN` of the blocks inside it
(`check-block-body`, `:1207`), which runs when each block ends. It reports the
unused name whose span starts first in the source (by source offset), not the
one introduced first: in `ys = xs.map do |v| 1 end`, the block parameter `v` is
introduced before `ys` (the value is checked before the name is introduced), but
`ys` starts first, so `ys` is reported. Functions are checked in the linked
program's order.

**Implementation sketch** (`src/checker.rkt`):

- The scope entries stay as they are (`(type . immutable?)`, made by
  `introduce!` at `:340`), since every `lookup` caller reads them with `car` and
  `cdr` (`introduce!` at `:342`, the `name-ref` branch at `:475`,
  `check-binding` at `:1463`). A side table keyed by the entry (a `hasheq`; each
  `introduce!` makes a new pair) holds its kind (variable, `for`, block
  parameter, pattern, parameter), its span and a read flag, so the change stays
  local. The function keeps a list of the entries it introduced.
- The `name-ref` branch of `check-expression` (`:474`) sets the read flag of the
  entry it finds, in the side table, unless that entry is one of the targets of
  the assignments being checked. `check-binding` (`:1458`) adds its target to
  that set while it checks the value of an assignment to an existing variable,
  and removes it afterwards. It is a set (or a stack), not one slot, so an
  assignment nested in a block inside the value does not drop the outer target:
  in `xs = xs.map do |v| acc = 0; acc = acc + xs.length; acc end` (one statement
  per line), the read of `xs` inside the block still does not count.
- `check-function` (`:1533`) sorts the list by the start offset of each span at
  the end and fails at the first entry that is not a parameter, has no read and
  does not start with `_`.

**Help ideas**, by kind:

- variable:
  `"count" is never read; remove it, or name it _count if it is unused on purpose`;
  when it is only updated: `"count" is only updated (count += 1), never read`;
  when the value is a `Result`:
  `handle the Result: try ..., a case on ok(_) and error(message), or .unwrap!; or discard it with _ = TCP.send(...)`;
  when the value is anything else and a call with effects:
  `keep the call as a statement`.
- `for` variable: `write for _ in 0...n`.
- block parameter: `write |_, i|`.
- pattern binding: `write error(_) to match without binding the value` (the
  wording of today's help for an empty pattern, `src/parser.rkt:350`).

**Tests** (`tests/checker-test.rkt`): each kind, with its span; a variable read
only inside a block (valid); `x += 1` alone, `x = x + 1` alone,
`xs = xs.push(1)` alone, `xs = xs.map do |v| v + xs.length end` alone, and the
nested `xs = xs.map do |v| acc = 0; acc = acc + xs.length; acc end` alone (all
reported for `xs`); `x = 1`, `x = 2`, `puts(x)` (valid); `_x`, `for _ in`,
`|_, v|`, `error(_)` (valid); the discard: `_ = f()` twice with values of two
types, nested `for _` loops and `|_, _|` (valid), reading `_`
(`CHECK-UNKNOWN-NAME` with its help), `_ += 1` (`CHECK-UNKNOWN-NAME`),
`_: Int = 1` (`PARSE-UNEXPECTED-TOKEN`, in `tests/parser-test.rkt`),
`_ = puts("x")` (`CHECK-VOID-VALUE`); an unused parameter of a function and of a
callback passed as `&name` (valid); two unused names in one function (the first
in the source is reported), and `ys = xs.map do |v| 1 end` (`ys` is reported,
not `v`); `sent = TCP.send(...)` unused (the help shows the `Result` forms, not
a bare call); a type error after an unused variable in the same function (the
type error wins); an unused variable in a function that also misses a return
(`CHECK-MISSING-RETURN` wins), and the same inside a block. An
`{expect="CHECK-UNUSED-VARIABLE"}` block on the variables page, and the CLI
check.

**Docs:** `grammar.md` ("Variables and scope": the rule, the discard `_`, `_`
names and what a read is; "Statements and blocks" for `for _`; "Enums and
pattern matching" and "Blocks and closures" for `_` and `|_, v|`), the
programming skill (`SKILL.md` and `references/diagnostics.md`), `grammar.md`
"Methods on builtin types" (its `xs = xs.push(2)` example must then use `xs`),
`site/content/tour/variables.md`, `control-flow.md` (`for _`), `blocks.md` and
`enums-and-case.md`. The PR also checks the examples in `grammar.md` and
`README.md`, so none shows a form this item now rejects.

### 26.3 Unreachable code

```agentica
def sign(n: Int) -> String
  if n < 0
    return "negative"
  else
    return "not negative"
  end
  puts("done")
end
```

`puts("done")` can never run, so it is `CHECK-UNREACHABLE-CODE` at that
statement, with a secondary span on the `if`: "every branch returns here". Today
the checker accepts it.

**Rule:** a statement that follows a terminator in the same block is
`CHECK-UNREACHABLE-CODE`, at the first such statement.

This is a new code, apart from the existing `CHECK-UNREACHABLE-CASE-ARM` (a
`case` arm that an earlier arm already covers, `src/checker.rkt:1332`), which
does not change.

**Terminators**, kept to what the checker already knows:

- `return`, `break` and `next`;
- an `if` with an `else` whose every branch ends in a terminator, and a `case`
  whose every arm ends in a terminator (any mix: one arm may `return` and
  another `break`).

That is the same idea as the "must return on every path" rule (`returns?`,
`src/checker.rkt:194`, behind `CHECK-MISSING-RETURN`), widened from `return` to
`break` and `next`, since those end a block too. Like that rule, the analysis
does not look into loops or calls. These are not terminators:

- `System.exit(...)` and calls that can halt (`gets!`, `unwrap!`, any `!`
  function): to the checker they are calls with a type, and it has no "never
  returns" type. A `-> Int` function that ends with `System.exit(1)` still needs
  a `return` after it today, so treating the call as a terminator would make the
  two rules disagree.
- `while true ... end` without a `break`: `grammar.md` says "a loop does not by
  itself guarantee a return", and the same holds here.
- `try`, which leaves early only on an error.

Branches inside a block are checked as their own blocks: `if c` with a `return`
and no `else` is not a terminator, but a statement after the `return` inside
that branch is unreachable.

**Where.** In the checker, because the rule needs the block structure that it
already walks and the same "ends on every path" logic as `returns?`; the linker
does not look at statements. `check-block` (`src/checker.rkt:1404`) and the
statement loop of `check-block-body` (`:1207`, for blocks and lambdas) check
each statement, then, before the next one, fail if the one just checked is a
terminator. So errors before the terminator come first, and the unreachable
statement itself is not checked.

**Today.** The checker accepts code after a `return`, a `break` or an exhaustive
`if`/`case`: `block-returns?` (`src/checker.rkt:191`) is true when any statement
of the block returns, wherever it is. After this item a terminator can only be
the last statement of its block, so `block-returns?` may look at the last
statement only; that is a simplification, not a change in behavior.
`contains-return?` (`:153`) stays a deep search: `missing-return-help` (`:168`)
uses it to tell "no `return` anywhere" apart from "a `return` on some paths
only", and that question is about returns nested anywhere in the body.

**Help idea:**
`this statement never runs, because the block ends at the return on line 5; remove it, or move it before the return`.
For a `case` or `if`:
`every branch of the case above ends with return, break or next`.

**Tests** (`tests/checker-test.rkt`): a statement after `return`, `break` and
`next` (code and span); after an `if`/`else` that returns in every branch, after
a `case` whose arms mix `return` and `break`, and inside a block (`return`
leaves the block); valid: after an `if` without `else`, after `System.exit(0)`,
after `while true` without `break`, after a `try`; two unreachable statements
(the first is reported); a type error before the `return` (the type error wins).
An `{expect="CHECK-UNREACHABLE-CODE"}` block on the control-flow page, and the
CLI check.

**Docs:** `grammar.md` ("Statements and blocks" and "Functions and entry
point"), the programming skill (`SKILL.md` and `references/diagnostics.md`),
`site/content/tour/control-flow.md` and `functions.md`. The PR also checks the
examples in `grammar.md` and `README.md`, so none shows a form this item now
rejects.

### 26.4 Ignored `Result` values

```agentica
def save(path: String, text: String) -> Result[Void]
  File.write_text(path, text, 1000)
  return ok()
end
```

The write can fail, but its `Result` is dropped, so the error is lost. This is
`CHECK-UNUSED-RESULT` at the call, with the help
`handle the Result: try File.write_text(...), a case on ok(_) and error(message), or .unwrap!; or discard it with _ = File.write_text(...)`.

**Rule:** an expression whose value is dropped, that is an expression statement
or the last statement of a `Void` block, and whose type is `Result[...]`, is
`CHECK-UNUSED-RESULT` at the expression. It does not matter who made the
`Result`: a builtin with effects (`File.close`, `File.write_text`, `TCP.send`,
`HTTP.respond`, `Process.close_stdin`, `Process.wait`, ...), a user function, a
method, or `Task.await` on a task that returns a `Result`. The one exception is
`IO.inspect`, which prints its argument and returns it, so nothing is lost (the
scan found 188 such statements, all printing a `Result` on purpose).

**Why.** Builtins with effects are exempt from `CHECK-UNUSED-VALUE`
(`grammar.md`, "Methods on builtin types"), and most of them return a `Result`.
So today a statement such as `File.close(f, 1000)` compiles and drops its error
with no trace. That is the one place where the language lets an error pass
silently; under the strictness principle it becomes an error. Ignoring a
`Result` on purpose stays possible, but it must be visible.

**How to handle it** (the help shows these, in this order):

- `try f(...)` in a function that returns a `Result`. `try` unwraps the value,
  so the statement's value is the success payload, not a `Result`, and it is not
  reported. This is valid today: `try File.write_text(...)` (a `Result[Void]`,
  so the statement is `Void`) and `try "6".to_i` as a statement both check.
- a `case` with `ok(_)` and `error(message)` arms, to act on the error;
- `.unwrap!` where halting the run on an error is fine;
- the one explicit discard, `_ = File.write_text(...)` (26.2). It keeps the drop
  visible in the code, so a reader sees that the error is dropped on purpose.
  The helps never suggest a named variable such as `_written = ...`; a `_name`
  is only the opt-out of 26.2 for a name kept on purpose.

**Where.** In the checker, in `check-unused-value!` (`src/checker.rkt:1430`),
which every dropped expression already passes through (expression statements in
`check-statement`, and the last statement of a `Void` block in
`check-block-body`), with its type. The new check runs before the
`CHECK-UNUSED-VALUE` one. No other stage changes.

**Help idea:** as above, with the call's own text in the `try` and `_ =` forms.
`CHECK-UNUSED-VALUE` (a bare `xs.push(2)`) stays as it is. Since this check runs
first, `CHECK-UNUSED-VALUE` only ever sees values that are not a `Result` (a
pure builtin such as `s.to_i` gives `CHECK-UNUSED-RESULT`), so its help keeps
saying to assign or use the result and never suggests `_ =`.

**Tests** (`tests/checker-test.rkt`): a dropped `Result` from a builtin with
effects, from a user function, from a method and from `Task.await` (code and
span); the last statement of a `Void` block
(`xs.each do |x| File.close(...) end`); valid: `try f(...)` as a statement
(`Result[Void]` and `Result[Int]`), a `case`, `.unwrap!`, `_ = f(...)`,
`IO.inspect(r)`, a `Result` that is the value of a block whose expected result
is a `Result`. An `{expect="CHECK-UNUSED-RESULT"}` block on the results page,
and the CLI check.

**Docs:** `grammar.md` ("Result and propagation", and "Methods on builtin
types", whose exemption for builtins with effects no longer covers a `Result`),
the programming skill (`SKILL.md` and `references/diagnostics.md`),
`site/content/tour/results-and-try.md` and the library pages whose examples drop
a `Result` (`files.md`, `network.md`, `process.md`). The PR also checks the
examples in `grammar.md` and `README.md`, so none shows a form this item now
rejects.

### 26.5 Not here

These are not planned. Each one would need its own decision against the
principle above:

- **Dead stores** (a value overwritten before it is read): they need a flow
  analysis (26.2).
- **Unused function parameters:** signatures are fixed by callers and adapters
  (26.2).
- **Unused private functions, types, struct fields and enum variants:** they
  need a whole-file analysis, and a library file may keep a private helper on
  purpose. Not decided.
- **Ignored results:** decided. A dropped value of a builtin without effects is
  already `CHECK-UNUSED-VALUE`; a dropped `Result`, from any call, is
  `CHECK-UNUSED-RESULT` (26.4). Other dropped values of calls with effects or of
  user functions (an `Int` from a user function) stay valid: the call is made
  for its effect, and there is no error to lose.
- **Dropped tasks:** decided. A bare `Task.spawn(&save, x)` statement stays
  valid even when `save` returns a `Result`: its type is `Task[...]`, and
  `Task.spawn` is a call with effects. The task's error is lost only if no one
  awaits it, and a named handle that is never awaited is already
  `CHECK-UNUSED-VARIABLE` (26.2). A rule on a dropped `Task[Result[...]]` would
  reject the fire-and-forget form that 26.2 leaves on purpose.
- **Style lints** (naming, line length, layout): never. The grammar and the
  one-way hints already fix the form.

### Impact on existing code (counts as of 2026-10-12, master 12df0f8)

A scan of the repo found what the table shows. It was a throwaway script on the
real lexer, parser, linker and checker: it applies the four rules to every node
of the AST (interpolation parts included), and counts a hit only when the
program passes today or when its present error would come after the new one (a
test that expects an earlier error is not affected). It read the `.agc` files of
`examples/`, `stdlib/`, `benchmarks/` and `tests/`, the `agentica` blocks of
`site/content`, the examples of the programming skill, and the Agentica programs
written inline in the Racket tests: string literals, and the `check-ok` programs
of `tests/checker-test.rkt` that its `main-with` helper builds. For 26.4 it used
a copy of the checker that records every dropped `Result` instead of stopping;
it read the same sources, except the inline programs that import other inline
files, and three `site/content/tour/modules.md` blocks that import other blocks
(read by hand: none drops a `Result`). It does not replace running `make test`
in each PR.

Files that land after this scan and before phase 16 must be counted again by
each PR: the programs of phase 17 (order step 7.3 for `Task.map` and row 7.2.1e
for channels, [section
27](27-iteration-and-concurrency.md#27-iteration-and-concurrent-collections)),
with their golden fixtures, checker tests, `tests/test_vm_task_map.py` and site
pages; the programs of HTTP streaming and `TlsContext` (order step 7.4); and the
`std/` modules of order row 7.2.4 (`std/binary`, phase 13) and of order step 7.5
(`std/logger`, 14c), with their site pages and tests; they matter to 26.1, 26.2
and 26.4.

| Where | 26.1 imports | 26.2 variables | 26.3 unreachable | 26.4 results |
|---|---|---|---|---|
| `examples/` (26 files), `stdlib/` | 0 | 0 | 0 | 3 in 2 files (`http_server.agc`: `HTTP.respond` twice; `tcp_echo.agc`: `TCP.send`) |
| `benchmarks/programs/` | 0 | 1 (`error(message)` in `string-library.agc`) | 0 | 0 |
| `tests/fixtures/` (`.agc`) | 0 | 35 in 22 files | 1 (`vm/calls.agc`, a statement after `return`) | 8 in 4 files (`vm/files-large.agc` 3, `files-errors.agc` 2, `files-handles.agc` 2, `files-text.agc` 1: `File.close`, `File.write_text`, `File.write_bytes`) |
| `tests/bdd/handlers.agc` | 0 | 1 (`invalid = 1 / 0`, a handler that crashes on purpose) | 0 | 0 |
| `site/content` blocks | 0 | 17 blocks on 7 pages (`library/io-and-system/network.md` 7, `process.md` 3, `files.md` 3, `io.md`, `library/data-structures/range.md`, `library/concurrency/task.md`, `tour/results-and-try.md`) | 0 | 0 |
| Programming skill examples | 0 | 0 | 0 | 0 |
| Bare `_` used as a variable (all of the sources above) | | 0 breaks: no `_ =`, no read of `_`, no `_` block parameter; 3 `for _ in` loops in `tests/fixtures/vm/random.agc`, which stay valid as discards | | |
| Inline programs in Racket tests, before 7i | 1 (`tests/modules-test.rkt:207`) | 36: 24 in `checker-test.rkt` (23 of the 33 `check-ok` programs the scan could read, and one more), 6 in `bytecode-test.rkt`, 2 in `bdd-integration.rkt` (now `test_bdd_integration.py`), 1 each in `modules-test.rkt` (`:208`), `examples-test.rkt` (now `test_examples.py`), `task-test.rkt` and `vm-diff-common.rkt` | 0 | 1 (a `check-ok` program in `checker-test.rkt` that drops `HTTP.respond`) |

The inline counts are for the tests as they are before 7i. 7i deletes the
evaluator and the tests that only exercise it, so the implementing PRs, which
come after 7i, will find the same number or fewer.

What the hits are, and their fix:

- **Variables.** Most are tasks spawned and never awaited
  (`t = Task.spawn(...)`), values computed to test a step limit or preemption
  (`x += 1` in `while true`, 5 hits that only the compound-assignment rule
  finds), unused `for` and block variables in fixtures, and, on the site,
  `Result` values of `TCP.send`, `Process.send`, `Process.close_stdin` and
  `Process.wait` assigned and never read. The fix is the discard `_` (`for _`,
  `|_, v|`, `error(_)`), a `_name`, a bare call statement (only for a value that
  is not a `Result`), or using the value; the site's `Result` values get a 26.4
  handling form or `_ = ...`. The `checker-test.rkt` programs mostly introduce a
  variable only to check its type (`x: Int = i`); they get `_x` names or a
  `puts`. In `tests/modules-test.rkt:208`, `funcs.agc` assigns `n = C.go()` and
  never reads it; its `main` is checked before the imported file's error that
  the test expects, so the PR uses `n`.
- **The one unreachable statement** is the golden fixture
  `tests/fixtures/vm/calls.agc`, which checks that code after `return` does not
  run; the PR removes that line and the new checker test covers the case. (A
  program in `tests/parser-test.rkt` also has a statement after `return`, but
  parser tests never run the checker.)
- **The one unused import** is in `tests/modules-test.rkt:207`: `types.agc`
  imports `bad.agc` as `B` and never uses it, and the test expects
  `CHECK-UNKNOWN-TYPE` from `bad.agc`. Under 26.1 the linker would stop first
  with `CHECK-UNUSED-IMPORT`. The PR gives `B` a use (for example a parameter of
  type `B.Pair`, once `Pair` is exported), so the test keeps checking that a
  checker error in an imported file is reported in that file. The other module
  tests with an unused alias fail earlier in the linker (missing file, bad path,
  duplicate or reserved alias, import cycle) and are not affected.
- **Ignored results.** All 12 are calls with effects used as statements:
  `File.close`, `File.write_text` and `File.write_bytes` in the file fixtures,
  and `HTTP.respond` and `TCP.send` in two examples and one checker test. The
  fixtures that test error cases on purpose use a `case` or `_ = ...`; the
  others use `try` or `.unwrap!`. The 188 `IO.inspect` statements on a `Result`
  are not hits (the exception above).
- `tests/eval/tasks/t5-scope-return/start.agc` has an unused `last`, but it is
  broken on purpose (agents fix it) and fails earlier with
  `CHECK-MISSING-RETURN`; it needs no edit.
- `{expect="..."}` site blocks that fail earlier with another checker code are
  not affected; `tour/results-and-try.md`'s `RUNTIME-UNWRAP-ERROR` block is,
  since a check error now comes before the run.

So 26.2 is the large migration (about 30 program and test files, and 17 site
blocks on 7 pages); 26.1 and 26.3 touch one test or fixture each; 26.4 touches 6
files and one inline test. Each count goes in its PR description.
