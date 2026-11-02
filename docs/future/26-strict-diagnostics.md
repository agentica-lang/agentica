## 26. Strict diagnostics

**Status:** planned (roadmap phase 16), as the first items of order step 7.6,
before the phase 15 items of that step, in the order 26.1, 26.3, 26.2, 26.4
(roadmap 16a, 16c, 16b, 16d). Decided by the user on 2026-10-12; 26.4 was added
after review the same day. Each item is a breaking change: migrate affected
programs and follow the spec's tests, spans, docs and changelog requirements;
no flag disables these checks. Done when: all four codes are documented in the
grammar, programming skill and site; repo programs are migrated; no code
disables the checks.

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
   diagnostic, and stops at the first error (`AGENTS.md`, "Rules"). The
   diagnostic format has only `error` (`compiler/diagnostics/diagnostic.agc`).
   Warnings would need a list of diagnostics next to a successful result, which
   breaks that contract for every stage and for `--json`.

**What the principle covers.** The diagnostics of the language stages (`LEX-`,
`PARSE-`, `CHECK-`, `LOWER-`, `BYTECODE-`, `RUNTIME-`). Runtime and tool output
that is not a diagnostic about the program's code is outside it: the VM tracer's
lines, the CLI's one-line fallback notice, and what a program writes with
`IO.warn`.

A new check is either an error with a stable code or it is not added; it
becomes an error only when the case is almost always a mistake and the fix is
local and mechanical (remove a line, or rename to a `_` name). Checks that fail
this test are not added (26.5).

**Deprecations.** Deprecation warnings may be considered only after 1.0. Before
1.0 a change in behavior lands as an error, the implementing PR migrates the
repo, and `CHANGELOG.md` lists it under "Changed".

**No switch to turn them off.** A check that can be turned off is a warning by
another name, and gives two accepted ways again. The discard `_` (`_ = f(...)`,
`for _ in ...`, `|_, v|`, `error(_)`) is the one way to drop a value on purpose,
and a name that starts with `_` is the one way to keep a name that is unused on
purpose (26.2).

**How it lands.** One small PR per item, in the order 26.1, 26.3, 26.2, 26.4:
the two small migrations first; 26.2 after 26.3, so a read in dead code never
has to be counted; 26.4 last, because its explicit discard `_ = f(...)` already
exists (#381), and before 26.2 a `sent = f(...)` would silence 26.4 and leave no
trace. All four are front end only (the linker for 26.1, the checker for the
rest). Each PR is a breaking change that migrates the repo (`examples/`,
`stdlib/`, `benchmarks/`, `tests/`, the site blocks, the skill examples), adds a
CHANGELOG "Changed" entry, and tests the code and the span through the CLI. The
26.1 entry also speaks to package authors: an unused import in a `pkg/` library
fails the build of every program that uses it. The grammar's "Diagnostics for
agents" section gets the no-warnings principle with the first item that lands.

- **§:** 26.1
  - **Item:** Unused imports
  - **Stage:** linker (`compiler/modules/linker.agc`)
  - **New diagnostic code:** `CHECK-UNUSED-IMPORT`

- **§:** 26.2
  - **Item:** Unused variables
  - **Stage:** checker (`compiler/check/checker.agc`)
  - **New diagnostic code:** `CHECK-UNUSED-VARIABLE`

- **§:** 26.3
  - **Item:** Unreachable code
  - **Stage:** checker (`compiler/check/checker.agc`)
  - **New diagnostic code:** `CHECK-UNREACHABLE-CODE`

- **§:** 26.4
  - **Item:** Ignored `Result` values
  - **Stage:** checker (`compiler/check/checker.agc`)
  - **New diagnostic code:** `CHECK-UNUSED-RESULT`

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

**Why the linker.** It is the only stage that sees import aliases: it resolves
every `Alias.name` through the file's imports and rewrites it to `@N::name`, so
the checker gets one merged program with no imports left.

**What counts as a use.** Every place where `resolve` finds the alias, for any
kind of name: a call (also without parentheses), a function value
(`&Text.shout`), a type in an annotation, parameter, field or JSON type
argument, a construction, an enum variant as a value or a pattern, and an enum
type. A use inside a function that is never called counts: the rule is about the
file's text. **Re-exports** (`docs/grammar/05b-modules.md`): `export Url.parse`
counts as a use of `Url` (the check marks it via `Declarations.reexports_of`),
so a facade that only re-exports needs no fake call.

**No side effects to keep.** An import has no effect besides its names (a module
has no top-level statements or state), so removing an unused one never changes
what a program does. The rule holds for every linked file (root, relative
imports, `pkg/` libraries, embedded `std/`), each against its own imports, with
no exemption for `pkg/`: a package with a stray import is broken for every user,
so the fix belongs in the package.

**Edge cases:**

- **A mistyped alias is not an unused import.** With `import Text from "text"`
  and a call `Txet.shout("hi")`, the real mistake is the call. The check skips a
  file that has a two-part function name whose first part is not an alias and
  not a builtin call (`IO.inspect`, `String.length` are valid), and the checker
  reports `CHECK-UNKNOWN-NAME` with its "did you mean" help.
- **An alias used without its member.** An alias is never a name on its own, so
  a one-part type or enum name equal to an alias is a mistake, most often a
  missing member: `u: User`, `User(name: "Ana")`, or `Domain.Some(1)` and the
  pattern `Domain.Some(x)` (the parser reads the variant `Some` of an enum named
  `Domain`). Today the checker reports `CHECK-UNKNOWN-TYPE` or
  `CHECK-PATTERN-TYPE` and the alias is never marked, so 26.1 alone would add a
  wrong "remove import" error. The linker therefore stops with
  `CHECK-IMPORT-NAME` at that span, with help `write User.<Type>` or `write
  Domain.<Enum>.Some(...)`, naming the declaration when the module exports it
  (`write User.User`) or, for a variant, the enum when exactly one exported enum
  has it. This is better than today's diagnostics on its own, so it can land in
  the 16a PR as a small change.
- **Order.** Imports are checked in source order, files in link order (root
  first), and the first alias never used is reported. Errors found while
  rewriting (`CHECK-IMPORT-NAME`) come first, and every linker error comes
  before every checker error.

**Help:** `remove import JsonUtil from "json_util"`, the whole line; there is no
"use it" hint, since the linker cannot know what the code meant to call.

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
expression anywhere in its scope. A read inside a block (or lambda) counts for
the outer variable it captures, since a block can read but never assign captured
values (`CHECK-CAPTURED-ASSIGNMENT`).

- **Compound assignment is not a read.** A read of `x` inside the value of an
  assignment to `x` itself does not count: `x += 1`, `x = x + 1` and `xs =
  xs.push(v)` alone do not make `x` or `xs` used (the parser turns `x += 1` into
  `x = x + 1`, `parse_compound`). This holds in nested blocks too: `xs = xs.map
  do |v| v + xs.length end` alone leaves `xs` unused. Values are immutable, so
  the new value of `x` leaves such an assignment only through a later read; a
  counter only incremented, or a list only appended to, is lost work and usually
  a bug. Rust warns the same way. A call in such a value still runs; if a loop
  calls a function with effects only to feed its own state (`n = tick(n)`), the
  name is `_n`.
- **Reassignment before any read.** The rule is per variable, not per
  assignment: `x = 1`, `x = 2`, `puts(x)` is valid. Finding the dead first value
  needs a flow analysis that the checker does not do (and Go does not reject it
  either).
- **Code that never runs.** A read after a `return` does not count; 26.3 lands
  first, so the checker rejects that statement before the question arises.
**`_` names.** Names that start with `_` and have more after it are already
valid: `NAME = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }` (`grammar.md`,
"Literals"; the lexer at `compiler/syntax/lexer.agc`). A variable whose name
starts with `_` (`_count`) is never reported; reading one stays valid. This is
the opt-out for a name kept on purpose, and it is only about this rule; to drop
a value, the discard below is the form.

**The discard `_`** is built (#381, decided on 2026-10-12, as Go's `_ =` and
Rust's `let _ =`; the grammar's "Variables and scope" has the rule). A `Void`
value is still `CHECK-VOID-VALUE`. The rest of this item, the unused-variable
check, is planned.

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
statement (as `CHECK-SHADOWED-NAME` uses), the block parameter, the `for`
variable or the pattern binding. The check runs at the end of each function,
after its body and its `CHECK-MISSING-RETURN` check, so every other error in the
function comes first. It reports the unused name whose span starts first in the
source, not the one introduced first: in `ys = xs.map do |v| 1 end` the block
parameter `v` is introduced before `ys`, but `ys` starts first, so `ys` is
reported. Functions are checked in the linked program's order.

**Help ideas**, by kind:

- variable:
  `"count" is never read; remove it, or name it _count if it is unused on
purpose`;
  when it is only updated: `"count" is only updated (count += 1), never read`;
  when the value is a `Result`:
  `handle the Result: try ..., a case on ok(_) and error(message), or .unwrap!;
or discard it with _ = TCP.send(...)`;
  when the value is anything else and a call with effects:
  `keep the call as a statement`.
- `for` variable: `write for _ in 0...n`.
- block parameter: `write |_, i|`.
- pattern binding: `write error(_) to match without binding the value` (the
  wording of today's help for an empty pattern, `compiler/syntax/parser.agc`).

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
statement, with a secondary span on the `if`: "every branch returns here".

**Rule:** a statement that follows a terminator in the same block is
`CHECK-UNREACHABLE-CODE`, at the first such statement.

This is a new code, apart from the existing `CHECK-UNREACHABLE-CASE-ARM` (a
`case` arm that an earlier arm already covers, `compiler/check/check_stmt.agc`),
which does not change.

**Terminators**, kept to what the checker already knows: `return`, `break` and
`next`; an `if` with an `else` whose every branch ends in a terminator; a `case`
whose every arm does (any mix). It is the "must return on every path" rule
(`block_returns?`, `compiler/check/check_flow.agc`, behind
`CHECK-MISSING-RETURN`) widened from `return` to `break` and `next`, and like it
the analysis does not look into loops or calls. Not terminators:

- `System.exit(...)` and calls that can halt (`gets!`, `unwrap!`, any `!`
  function): the checker has no "never returns" type, and a `-> Int` function
  that ends with `System.exit(1)` still needs a `return`, so the two rules would
  disagree.
- `while true ... end` without a `break` (the grammar: a loop does not by itself
  guarantee a return), and `try`, which leaves early only on an error.

Branches are checked as their own blocks: `if c` with a `return` and no `else`
is not a terminator, but a statement after the `return` inside that branch is
unreachable.

**Where.** In the checker, which already walks the block structure and has the
"ends on every path" logic. Each statement is checked and then, before the next
one, the checker fails if the one just checked is a terminator; so errors before
the terminator come first and the unreachable statement is not checked. After
this item a terminator can only be the last statement of its block, so
`block_returns?` may look at the last statement only (`contains_return?` stays a
deep search for `missing_return_help`).

**Help:** `this statement never runs, because the block ends at the return on
line 5; remove it, or move it before the return`; for a `case` or `if`: `every
branch of the case above ends with return, break or next`.

### 26.4 Ignored `Result` values

```agentica
def save(path: String, text: String) -> Result[Void]
  File.write_text(path, text, 1000)
  return ok()
end
```

The write can fail, but its `Result` is dropped, so the error is lost. This is
`CHECK-UNUSED-RESULT` at the call, with the help
`handle the Result: try File.write_text(...), a case on ok(_) and
error(message), or .unwrap!; or discard it with _ = File.write_text(...)`.

**Rule:** an expression whose value is dropped, that is an expression statement
or the last statement of a `Void` block, and whose type is `Result[...]`, is
`CHECK-UNUSED-RESULT` at the expression. It does not matter who made the
`Result`: a builtin with effects (`File.close`, `File.write_text`, `TCP.send`,
`HTTP.respond`, `Process.close_stdin`, `Process.wait`, ...), a user function, a
method, or `Task.await` on a task that returns a `Result`. The one exception is
`IO.inspect`, which prints its argument and returns it, so nothing is lost.

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

**Where.** In the checker, in `check_unused_value`
(`compiler/check/check_unused.agc`), which every dropped expression already
passes through (expression statements, and the last statement of a `Void`
block), with its type. The new check runs before the `CHECK-UNUSED-VALUE` one.
No other stage changes.

**Help idea:** as above, with the call's own text in the `try` and `_ =` forms.
`CHECK-UNUSED-VALUE` (a bare `xs.push(2)`) stays as it is. Since this check runs
first, `CHECK-UNUSED-VALUE` only ever sees values that are not a `Result` (a
pure builtin such as `s.to_i` gives `CHECK-UNUSED-RESULT`), so its help keeps
saying to assign or use the result and never suggests `_ =`.

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

### Impact on existing code

26.2 is the large migration (tasks spawned and never awaited, values computed
to test a step limit, unused `for` and block variables, and dropped `Result`
values of `TCP.send`, `Process.send`, `Process.close_stdin` and `Process.wait`).
26.1 and 26.3 touch one test or fixture each; 26.4 touches a few files. The
fixes are the discard `_`, a `_name`, a bare call statement (only for a value
that is not a `Result`) or using the value; a `Result` gets a 26.4 handling form
or `_ = ...`. Each PR counts the affected programs again and puts its count in
its description. A fixture that fails earlier with another code, or an
`{expect="..."}` site block that does, is not affected.
