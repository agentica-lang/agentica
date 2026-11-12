## The rules of `agentica lint`: each is a suggestion from the style guide (site/content/style.md) that the syntax tree
## shows without types, with a stable LINT- code. The rules read the catalog of builtins as data (a builtin is no step
## of a pipe), never the checker. A suggestion is a Problem, so it prints and serializes as any
## diagnostic does, but it never means the program is wrong: `agentica check` owns what is always a mistake.

import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Source from "../syntax/source"

## A `+` that grows a String inside a loop copies the whole text on each pass, so the loop is quadratic.
export STRING_APPEND = Rule(
  code: "LINT-STRING-APPEND-IN-LOOP",
  message: "this loop grows a String with +, which copies the text on every pass",
  help: "push the pieces on a List and join them once after the loop: parts = parts.push(piece), parts.join(\"\")",
)

## A Bool is a condition by itself.
export BOOL_COMPARE = Rule(
  code: "LINT-BOOL-COMPARE",
  message: "a Bool is not compared with true or false",
  help: "use the Bool as it is: `if done` or `if not done`, with and, or and not",
)

## One `|>` step is a plain call.
export SINGLE_PIPE = Rule(
  code: "LINT-SINGLE-PIPE",
  message: "a pipe with one step is a plain call",
  help: "a plain call, or the `.` form for a builtin: `shout(text)`, not `text |> shout()`",
)

## Three calls nested in first position are a pipe that starts with the innermost one.
export NESTED_CALL = Rule(
  code: "LINT-NESTED-CALL",
  message: "three calls are nested in first position",
  help: (
    "a pipe that starts with the innermost call, one step per line: `(g(x) |> f() |> h())` for `h(f(g(x)))`; " +
    "a `try` stays on its step: `|> try h()`"
  ),
)

## A method chain that passes lambdas is a pipe, one step per line.
export LAMBDA_CHAIN = Rule(
  code: "LINT-LAMBDA-CHAIN",
  message: "a method chain of three or more steps passes lambdas",
  help: (
    "a pipe with one step per line, each method by its name: " +
    "`(xs |> map(->(x) { x * 2 }) |> select(->(x) { x > 2 }) |> sum())`"
  ),
)

## Text is built with interpolation.
export TO_S_CONCAT = Rule(
  code: "LINT-TO-S-CONCAT",
  message: "text is built by joining pieces with + and to_s",
  help: "use interpolation: \"\#{name}: \#{count} items\"",
)

## Three or more branches on one value are a `case`.
export IF_CHAIN = Rule(
  code: "LINT-IF-CHAIN",
  message: "an if chain tests one value against literals in three or more branches",
  help: "use `case value` with one arm for each literal and `_` for the rest",
)

## The positive case goes first.
export NEGATED_ELSE = Rule(
  code: "LINT-NEGATED-ELSE",
  message: "a negated test is paired with else",
  help: "test the positive case and swap the two bodies",
)

## Only public code has a `##` doc.
export PRIVATE_DOC = Rule(
  code: "LINT-PRIVATE-DOC",
  message: "a private declaration has a ## doc",
  help: "delete the doc, or use a # comment for the note that the code needs",
)

## A qualified name used again and again is imported by name.
export REPEATED_NAME = Rule(
  code: "LINT-REPEATED-QUALIFIED-NAME",
  message: "a qualified name is written many times",
  help: "import the type by name",
)

## One rule: its code, what it says and how to write it instead. The message and the help may be replaced (`with`) by a
## rule that names the code it found.
export struct Rule
  code: String
  message: String
  help: String
end

## The suggestion of `rule` in `file`, at `span`.
export def at(file: String, rule: Rule, span: Source.Span) -> Problems.Problem
  Problems.problem(file, "", rule.code, rule.message, span, Diag.Help.Hint(rule.help))
end
