## 11. Ruby-style ergonomics

Status: implemented (roadmap "Ruby-style ergonomics"); the specification moved
to `grammar.md` and the programming skill. What is still open is listed in 11.4.
The rule below still decides which new forms to accept.

Agentica is presented as "Ruby with types". The evaluation logs (`docs/eval.md`)
show that most agent errors are Ruby and Python habits: `s.length`, `x.to_i`,
`!a`, `a && b`, `x += 1`. This section accepts the Ruby forms that keep static
checking and immutable values, so the model's habits become valid code. The
module forms stay valid; the Ruby forms become the style taught in the
programming skill.

**Which forms to accept.** Evaluation logs come from one model, so a form seen
there is a candidate, not a decision. Accept a form only when one of these
holds:

1. **It is real Ruby**, with the same meaning or a typed version of it.
   Examples: `!`/`&&`/`||`, `+=`, `"#{x}"`, `do |x| ... end`, `s.length`,
   `while cond do`, top-level `puts`/`print`/`gets`, `puts(x)` with any value,
   `x.to_s` and `x.inspect` on every data value, `break`/`next`. When the typed
   version differs from Ruby (`to_i` and `gets` return a `Result`), document the
   difference.
2. **It makes Agentica consistent with itself.** The same spelling works
   wherever the language already uses it. Examples: `Result.Ok(x)` as a value
   because it is already a pattern, `ok(v)` as a pattern because it is already a
   value, `Command.Show` without parentheses because the pattern has none, and a
   one-line case arm because one-line blocks exist.

Any other form gets a `help` that names the Agentica form, but is not accepted.
This covers forms from Python, JavaScript, Rust and Elixir (`let`, `var`,
`match`, `fn`, `elif`, `len`). It also covers Ruby forms that do not fit
(`when`, `then`, statement modifiers such as `x if c`, `loop do`, `Hash.new`).
Before relying on a newly accepted form, check it with a second model in an
evaluation round. Section 25 adds a stricter rule on top of this one, one way to
do each thing ([section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms)):
statement modifiers and `unless` stay out, since they are second ways to write
`if`, and so do `loop do` (`while true`) and keyword arguments ([section
25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c)).

### 11.1 Operators (implemented)

`!`, `&&`, `||` and compound assignment are in `grammar.md`.

### 11.2 Methods on builtin types (implemented)

Methods, the Ruby aliases and `CHECK-UNUSED-VALUE` are in `grammar.md`.

### 11.3 String interpolation (implemented)

Interpolation and the `\#` escape are in `grammar.md`.

### 11.4 Blocks and closures

Blocks, closures, `List.each`, `List.any?` and `List.all?` are in `grammar.md`.

Nothing is open here: standalone lambdas (`inc = lambda do |x: Int| x + 1 end`)
are planned in [section 25.5](25-ruby-typed-idioms.md#255-standalone-lambdas);
`{ |x| }` blocks and methods on user types are decided against ([section
25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c)).

### 11.5 Hints for foreign habits

Implemented: the hints are listed in `grammar.md`, section 7.

