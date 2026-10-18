## Ruby-style ergonomics

The rules are in `grammar.md` and the programming reference; the rule for
which forms to accept, and the open items, are in
[§25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms). Agents write Ruby
and Python habits (`docs/eval.md`); accept the Ruby forms that keep static
checking and immutable values. One pull request per step, each stacked on the
previous one and moving its part into `grammar.md` and the programming
reference.

**Done:** operators (`!`, `&&`, `||`, compound assignment), methods on
builtin types with Ruby aliases, `#{...}` interpolation (with the `\#`
  escape), blocks/closures
(`do |x|`, capture by value, `List.each/any?/all?`), hints for foreign habits,
`break`/`next`, `to_s`/`inspect` on every data value; taught in the skill and
examples, validated by eval rounds 5–8 in `docs/eval.md`. Rules in the grammar
(the one-way test and open items in
[§25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms)).

**Done when:** the Ruby forms check and run with the same diagnostics quality as
the module forms, and the evaluation shows the effect.

