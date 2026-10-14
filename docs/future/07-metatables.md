## 7. Possible metatables: Ruby-style modules

**Status:** not planned: see [section
25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c). User types have no
methods, and a struct of `Fn` fields with wrapper functions covers the same need
by composition. The text below is kept as a record of the idea. Group shared
behavior visually, then attach it to maps, lists, or records. Prefer Ruby's
`module ... end`, `def ... end`, `self`, and `.extend(...)` over new spellings
such as `defmod` or Elixir's `defmodule`. Borrow Elixir's immutable-value
approach and keep static checking; adopting this syntax does not require classes
or inheritance.

Possible shape, deliberately Ruby-parsable rather than current Agentica syntax:

```ruby
module User
  # Proposed receiver: Map[String, String]; result: String.
  # These comments illustrate types, not a settled annotation syntax.
  def name()
    return self["name"]
  end

  def greet()
    return "Hello " + self.name()
  end
end

def main()
  ana = {"name" => "Ana"}.extend(User)
  bob = {"name" => "Bob"}.extend(User)
  puts(ana.greet()) # Hello Ana
  puts(bob.greet()) # Hello Bob
end
```

The same idea could give a list named methods without changing its normal
indexing:

```ruby
module Numbers
  # Proposed receiver: List[Int]; result: Int.
  def first()
    return self[0]
  end
end

numbers = [10, 20, 30].extend(Numbers) # Fragment inside main.
puts(String.from_int(numbers.first())) # 10
puts(String.from_int(numbers[1]))      # 20
```

Candidate semantics and boundaries:

- A module holds shared methods, not per-object state. A method's `self` is the
  attached receiver; methods can call sibling methods through `self`.
- Unlike Ruby's mutating `extend`, the candidate Agentica form returns a new
  immutable wrapper. The original value is unchanged. Module selection and
  method signatures must be known to the checker; incompatible receivers and
  unknown methods are check errors.
- Normal map/list indexing, insertion order, and missing-key/index diagnostics
  stay unchanged initially. Attachment adds behavior; it does not make
  collection lookup faster or combine List and Map into a mixed PHP-style array.
- Lua-style fallback lookup (`__index`), custom indexing, operators, or callable
  objects could be a later layer. Decide which typed hooks are useful before
  adding them; do not make every lookup run arbitrary callbacks by default.

Open decisions before implementation:

- How receiver, argument, and result types are declared while keeping
  Ruby-parsable syntax: signature comments or a separate RBS-style file are
  possibilities, not decisions.
- The static type of an attached value, visibility, method collisions, multiple
  modules, and whether collection operations preserve attached behavior.
- Whether `.extend(Module)` is sufficient or an explicit
  `Meta.attach(value, Module)` API is also needed. Prefer one spelling, not both
  without a real need.
- Name resolution for bare module arguments and how module namespaces relate to
  records and future imports.

**Ruby tooling goal, not a compatibility promise:** existing Agentica `->`
signatures and `struct` declarations are not Ruby syntax. The examples use `=>`
for String-keyed maps; Ruby's `{"name": value}` creates a Symbol key, unlike
Agentica's current map literal. Reusing Ruby linters such as RuboCop requires a
Ruby-parsable source subset or a translation step, plus configuration for
Agentica conventions. Verify that with real tooling before claiming support.
None of these spellings or type alternatives changes the core grammar today.

