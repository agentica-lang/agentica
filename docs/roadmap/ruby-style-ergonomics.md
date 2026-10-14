## Ruby-style ergonomics

Specified in [`docs/future/11-ruby-ergonomics.md` section
11](../future/11-ruby-ergonomics.md#11-ruby-style-ergonomics). Agents write Ruby
and Python habits (`docs/eval.md`); accept the Ruby forms that keep static
checking and immutable values. One pull request per step, each stacked on the
previous one and moving its part of section 11 into `grammar.md` and the
programming reference.

- [x] Specify operators, methods on builtins, interpolation, blocks and
  closures, and hints in `docs/future/11-ruby-ergonomics.md` section 11.
- [x] Operators: `!`, `&&`, `||`, and compound assignment (`+=`, `-=`, `*=`,
  `/=`, `%=`).
- [x] Methods on builtin types with the Ruby aliases, and `CHECK-UNUSED-VALUE`
  for unused results of builtins without effects.
- [x] String interpolation with `#{...}` and the `\#` escape.
- [x] Blocks and closures: `do |x| ... end` as the last argument, capture by
  value, `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET`, `CHECK-CAPTURED-ASSIGNMENT`;
  closures accepted everywhere a `Fn` is (tasks, HTTP, BDD); `List.each`,
  `List.any?`, `List.all?`; `examples/blocks.agc`.
- [x] Hints for foreign habits (`len`, `str`, `print`, `input`, `range`, `None`,
  `elif`, `to_i` used as `Int`).
- [x] Teach the Ruby forms in the programming skill and examples.
- [x] Re-run the `binary` evaluation arm and `tests/eval/diagnostics.py`, and
  compare with the 2026-10-10 snapshot (round 5 in `eval.md`).
- [x] Accept the Ruby forms round 5 showed (optional `do` on
  `case`/`while`/`for`, one-line case arms, module calls without arguments and
  parentheses) and hint the rest.
- [x] Re-run the `binary` arm after these changes and compare with round 5
  (round 6).
- [x] Accept the forms round 6 still showed: `Result.Ok`/`Result.Err` as values,
  `ok`/`error` as patterns, nullary variants without parentheses, top-level
  `print`/`gets`/`gets!`.
- [x] `break` and `next` in `while` and `for` (`CHECK-LOOP-CONTROL`).
- [x] `puts`/`print`/`IO.warn` take any value with `to_s`, and `to_s` works on
  every data value (round 8 showed `puts(n)` and `Bool#to_s` with both models).
- [x] `x.inspect` on every data value: the `IO.inspect` text as a `String`.

**Done when:** the Ruby forms check and run with the same diagnostics quality as
the module forms, and the evaluation shows the effect.

