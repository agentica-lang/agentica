---
name: agentica-code-guidelines
description: >-
  Style and idiom for Agentica (.agc) code: naming, layout, modules, functions,
  pipes, case, Result/try, comments, and performance. Use when writing or
  reviewing Agentica code style; language correctness belongs to
  agentica-programming.
---

# Agentica code guidelines

Use on `.agc` that passes `agentica check`. Fix syntax or type errors first
with `agentica-programming`. A diagnostic code in parentheses means the front
end refuses that form. `[test]` means a repo test enforces the rule. Unmarked
rules are review-only.

- `references/style.md`: bad/good examples for these rules.
- `references/performance.md`: measured costs; speed work requires profiling
  and measurement.
- `site/content/style.md`: the short version for people, on the site; change
  it together with these rules.

Change style only in code you touch. Restyle untouched code separately.

## Layout

- Two spaces per indent; no tabs or trailing spaces; one newline at EOF.
- Lines max 119 characters, comments included (`[test]` in `compiler/` and
  `stdlib/`); use the same limit elsewhere.
- Separate top-level declarations with one blank line
  (`PARSE-MISSING-BLANK-LINE`); no double blank lines or blank lines right
  after `def` or before `end`.
- Break long calls/lists one item per line with a trailing comma; wrap long
  expressions in parentheses. Never continue an expression on a bare line.
- Put spaces around operators and after commas, not inside brackets or
  parentheses, or around `..` and `...`.

## Naming

- `snake_case` for functions, variables, fields and files; `CamelCase` for
  structs, enums and variants. The first letter is enforced
  (`PARSE-UNEXPECTED-TOKEN`); the rest is style.
- Constants are `UPPER_SNAKE_CASE`, at least two characters
  (`PARSE-CONSTANT-NAME`). Name meaningful numbers; use `_` in large numbers.
- Bool-returning functions end in `?` and read as questions; no `is_`. Bool
  variables/fields are adjectives or `has_` names.
- `!` means a function halts instead of returning a `Result`; give your own
  function `!` only when it halts. Default to returning `Result`.
- Name by meaning, not type (`price`, not `int_value`). Avoid `do_x`/`x_impl`
  twins; give a helper its own name. State the positive case first; avoid
  `if !x ... else ...`.

## Modules and docs

- Declaration order is fixed (`CHECK-DECL-ORDER`): module doc/imports,
  constants, structs/enums, `export def`, private `def`. Sort imports by path;
  put callers before helpers within a group.
- Export only names used by other files. Keep one topic per file; split files
  that grow into several topics.
- Use `import Alias from "path"` for many names or possible collisions;
  `import {a, B} from "path"` for one or two frequent names. Never both for
  one module.
- Add a descriptive local type alias when a composite/qualified type recurs;
  don't alias a short, clear type.
- The first `##` block, then a blank line, is the module doc. Every exported
  `def`, `struct`, `enum`, field and variant gets a `##` doc starting with a
  verb and describing its result, not its implementation.
- `#` comments explain why (rule, order, limit, trick), not the next line.
  Put them in a function body or above a `##` block, never between it and its
  declaration (`PARSE-DETACHED-DOC`). Remove commented-out code.

## Functions

- One purpose per function; split when comments divide its paragraphs. Hot
  loops are an exception.
- Prefer four or fewer parameters; group more in a struct. Put options last
  with defaults (`CHECK-DEFAULT-ORDER`).
- Guard-return bad cases early. Keep nesting to three levels of `if`, `for`,
  `while` and `case`.
- Return a struct/enum, not parallel lists, fixed-key maps or magic codes.
- Use `for` for totals/results; collection methods for transforms. Blocks cannot
  assign outer variables (`CHECK-CAPTURED-ASSIGNMENT`). Rebind only loop state;
  use a new name for a new meaning.
- Test Bools directly (`if done`), not against `true`/`false`. Use `and`,
  `or`, `not`, not `&&` or `||`; name long predicates with a `?` function.

## Pipes

- Use a parenthesized pipe for three or more steps on one value; put one
  `|> f(args)` per line. Start with the input value. One step is a regular call.
- Pipe into your own functions. Builtins with method forms use `.`; piping to
  them fails (`CHECK-PIPE-METHOD`): write `x.upcase`, not `x |> String.upcase`.
  Replace three-deep nested calls with a pipe.

## case and if

- Use `case` for enums, `Result` or at least three branches on one value; use
  `if`/`elsif` for yes/no. Prefer `case` over nested `if` on the same value.
- List every enum variant and omit `_` so new variants fail checking
  (`CHECK-NON-EXHAUSTIVE-CASE`). Use `_` only when the remainder is one case.
- Put specific arms/guards first. A guarded or nested arm doesn't cover a
  variant; keep an unguarded fallback.
- Replace key-to-value `if` chains with a `Map` constant, membership chains
  with a `Set` constant.
- Use nested patterns when payload shape decides; add guards only for
  conditions patterns can't express.

## Errors

- Fallible functions return `Result[T]`; propagate with `try`. No exceptions.
  Non-fallible functions don't return `Result`.
- Use halting forms (`to_i!`, `unwrap!`) only when failure is a bug; explain
  why in a comment.
- Error text is lowercase, has no final period, and includes the bad value.
  Don't swallow errors with `unwrap_or` unless the default is right; explain it.
- Handle errors at the boundary (`main`, request handler) with `IO.warn`.
  Use an enum for caller-visible outcomes; `error(msg)` for human-readable
  failures.

## Strings and collections

- Build text with interpolation, not `+` or `.to_s`. Use a heredoc or a few
  sentence-sized `+` pieces, never one piece per line.
- Use `List` for order, `Set` for membership, `Map` for keyed lookup, and a
  struct for a record with known fields.

## Speed (only on a hot path)

- Profile first: `AGENTICA_VM_TRACE=profile agentica FILE.agc`. Steps repeat;
  wall time varies. Keep speed changes only when measurement improves.
- Hoist argument-independent tables to module constants. Use `Set` for
  membership; build text with `push` and one `join` (`s = s + piece` in a loop
  is quadratic).
- Details and measurements: `references/performance.md`.
