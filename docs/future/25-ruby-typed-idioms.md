## 25. Ruby typed idioms

Decisions behind the Ruby forms of the language. Built forms live in the
grammar and the programming skill; planned ones live in their issue, with the
spec below: `format` (§25.11, #982).

The principles (Ruby with types, one way, no warnings, the method test) are in
`docs/grammar/01-overview.md` §2.

### 25.11 `format`

```agentica
puts(format("%-8s|%6.2f|%03d|%x", "apple", 2.5, 7, 255))   # apple   |  2.50|007|ff
```

`format(fmt, args...)` returns a `String`, like Ruby's `Kernel#format`. A
conversion is `%[flags][width][.precision]type`:

- `d`: an `Int`, in decimal.
- `x`: an `Int`, in lowercase hex; a negative number is `-` and the hex of its
  magnitude (`-ff`, as in Python; Ruby writes `..f01`).
- `f`: a `Float`, fixed point with 6 digits after the point unless `.precision`
  says otherwise; `NaN`, `Inf` and `-Inf` as in Ruby.
- `s`: any value with `to_s`, as `puts` writes it.
- `%%`: a `%`.

Flags: `0` pads numbers with zeros after the sign (`%05d` of `-42` is `-0042`);
`-` pads on the right with spaces. With both (`%-05d`), `0` is ignored, as in C
and Ruby. Other flags (`+`, space, `#`) are `CHECK-FORMAT-SPEC`. `width` is 1 to
1000 and counts characters as `String.length` does. `precision` is 0 to 50 and
only for `f`. An `Int` for `%f` is not converted (`n.to_f`, as everywhere).

**One way:** `format` is only for width, precision, flags or hex, and `"#{x}"`
interpolation stays the way to put values in text. A format string whose
conversions are all bare `%s` or `%d`, or that has no conversion at all, is
`CHECK-FORMAT-SPEC` with a help that shows the interpolated string.
`format("%.2f", x)` is the one public way to write a fixed number of digits;
`x.to_fixed(2)` and `x.round(2).to_s` get `CHECK-UNKNOWN-METHOD` with a help
that shows it.

**The format string must be a literal, checked at compile time.** The
alternative was a run-time format string returning `Result[String]`. The checker
then knows the arguments and their types, so a mistake is a compile error with a
span inside the string, the result is a plain `String`, and nearly all real
format strings are literals. A program that needs a format chosen at run time
picks between literals.

**Checker rules:**

- `format` is checker-handled and variadic: a catalog entry covers the name
  reservation and `agentica help format`. Only the function name is reserved: a
  user `def format` is `CHECK-REDEFINED-NAME` (breaking); variables, parameters
  and fields named `format` stay valid.
- The first argument must be a plain one-line string literal, without `#{...}`
  and not a heredoc: `CHECK-FORMAT-LITERAL`.
- A bad conversion (unknown type or flag, a trailing `%`, `precision` on `d`,
  `x` or `s`, `0` on `s`, a width or precision out of range) is
  `CHECK-FORMAT-SPEC` at the conversion's span inside the literal.
- A wrong number of arguments is `CHECK-ARITY`; an argument of the wrong type (a
  `%s` argument without `to_s` included) is `CHECK-TYPE-MISMATCH` at the
  argument, with a secondary span at its conversion.
- `sprintf(...)`, `"%d" % x` and `String.format(...)` get a help that shows
  `format(...)`.

**Format strings are not parsed at run time.** Padding, decimal and hex text
are Agentica code in the compiler prelude, and each call becomes a
concatenation of the literal parts and one prelude call per conversion. One
part is a builtin, prelude-only (`CHECK-UNKNOWN-NAME` elsewhere): fixed-point
text of a `Float` (digits 0 to 50, otherwise `RUNTIME-INVALID-COUNT`), because
correct decimal rounding of a binary `Float` needs exact arithmetic (the VM
calls `snprintf` with `%.*f`).

### 25.13 Decided against (Part C)

Each of these is decided; it gets a `help` that names the Agentica form where
one exists.

- **Runtime metaprogramming:** `define_method`, `class_eval`, `instance_eval`,
  `method_missing`, `send`/`public_send`: the checker must know every call; use
  a `Map[String, Fn[...]]` to dispatch by name.
- **`respond_to?`, reflection and structural interfaces** (Go-style: a type fits
  because it has the right methods): user types have no methods, and the checker
  knows every field and method of a value, so the answer is constant; a run-time
  check would only hide a type error. Reflection (`instance_variable_get`,
  building a value from a type name, calling a function by a name in a string)
  breaks static checking and makes the VM keep names and types at run time; use
  `JSON.from` to see a value's fields. Listing the fields of a struct type is
  `Type.members` (`docs/grammar/06-semantics.md`).
- **`eval` and `binding`:** no code from strings at run time.
- **Monkey patching and refinements:** builtin types and modules are fixed;
  write a function.
- **Hooks** (`included`, `inherited`, `method_added`), **mixins** (`include`,
  `extend`, `Comparable`), metatable-style methods and **duck typing:** there
  are no classes or user methods. A struct of `Fn` fields is the interface,
  checked by name, and wrapper functions compose behavior (below). For chaining
  user functions, use `|>`.
- **Symbols:** `String` keys and enums cover them. **`freeze` and `dup`:** every
  value is already immutable.
- **`yield`:** the block is a named `Fn` parameter, called with `.call`.
- **Generators and fibers** (`Enumerator.new`, `Fiber`): see
  `27-iteration-and-concurrency.md`; a producer task that sends into a
  `Channel` is the generator.
- **Keyword arguments:** `connect("a", port: 8080)` would be a second way to
  pass an argument that can already be passed by position. Calls stay
  positional; `with` and struct construction stay the only places with named
  arguments.
- **`loop do ... end`:** `while true ... end` already does it, and `break`
  cannot leave a block, so it would be a statement that looks like a block.
- **`unless` and modifiers on other statements** (`puts(x) if v`,
  `x += 1 if c`): second ways to write `if`. The parser gives
  `PARSE-UNEXPECTED-TOKEN`. Only `return`, `break` and `next` take an `if`
  guard.
- **New method aliases** (`select`, `collect`, `detect`, `inject`) and **second
  ways** (`reject`, the `Range` Enumerable methods, the block form of
  `each_slice`): each gets `CHECK-UNKNOWN-METHOD` (or `CHECK-BLOCK-TARGET`) with
  the canonical form.
- **`*args` and `**opts` splats:** a `List` or a struct parameter, and
  defaults. **`%w[...]`:** a list literal.
- **`raise`/`rescue`/`ensure`:** errors are `Result` values with `try`;
  `File.open` with a block covers `ensure`.
- **User operator overloading, and overloading by argument type or by arity:**
  it breaks the inference of blocks and of empty literals (`[]`, `{}`) from the
  expected parameter type, makes diagnostics worse, and needs name mangling in
  the VM and the linker; defaults cover arity. Struct equality is provided by
  the compiler, not by the user.
- **Structural unions** (`Int | String`): they need flow-sensitive narrowing and
  duplicate the exhaustiveness work of enums; sum types come from enums.
- **General and procedural macros:** agents write worse code in custom DSLs,
  diagnostics land in expanded code, and they need a new stage.
- **Checks that are not diagnostics:** dead stores (they need a flow analysis),
  unused function parameters (signatures are fixed by callers and adapters),
  unused private functions, types, fields and variants (a whole-file analysis; a
  library may keep a helper on purpose), a rule on a dropped `Task[Result[...]]`
  (it would reject fire-and-forget), and style lints in the checker (naming,
  line length, layout; `agentica lint` is the home of suggestions).
- **Tooling and library:** rename and refactor commands (agents edit files well;
  `refs` gives the places); a package registry, private registries, publishing
  commands, signatures, branches or version ranges, and semver (a pin is a tag
  or a commit, one name has one source, and two majors use two names); a
  template read at run time (it needs `eval`); raw string literals for regex;
  an Elixir-style `@doc` attribute and YARD-style `@param` tags.
- **A musl (Alpine) build and the VM as a shared library:** the musl build stays
  apart from the glibc release, and loading the VM as a shared library through
  the FFI was rejected (two garbage collectors, clashes over `exit` and stdio).

**Composition instead of inheritance.** To "inherit" behavior:

1. The interface is a struct of `Fn` fields, for example `Storage` with `get`
   and `put`; `s.put(a, b)` calls a field.
2. A wrapper (decorator) function takes a base value and returns a new one with
   some fields replaced, keeping the others: `def logged(base: Storage) ->
   Storage` returns `base.with(get: ...)`, where the new `get` logs and then
   calls `base.get`.
3. A facade module passes on names from other modules with re-exports
   (`docs/grammar/05b-modules.md`), like Elixir's `defdelegate`.

An adapter or facade that builds a path from a name must check it with an
allow-list first: not empty, only ASCII letters, digits, `-` and `_`.
