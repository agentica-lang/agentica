---
name: agentica-code-guidelines
description: Style and idiom for Agentica (.agc) code, in the spirit of the Elixir style guide and Credo - layout, naming, module and function shape, pipe chains, case, Result and try error handling, comments and ## docs - plus which constructs are fast or slow (lookup tables, while loops, string building, profiling). Use when writing, reviewing or refactoring .agc code for readability, idiom or speed. Not for syntax or checker errors, nor for interpreter, VM or compiler work.
---

# Agentica code guidelines

Style and idiom for `.agc` code, taken from the Elixir community style guide and the Credo checks, cut down to what Agentica has. There are no macros, atoms, `with`, protocols, behaviours or typespecs here, so those rules are gone. Use it on code that already checks; a syntax or checker error is fixed first, with the language rules, not with this file.

Marks: `[CODE]` means the front end refuses the code with that diagnostic. `[test]` means a repo test checks it (line width in `compiler/` and `stdlib/`). No mark means only a reviewer checks it. Most style rules have no mark: the checker accepts `fooBar` as a function name, a tab as indentation and an unused variable.

## How to use it

1. Write or change the code, then run `agentica check FILE` and fix every diagnostic.
2. Walk the rules below. `references/style.md` has a bad/good pair for each; open it when a rule is not clear or a review needs an example.
3. Change style only in code you touch. A restyle of untouched code goes in its own commit.
4. Speed work is for hot paths, found by a profile and compared by measuring. Clear code first; `references/performance.md` has the measured costs.

## Layout

- Two spaces per level, no tabs, no trailing spaces, one newline at the end of the file.
- Lines at most 119 characters, comments included `[test]` in `compiler/` and `stdlib/`. Elsewhere use the same limit.
- One blank line between top-level declarations `[PARSE-MISSING-BLANK-LINE]`; no double blank lines; no blank line right after `def` or before `end`.
- A call or list that does not fit on a line goes one item per line with a trailing comma. A long expression goes inside parentheses (a line never continues by itself).
- Spaces around operators and after commas, none inside brackets and parentheses, none around `..` and `...`.

## Naming

- `snake_case` for functions, variables, fields and file names. `CamelCase` for structs, enums and variants. The case of the first letter is enforced `[PARSE-UNEXPECTED-TOKEN]` (`def Foo` and `struct point` fail); the rest is review.
- Constants are `UPPER_SNAKE_CASE`, at least two characters `[PARSE-CONSTANT-NAME]`. Name a magic number once: `MAX_RETRIES = 3`. Write big numbers with `_`: `1_000_000`.
- A function that returns `Bool` ends in `?` and reads as a question (`empty?`, `valid_port?`). No `is_` prefix. Bool variables and fields are plain adjectives or `has_` names: `done`, `has_name`.
- `!` is for the form that halts instead of returning a Result (`to_i!`, `unwrap!`). Give your own function a `!` only if it halts; the default is to return a `Result`.
- Name by meaning, not by type or shape: `price`, not `int_value`. No `do_x` and `x_impl` twins; give the helper its own name.
- Say it positively: `visible`, not `not_hidden`. Put the positive branch first; never write `if !x ... else ... end`, swap the branches.

## Modules and docs

- Declaration order is fixed `[CHECK-DECL-ORDER]`: module doc and imports, constants, `struct` and `enum`, `export def`, then private `def`. Imports are sorted by path. Inside a group, put callers before the helpers they call.
- Export only what other files use. One file, one topic; split a file when it grows several.
- `import Alias from "path"` when you use many names or a name could clash. `import {a, B} from "path"` for one or two names used often. Never both for one module.
- Use a module-local type alias when the same qualified or composite type recurs across a module. Keep the alias descriptive, and do not add a synonym for a type that is already short and clear.
- The first `##` block of a file, then a blank line, is the module doc. Every `export def`, `struct`, `enum`, field and variant gets a `##` doc that starts with a verb and says what it returns, not how.
- A `#` comment goes inside the body or above the `##` block, never between the block and its `def` `[PARSE-DETACHED-DOC]`.
- Comments say why: a rule, an order, a limit, a trick. Do not narrate the line below. Never leave commented-out code.

## Functions

- A function does one thing. If you want a comment for each paragraph, split it. Hot loops are the exception (see Speed).
- Four parameters or fewer. For more, group them in a struct. Options go last, with a default `[CHECK-DEFAULT-ORDER]`.
- Use guard returns at the top for the bad cases, so the main path stays flat. Keep nesting to three levels of `if`, `for`, `while` and `case`.
- Return a struct or an enum, not parallel lists, a `Map[String, String]` with fixed keys, or magic `Int` and `String` codes.
- `for` to build a total or a result; `map`, `filter`, `reduce`, `any?` and `all?` to transform. A block cannot assign an outer variable `[CHECK-CAPTURED-ASSIGNMENT]`.
- Rebind a name only for loop state (`total += x`, `xs = xs.push(x)`). Give a new meaning a new name.
- Compare a Bool as itself: `if done`, not `if done == true`.
- `and`, `or`, `not` (not `&&`, `||`). Name a long Bool expression with a `?` function.

## Pipes

- Three or more steps on one value are a pipe chain in parentheses, one `|> f(args)` per line, not `x = f(x, args)` repeated. Review checks it; nothing else does.
- Start the chain with the value: a name, a literal, or the call that makes it (`header(version)`). A chain of one step is a plain call: `f(x)`, not `x |> f()`.
- Pipe into your own functions only. A builtin with a method form uses the dot, and a pipe into it is refused `[CHECK-PIPE-METHOD]`: `xs.sort.join(",")`.
- Use a pipe instead of nested calls three deep: `h(g(f(x)))` is `x |> f() |> g() |> h()`.

## case and if

- `case` for an enum, a Result, or three or more branches on one value. `if`/`elsif` for yes-or-no tests. A nested `if` on the same value is a `case`.
- On an enum, list every variant and no `_`, so a new variant is a compile error `[CHECK-NON-EXHAUSTIVE-CASE]`. Use `_` only when the rest really is one case.
- Put the specific arms and guards first. A guarded or nested arm does not cover its variant, so end with `ok(_)` or `_`.
- A key-to-value `if` chain is a `Map` constant. A membership test is a `Set` constant.
- Use a nested pattern when the shape of an enum payload decides the branch. Add a guard only for a condition that the pattern cannot express; keep an unguarded fallback because guarded arms do not establish exhaustiveness.

## Errors

- A function that can fail returns `Result[T]`; `try` passes the error up. There are no exceptions. A function that cannot fail does not return a Result.
- Use the halting forms (`to_i!`, `unwrap!`) only where a failure is a bug, and say so in a comment.
- Error text is lowercase, has no final period, and holds the bad value: `"negative: #{price}"`.
- Do not swallow an error with `unwrap_or` unless the default is right; say why in a comment.
- Catch the error at the edge (`main`, a request handler) and write it with `IO.warn`.
- Use an enum for outcomes the caller must tell apart; `error(msg)` is for failures a person reads.

## Strings and collections

- Build text with interpolation, not `+` and `.to_s`. Long text: a heredoc, or a few sentence-sized pieces joined with `+`, never one piece per line.
- `List` when order matters, `Set` for membership, `Map` for lookup by key, a struct for a record with known fields.

## Speed (only on a hot path)

- A table that does not depend on the arguments is a module constant, built once: `VOWELS = Set.new(["a", "e"])`, not rebuilt on each call.
- Test membership with a `Set`, not an `or` chain.
- Build text with `push` and one `join`. `s = s + piece` in a loop is quadratic (measured: 100,000 appends took 7.0 s, the `join` form 0.06 s).
- Profile before changing anything: `AGENTICA_VM_TRACE=profile agentica FILE.agc`. Steps repeat from run to run; wall time does not.
- Details and numbers: `references/performance.md`.

## When to read a reference

| Read | When |
|---|---|
| [references/style.md](references/style.md) | you need the bad/good pair of a rule above, or you review code and want an example to quote |
| [references/performance.md](references/performance.md) | a program is slow, a loop runs over 100,000 items or about 1 MB, or you choose between `while`, blocks, `.with`, `Set`, `Map` and `List` for a hot path |
