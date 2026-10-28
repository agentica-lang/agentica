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

**How it lands.** Each item is its own small PR, in the order 26.1, 26.3, 26.2,
26.4: the two small migrations first; 26.2 after 26.3, so a read in dead code
never has to be counted; 26.4 last, because its one explicit discard, `_ =
f(...)`, already exists (#381), and before 26.2 a `sent = f(...)` would silence
26.4 and leave no trace. All four are front end only (the linker for 26.1, the
checker for the rest): the bytecode format and the VM do not change. Each PR is
a breaking change and migrates the repo in the same PR (`examples/`, `stdlib/`,
`benchmarks/`, `tests/`, the site blocks, the skill examples), adds a CHANGELOG
"Changed" entry, and tests the code and the span through the CLI. The 26.1
entry also speaks to package authors: an unused import in a `pkg/` library fails
the build of every program that uses it. The "Diagnostics for agents" section of
the grammar gets the no-warnings principle with the first item that lands.

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

**Why the linker.** The linker is the only stage that sees import aliases. It
resolves every `Alias.name` of a file through that file's imports (`resolve`,
`compiler/modules/`) and rewrites it to the target's identity (`@N::name`); the
checker then gets one merged program with no imports left. So the checker
cannot tell which alias a name came from, and the linker must decide.

**What counts as a use.** Every place where `resolve` finds the alias in the
file's imports (the alias is marked there), for any kind of name: a call
(`Text.shout(...)`, also without parentheses), a function value
(`&Text.shout`), a type in an annotation, a parameter, a field or a JSON type
argument (`Models.User`), a construction (`Models.User(name: "Ana")`), an enum
variant as a value or a pattern (`Domain.Option.Some(x)`), and an enum type
(`Domain.Option[Int]`). A use inside a function that is never called still
counts: the rule is about the file's text, not about what runs.

**Re-exports** (`docs/grammar/05b-modules.md`, roadmap 15b, built):
`export Url.parse` counts as a use of `Url`. A facade file that only re-exports
is the main use of re-exports, and it must not need a fake call to keep its
imports. 15b landed before this item, so the check marks the alias as used when
a re-export names it (`Declarations.reexports_of`), and its tests include a
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

**Edge cases:**

- **A mistyped alias is not an unused import.** In `import Text from "text"`
  with a call `Txet.shout("hi")`, the alias `Text` looks unused, but the real
  mistake is the call. The linker already passes a two-part function name whose
  first part is not an alias to the checker unchanged, so the checker reports
  it with its stable code. So the unused-import check skips a file that has any
  such name that is not a builtin call (`IO.inspect` and `String.length` are
  valid calls of that shape), and the checker reports `CHECK-UNKNOWN-NAME`, as
  today, with its "did you mean" help over functions and builtins.
- **An alias used without its member.** An import alias is never a name on its
  own: the linker already forbids an alias that collides with a declaration of
  the file or a builtin type name, so a one-part type or enum name equal to an
  alias is always a mistake, most often a missing member. Two shapes:
  - a type, construction or type expression: `u: User`, a parameter
    `def show(u: User)`, `User(name: "Ana")`, or `User` alone as a value, all
    with `import User from "user"`;
  - an enum variant without the enum's name: with `import Domain from
    "domain"`, the call `Domain.Some(1)` and the pattern `Domain.Some(x)` (the
    parser reads them as the variant `Some` of an enum named `Domain`).

  Today the checker reports `CHECK-UNKNOWN-TYPE` (for the enum call, "unknown
  enum") or `CHECK-PATTERN-TYPE` (for the pattern), and the alias is never
  marked, so 26.1 alone would add a wrong "remove import" error. So the linker
  stops right away with `CHECK-IMPORT-NAME` at that span. The help shows the
  missing member: `write User.<Type>` or `write Domain.<Enum>.Some(...)`. When
  the imported module exports a declaration with that name, the help names it
  (`write User.User`); for a variant, when exactly one exported enum has a
  variant of that name, the help names the enum (`write
  Domain.Option.Some(...)`). This is better than today's diagnostics even
  without the unused-import rule, so it can land in the 16a PR as its own small
  change.
- **Order.** Each file's imports are checked in source order, files in link
  order (the root first), and the first alias never used is reported. Errors
  found while rewriting come first: an unknown or private imported name
  (`CHECK-IMPORT-NAME`) in a file is reported before an unused import. A
  mistyped alias in a call is not a rewriting error; it is the checker's
  `CHECK-UNKNOWN-NAME`, and the rule above keeps the unused import from hiding
  it. Apart from that case, every linker error comes before every checker
  error, since the linker runs first.

**Help idea:** `remove import JsonUtil from "json_util"`, which names the whole
line, as in the example above. There is no "use it" hint: the linker cannot know
what the code meant to call.

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
  `xs = xs.push(v)` alone do not make `x` or `xs` used. The parser already
  turns `x += 1` into `x = x + 1` (`parse_compound`,
  `compiler/syntax/parser.agc`), so both forms get the same answer. This holds
  in nested blocks too: while the value of `x = ...` is checked, a read of `x`
  inside a block in that value does not count either, so `xs = xs.map do |v| v +
  xs.length end` alone leaves `xs` unused. The reason: values are immutable, so
  the only way the new value of `x` leaves such an assignment is through a later
  read of `x`. A counter that is only incremented, or a list that is only
  appended to, is lost work, and usually a bug (the result was meant to be
  printed or returned). Rust warns the same way (`variable is assigned to, but
  never used`). A call in such a value still runs; if a loop calls a function
  with effects only to feed its own state (`n = tick(n)`), the name is `_n`.

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
statement that introduces it (the span `CHECK-SHADOWED-NAME` uses), the block
parameter, the `for` variable or the pattern binding (the parser records a span
for each of the last two). The check runs at the end of each function, after its
body is checked and after its `CHECK-MISSING-RETURN` check, so every other error
in the function comes first, including the `CHECK-MISSING-RETURN` of the blocks
inside it. It reports the unused name whose span starts first in the source (by
source offset), not the one introduced first: in `ys = xs.map do |v| 1 end`, the
block parameter `v` is introduced before `ys` (the value is checked before the
name is introduced), but `ys` starts first, so `ys` is reported. Functions are
checked in the linked program's order.

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

**Terminators**, kept to what the checker already knows:

- `return`, `break` and `next`;
- an `if` with an `else` whose every branch ends in a terminator, and a `case`
  whose every arm ends in a terminator (any mix: one arm may `return` and
  another `break`).

That is the same idea as the "must return on every path" rule (`block_returns?`,
`compiler/check/check_flow.agc`, behind `CHECK-MISSING-RETURN`), widened from
`return` to `break` and `next`, since those end a block too. Like that rule, the
analysis does not look into loops or calls. These are not terminators:

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
already walks and the same "ends on every path" logic as the
`CHECK-MISSING-RETURN` rule; the linker does not look at statements. Blocks and
lambdas check each statement, then, before the next one, fail if the one just
checked is a terminator. So errors before the terminator come first, and the
unreachable statement itself is not checked.

After this item a terminator can only be the last statement of its block, so
`block_returns?` may look at the last statement only. `contains_return?` stays a
deep search: `missing_return_help` uses it.

**Help idea:**
`this statement never runs, because the block ends at the return on line 5;
remove it, or move it before the return`.
For a `case` or `if`:
`every branch of the case above ends with return, break or next`.

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
