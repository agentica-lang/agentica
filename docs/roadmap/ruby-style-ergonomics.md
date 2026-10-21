## Ruby-style ergonomics

**Done:** operators (`!`, `&&`, `||`, compound assignment), methods on
builtin types with Ruby aliases, `#{...}` interpolation (with the `\#`
escape), blocks/closures (`do |x|`, capture by value, `List.each/any?/all?`),
hints for foreign habits, `break`/`next`, `to_s`/`inspect` on every data
value; taught in the skill and examples, validated by eval rounds 5–8 in
`docs/eval.md`. Agents write Ruby and Python habits; the rule for which forms to
accept (those that keep static checking and immutable values), the one-way test
and the open items are in
[§25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms). The rules are in
the grammar.

**Done when:** the Ruby forms check and run with the same diagnostics quality as
the module forms, and the evaluation shows the effect.
