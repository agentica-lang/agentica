## 26. Strict diagnostics

**Status:** planned (roadmap phase 16), after 7i deletes the evaluator (order 7.2), as the first items of order step 7.4, before the phase 15 items of that step. Decided by the user on 2026-10-12.

This section adds three errors that other languages give as warnings: an unused import, an unused variable and unreachable code. The checks are small and need no new syntax; the decision behind them is the principle below.

**Principle: no warnings.** Agentica has no warnings, by design, as in Go: a diagnostic is an error or it does not exist. There are three reasons:

1. **Agents ignore warnings.** An LLM agent reads the exit code and the first error. A warning does not stop the run, so the agent does not fix it, and the mistake stays in the code.
2. **A warning means "wrong, but allowed".** That is a second accepted way to write the code, against the one-way rule of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): if a form is wrong, the language rejects it; if it is right, the language says nothing.
3. **One diagnostic per stage.** Each stage returns its output or exactly one diagnostic, and stops at the first error (`AGENTS.md`, "Conventions"). The diagnostic format has only `error` (`src/diagnostic.rkt`). Warnings would need a list of diagnostics next to a successful result, which breaks that contract for every stage and for `--json`.

So a new check is either an error with a stable code or it is not added. A check becomes an error only when the case is almost always a mistake and the fix is local and mechanical (remove a line, or rename to a `_` name). Checks that fail this test are not added (26.4).

**Deprecations.** Deprecation warnings may be considered only after 1.0, when there are users whose code must keep working while they move. Before 1.0, a change in behavior is a breaking change: it lands as an error, the implementing PR migrates the repo, and the `CHANGELOG.md` lists it under "Changed".

**No switch to turn them off.** There is no flag such as `--allow-unused`: a check that can be turned off is a warning by another name, and it would give two accepted ways again. A name that starts with `_` is the one way to say "unused on purpose" (26.2).

**How it lands.**

- Each item is its own small PR, after 7i (order 7.2), so the Racket evaluator and its tests are gone and need no migration. All three are front end only: the linker (`src/modules.rkt`) for 26.1, the checker (`src/checker.rkt`) for 26.2 and 26.3. `src/lower.rkt`, the bytecode format and the VM do not change.
- Each PR is a breaking change and migrates the repo in the same PR: the programs in `examples/`, `stdlib/`, `benchmarks/`, `tests/` (the `.agc` fixtures and the Agentica programs written inline in the Racket tests), the `agentica` blocks of `site/content`, and the examples of the programming skill. The impact list at the end of this section says what each item breaks today. The `CHANGELOG.md` gets one "Changed" entry per item.
- **Tests** in each PR: checker or linker tests that assert the code and the span (`tests/checker-test.rkt`, `tests/modules-test.rkt`), never the message text; a golden fixture per code (`tests/fixtures/vm/*.expected` records the diagnostic code); and an `{expect="CODE"}` site example.
- **Docs** in each PR: `docs/grammar.md` (the rule, and §7 "Diagnostics for agents" gets the no-warnings principle with whichever item lands first), the programming skill (`references/diagnostics.md` for the code, and one line in `SKILL.md`, since these rules apply to every program), the matching site page, and the development skill's notes. When an item lands, its text moves to `grammar.md` and is deleted here.

| § | Item | Stage | New diagnostic code |
|---|---|---|---|
| 26.1 | Unused imports | linker (`src/modules.rkt`) | `CHECK-UNUSED-IMPORT` |
| 26.2 | Unused variables | checker (`src/checker.rkt`) | `CHECK-UNUSED-VARIABLE` |
| 26.3 | Unreachable code | checker (`src/checker.rkt`) | `CHECK-UNREACHABLE-CODE` |

The codes keep the `CHECK-` prefix, also for the linker's code, as the linker's other codes do (`CHECK-IMPORT-NAME`, `CHECK-IMPORT-CYCLE`).

### 26.1 Unused imports

```agentica
import "text.agc" as Text
import "json_util.agc" as JsonUtil

def main() -> Void
  puts(Text.shout("hi"))
end
```

`JsonUtil` is never used, so the program is rejected:

```text
app.agc:2:27 error[CHECK-UNUSED-IMPORT]
the import alias "JsonUtil" is never used

2 | import "json_util.agc" as JsonUtil
  |                           ^^^^^^^^
  = help: remove this import
```

**Rule:** an import whose alias is never used in its file is `CHECK-UNUSED-IMPORT`, at the alias.

**Why the linker.** The linker is the only stage that sees import aliases. It resolves every `Alias.name` of a file through that file's imports (`resolve`, `src/modules.rkt:151`) and rewrites it to the target's identity (`@N::name`); the checker then gets one merged program with no imports left, and rejects any import it finds (`CHECK-MODULE-CONTEXT`, `src/checker.rkt:1562`). So the checker cannot tell which alias a name came from, and the linker must decide.

**What counts as a use.** Every place where `resolve` finds the alias in the file's imports (`(hash-ref (hash-ref imports key) alias)`), for any kind of name: a call (`Text.shout(...)`, also without parentheses), a function value (`&Text.shout`), a type in an annotation, a parameter, a field or a JSON type argument (`Models.User`), a construction (`Models.User(name: "Ana")`), an enum variant as a value or a pattern (`Domain.Option.Some(x)`), and an enum type (`Domain.Option[Int]`). A use inside a function that is never called still counts: the rule is about the file's text, not about what runs.

**Re-exports** ([section 25.2](25-ruby-typed-idioms.md#252-re-exports), roadmap 15b): `export Url.parse` counts as a use of `Url`. A facade file that only re-exports is the main use of re-exports, and it must not need a fake call to keep its imports. 15b lands after this item (both at order step 7.4), so 15b marks the alias as used when it resolves a re-export, and its tests include a facade that only re-exports.

**No side effects to keep.** An import has no effect besides its names: a module has no top-level statements and no module state (`grammar.md`, "File modules and imports"). So removing an unused import never changes what a program does.

**Every module.** The rule holds for every linked file: the root, relative imports, `pkg/` libraries and the embedded `std/` modules. Each file is checked against its own imports, once, even when several files import it.

**Implementation sketch:**

- `import-decl` (`src/ast.rkt:54`) gains an `alias-span` field, filled by the parser from the alias token (`src/parser.rkt:128`); today the node has only the span of the whole line.
- `visit` (`src/modules.rkt:102`) keeps, per file, the set of aliases used. `resolve` marks an alias when it finds it.
- After every file is rewritten (the `append-map` that builds the merged `program`, `src/modules.rkt:265`), the linker walks the files in link order (the root first) and, in each file, the imports in source order, and fails at the first alias that was never marked.
- Errors found while rewriting come first (an unknown name in a file is reported before an unused import), and every linker error comes before every checker error, since the linker runs first.

**Help idea:** "remove this import" (the help names the line: `remove import "json_util.agc" as JsonUtil`). There is no "use it" hint: the linker cannot know what the code meant to call.

**Tests** (`tests/modules-test.rkt`): an unused alias in the root (code and the alias's span); an unused alias in an imported file and in a `std/` import; an alias used only in a type annotation, only in a pattern, only as `&Alias.f`, only in a construction, and only in a function that is never called (all valid); two unused imports (the first is reported); a file imported by two files where only one uses its own alias; an unknown name and an unused import in the same file (the unknown name wins); with 15b, a facade that only re-exports. A golden fixture and an `{expect="CHECK-UNUSED-IMPORT"}` block on the modules page.

**Docs:** `grammar.md` ("File modules and imports"), the programming skill (`references/modules.md`, `references/diagnostics.md`, one line in `SKILL.md`), `site/content/tour/modules.md`.

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

`count` is only updated, never read, so the program is rejected at `count = 0`, with the help "remove it, or name it _count if it is unused on purpose".

**Rule:** a local name that is never read is `CHECK-UNUSED-VARIABLE`, unless the name starts with `_`.

**Which names.**

- **Variables** introduced by an assignment (`x = 1`, `x: Int = 1`). Yes.
- **`for` variables.** Yes: `for i in 0...n` that never reads `i` is written `for _i in 0...n`.
- **Block parameters** (and the parameters of standalone lambdas, 25.5). Yes: `xs.each_with_index do |_x, i| ... end`, `m.each do |_k, v| ... end`. A block is written at its one call site and its parameter names are private to it, so renaming one costs nothing and changes no signature. Ruby's own linters do the same (RuboCop's `Lint/UnusedBlockArgument`).
- **Pattern bindings** in `case` arms. Yes: `error(message) -> puts("failed")` is written `error(_) -> puts("failed")`. The pattern discard `_` already exists (`grammar.md`, `pattern_binding = NAME | "_"`).
- **Function parameters.** Never. A function's parameters are part of its signature, which callers, `&name` callbacks and adapters (structs of `Fn` fields) depend on; a callback often must take a parameter it does not need. `main` has none.
- Struct fields, functions and types are not variables, and are not checked here (26.4).

**What "read" means.** A variable is read when its name is evaluated as an expression anywhere in its scope: in a condition, an argument, an operand, an interpolation, an index, a `return`, or the value of an assignment to another variable. A read inside a block (or lambda) counts for the outer variable it captures, since a block can read captured values but never assign them (`CHECK-CAPTURED-ASSIGNMENT`).

- **Compound assignment is not a read.** A read of `x` inside the value of an assignment to `x` itself does not count: `x += 1`, `x = x + 1` and `xs = xs.push(v)` alone do not make `x` or `xs` used. The parser already turns `x += 1` into `x = x + 1` (`parse-compound-assignment`, `src/parser.rkt:517`), so both forms get the same answer. The reason: values are immutable, so the only way the new value of `x` leaves such an assignment is through a later read of `x`. A counter that is only incremented, or a list that is only appended to, is lost work, and usually a bug (the result was meant to be printed or returned). Rust warns the same way (`variable is assigned to, but never used`). A call in such a value still runs; if a loop calls a function with effects only to feed its own state (`n = tick(n)`), the name is `_n`.
- **Reassignment before any read.** The rule is per variable, not per assignment: `x = 1`, then `x = 2`, then `puts(x)` is valid. The first value is never read, but finding that needs a flow analysis of every path; the checker does not do one, and Go does not reject it either. A variable is unused only when no read of it exists at all.
- **Code that never runs.** A read in a statement after a `return` does not exist for the checker, since 26.3 rejects that statement first.

**`_` names.** Names that start with `_` are already valid: `NAME = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }` (`grammar.md`, "Literals"; the lexer at `src/lexer.rkt:169`). So the rule needs no grammar change. A name that starts with `_` is never reported; reading one stays valid. Outside patterns, `_` alone is an ordinary name today: two nested `for _ in` loops are `CHECK-SHADOWED-NAME`, and a second `_ = "s"` after `_ = 3` is `CHECK-TYPE-MISMATCH`, because it is the same variable. That does not change here, so the help suggests a `_name` (`_i`, `_k`), not `_` alone, except in patterns, where `_` is the discard. Making `_` a discard everywhere would be a grammar change; it is not part of this item.

**Discarding a call's value.** `sent = TCP.send(socket, text, 1000)` with `sent` never read is reported. When the value is a call whose result may be ignored (a user function, or a builtin with effects, which `CHECK-UNUSED-VALUE` does not flag), the help shows the call as a statement, without `sent =`. Two cases found in the repo (the impact list) show why this matters: the site's network and process examples assign a `Result` from `send` or `close` and never look at it.

**Span and order.** The span is where the variable is introduced: the assignment statement that introduces it (the span `CHECK-SHADOWED-NAME` uses today), the block parameter (`block-param` has a span), the `for` variable or the pattern binding. The last two have no span of their own today, so `for-stmt` (`src/ast.rkt:72`) gains a `var-span` field and `variant-pattern` (`src/ast.rkt:78`) a `binding-spans` field (one span per binding, `_` included), filled by the parser (`src/parser.rkt:582`, `:351`, `:387`). `bindings` stays a list of names, so readers such as `src/lower.rkt` keep working; the positional `match` patterns in `rewrite` (`src/modules.rkt:214`, `:247`) gain the field. The check runs at the end of each function, after its body is checked, so every other error in the function comes first; it reports the unused name that is introduced first in the source. Functions are checked in the linked program's order.

**Implementation sketch** (`src/checker.rkt`):

- A scope entry (today `(type . immutable?)`, set by `introduce!` at `:340`) also records its kind (variable, `for`, block parameter, pattern, parameter), its span, and a read flag. The function keeps a list of the entries it introduced.
- The `name-ref` branch of `check-expression` (`:474`) sets the read flag of the entry it finds, unless that entry is the target of the assignment being checked. `check-binding` (`:1458`) sets that target while it checks the value of an assignment to an existing variable, and restores the previous one afterwards.
- `check-function` (`:1533`) walks the list at the end and fails at the first entry, in source order, that is not a parameter, has no read and does not start with `_`.

**Help ideas**, by kind:

- variable: `"count" is never read; remove it, or name it _count if it is unused on purpose`; when it is only updated: `"count" is only updated (count += 1), never read`; when the value is a call that may stand alone: `keep the call as a statement: TCP.send(socket, text, 1000)`.
- `for` variable: `write for _i in 0...n`.
- block parameter: `write |_x, i|`.
- pattern binding: `write error(_) to match without binding the value` (the wording of today's help for an empty pattern, `src/parser.rkt:350`).

**Tests** (`tests/checker-test.rkt`): each kind, with its span; a variable read only inside a block (valid); `x += 1` alone, `x = x + 1` alone and `xs = xs.push(1)` alone (all reported); `x = 1`, `x = 2`, `puts(x)` (valid); `_x`, `for _i`, `|_k, v|`, `error(_)` (valid); an unused parameter of a function and of a callback passed as `&name` (valid); two unused names in one function (the first in the source is reported); a type error after an unused variable in the same function (the type error wins). A golden fixture and an `{expect="CHECK-UNUSED-VARIABLE"}` block on the variables page.

**Docs:** `grammar.md` ("Variables and scope": the rule, `_` names and what a read is; "Enums and pattern matching" and "Blocks and closures" for `_` and `|_x|`), the programming skill (`SKILL.md` and `references/diagnostics.md`), `site/content/tour/variables.md`, `control-flow.md` (`for _i`), `blocks.md` and `enums-and-case.md`.

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

`puts("done")` can never run, so it is `CHECK-UNREACHABLE-CODE` at that statement, with a secondary span on the `if`: "every branch returns here". Today the checker accepts it.

**Rule:** a statement that follows a terminator in the same block is `CHECK-UNREACHABLE-CODE`, at the first such statement.

**Terminators**, kept to what the checker already knows:

- `return`, `break` and `next`;
- an `if` with an `else` whose every branch ends in a terminator, and a `case` whose every arm ends in a terminator (any mix: one arm may `return` and another `break`).

That is the same idea as the "must return on every path" rule (`returns?`, `src/checker.rkt:194`, behind `CHECK-MISSING-RETURN`), widened from `return` to `break` and `next`, since those end a block too. Like that rule, the analysis does not look into loops or calls. These are not terminators:

- `System.exit(...)` and calls that can halt (`gets!`, `unwrap!`, any `!` function): to the checker they are calls with a type, and it has no "never returns" type. A `-> Int` function that ends with `System.exit(1)` still needs a `return` after it today, so treating the call as a terminator would make the two rules disagree.
- `while true ... end` without a `break`: `grammar.md` says "a loop does not by itself guarantee a return", and the same holds here.
- `try`, which leaves early only on an error.

Branches inside a block are checked as their own blocks: `if c` with a `return` and no `else` is not a terminator, but a statement after the `return` inside that branch is unreachable.

**Where.** In the checker, because the rule needs the block structure that it already walks and the same "ends on every path" logic as `returns?`; the linker does not look at statements. `check-block` (`src/checker.rkt:1404`) and the statement loop of `check-block-body` (`:1207`, for blocks and lambdas) check each statement, then, before the next one, fail if the one just checked is a terminator. So errors before the terminator come first, and the unreachable statement itself is not checked.

**Today.** The checker accepts code after a `return`, a `break` or an exhaustive `if`/`case`: `block-returns?` (`src/checker.rkt:191`) is true when any statement of the block returns, wherever it is. After this item a terminator can only be the last statement of its block, so `block-returns?` and `contains-return?` (`:153`) may look at the last statement only; that is a simplification, not a change in behavior.

**Help idea:** `this statement never runs, because the block ends at the return on line 5; remove it, or move it before the return`. For a `case` or `if`: `every branch of the case above ends with return, break or next`.

**Tests** (`tests/checker-test.rkt`): a statement after `return`, `break` and `next` (code and span); after an `if`/`else` that returns in every branch, after a `case` whose arms mix `return` and `break`, and inside a block (`return` leaves the block); valid: after an `if` without `else`, after `System.exit(0)`, after `while true` without `break`, after a `try`; two unreachable statements (the first is reported); a type error before the `return` (the type error wins). A golden fixture and an `{expect="CHECK-UNREACHABLE-CODE"}` block on the control-flow page.

**Docs:** `grammar.md` ("Statements and blocks" and "Functions and entry point"), the programming skill (`SKILL.md` and `references/diagnostics.md`), `site/content/tour/control-flow.md` and `functions.md`.

### 26.4 Not here

These are not planned. Each one would need its own decision against the principle above:

- **Dead stores** (a value overwritten before it is read): they need a flow analysis (26.2).
- **Unused function parameters:** signatures are fixed by callers and adapters (26.2).
- **Unused private functions, types, struct fields and enum variants:** they need a whole-file analysis, and a library file may keep a private helper on purpose. Not decided.
- **Ignored results:** already `CHECK-UNUSED-VALUE` for builtins without effects (`grammar.md`, "Methods on builtin types").
- **Style lints** (naming, line length, layout): never. The grammar and the one-way hints already fix the form.

### Impact on existing code

A scan of the repo on 2026-10-12 (a throwaway script on the real lexer and parser that applies the rules above; it does not replace running `make test` in each PR) found:

| Where | 26.1 imports | 26.2 variables | 26.3 unreachable |
|---|---|---|---|
| `examples/` (26 files), `stdlib/` | 0 | 0 | 0 |
| `benchmarks/programs/` | 0 | 1 (`error(message)` in `string-library.agc`) | 0 |
| `tests/fixtures/` (`.agc`) | 1 (`Pad` in `vm/linked.agc`) | 35 in 22 files | 1 (`vm/calls.agc`, a statement after `return`) |
| `tests/bdd/handlers.agc` | 0 | 1 (`invalid = 1 / 0`, a handler that crashes on purpose) | 0 |
| `site/content` blocks | 0 | 16 blocks on 7 pages (`library/network.md` 6, `process.md` 3, `files.md` 3, `io.md`, `range.md`, `task.md`, `tour/results-and-try.md`) | 0 |
| Programming skill examples | 0 | 0 | 0 |
| Inline programs in Racket tests | 0 | about 36: 23 of the 33 `check-ok` programs in `tests/checker-test.rkt` that the scan could read, and 13 in `bytecode-test.rkt` (7), `bdd-integration.rkt` (2), `checker-test.rkt`, `examples-test.rkt`, `task-test.rkt` and `vm-diff-common.rkt` | 0 |

What the hits are, and their fix:

- **Variables.** Most are tasks spawned and never awaited (`t = Task.spawn(...)`), values computed to test a step limit or preemption (`x += 1` in `while true`, 5 hits that only the compound-assignment rule finds), unused `for` and block variables in fixtures, and, on the site, `Result` values of `TCP.send`, `Process.send`, `Process.close_stdin` and `Process.wait` assigned and never read. The fix is a `_` name, a bare call statement, or using the value. The `checker-test.rkt` programs mostly introduce a variable only to check its type (`x: Int = i`); they get `_x` names or a `puts`.
- **The one unreachable statement** is the golden fixture `tests/fixtures/vm/calls.agc`, which checks that code after `return` does not run; the PR removes that line and the new checker test covers the case.
- **The one unused import** is `pkg/text/pad.agc` in `tests/fixtures/vm/linked.agc`, which tests `pkg/` resolution; the PR uses a name from it.
- `tests/eval/tasks/t5-scope-return/start.agc` has an unused `last`, but it is broken on purpose (agents fix it) and fails earlier with `CHECK-MISSING-RETURN`; it needs no edit.
- `{expect="..."}` site blocks that fail earlier with another checker code are not affected; `tour/results-and-try.md`'s `RUNTIME-UNWRAP-ERROR` block is, since a check error now comes before the run.

So 26.2 is the large migration (about 30 program and test files, and 16 site blocks on 7 pages); 26.1 and 26.3 touch one fixture each. Each count goes in its PR description.
