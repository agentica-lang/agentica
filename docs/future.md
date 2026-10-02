# Agentica: future grammar

Status: proposal. Nothing in this document is implemented or normative. The language the interpreter runs is in [`grammar.md`](grammar.md).

Working rule: when a phase of the [`roadmap.md`](roadmap.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

## 2. Enums and pattern matching

This section documents the direction already discussed. It is not part of the initial core and requires extending the lexer, parser, checker, and evaluator. The illustrative Outcome enum is separate from the already implemented builtin Result[T] with String errors.

```ruby
enum Outcome[T, E]
  Ok(T)
  Err(E)
end

enum Option[T]
  Some(T)
  None
end

def label(result: Outcome[String, String]) -> String
  case result
  in Ok(value)
    return value
  in Err(message)
    return message
  end
end
```

Proposed EBNF extension, added to the alternatives for declarations and statements:

```ebnf
enum_decl        = "enum", TYPE_NAME, [ type_parameters ], NL,
                   variant_decl, { variant_decl }, "end", NL ;
type_parameters  = "[", TYPE_NAME, { ",", TYPE_NAME }, "]" ;
variant_decl     = TYPE_NAME,
                   [ "(", type, { ",", type }, ")" ], NL ;

case_statement   = "case", expression, NL,
                   match_arm, { match_arm }, "end", NL ;
match_arm        = "in", pattern, NL, block ;
pattern          = "_"
                 | INTEGER | FLOAT | STRING | "true" | "false" | "nil"
                 | "-", INTEGER | "-", FLOAT
                 | TYPE_NAME, [ "(", pattern_bindings, ")" ] ;
pattern_bindings = NAME, { ",", NAME } ;
```

`_` is a wildcard that does not introduce a variable. The first version of matching allows only literals and variants with direct bindings: no nested patterns, guards, regex, or list patterns. `case` remains a statement, not an expression.

The checker verifies exhaustiveness for enums: all variants must be covered or a final wildcard must exist. For open domains such as integers and strings it requires a wildcard. Bindings are local to each arm; arms are tried in order and unreachable ones are diagnosed.

The expression grammar must also be extended to build variants, for example `Ok(value)` and `None`. Before implementing this extension, name resolution must be decided: variant qualification, collisions with structs, and how to infer type parameters that do not appear in the payload. The core does not settle those decisions in advance.

`Point(x: 0, y:)` was discussed as a possibility but is postponed: this first matching has no struct patterns or field shorthand.

## 3. Extensions without a normative grammar

| Extension | Direction | Pending decisions |
|---|---|---|
| Interpolation | `"Hello #{user.name}"` | Escapes, allowed expressions, and conversion to text |
| Function generics | Reuse functions with different types | Syntax, inference, and constraints |
| Closures and methods | Better ergonomics; possible [module attachment](#7-possible-metatables-ruby-style-modules) | Capture, receiver types, representation, and resolution |
| Modules | Group behavior and split programs into files | Import, visibility, cycles, and module attachment (section 7) |
| C FFI | Safe wrappers over native calls | Pointers, ownership, ABI, and calls from the interpreter |
| Async and fibers | Suspend execution on I/O; initially one thread | API, cancellation, and error propagation |
| Actors | Own messages and mailboxes | Syntax, isolation, shared values, and supervision |

## 4. Standard library and function values (phases 5f–5m)

Fixed here so each roadmap phase can take it as its specification.

```ebnf
postfix_expr     = primary, { ".", NAME
                            | ".", "call", "(", [ arguments ], ")"
                            | "[", expression, "]" } ;

primary          = (* …core forms, plus: *)
                 | "&", NAME
                 | TYPE_NAME ;
```

- **`&name` and `.call(...)`:** `&name` turns a top-level function into a value of type `Fn[...]`, and `value.call(args)` calls it. `call` is not a reserved word: it has this meaning only right after a `.` and before `(`. There are no closures: `&name` does not capture variables. The checker requires `name` to be a declared function and compares parameters and return type with the expected type. Precedence 1, like the named call.
- **Bare `TYPE_NAME`:** without `(` or `.`, it is a type used as an argument, as in `JSON.decode(text, User)`. The checker accepts it only as an argument of the builtin functions that ask for it (`JSON.decode`, `JSON.schema`); anywhere else it is an error.
- **Types:** `Fn[A, ..., R]` (the final type is the return, phase 5j), `Json`, `Socket`, `Listener`, `Process`, and `Response` (builtin struct with `status`, `body`, and `headers`). Opaque types cannot be built or inspected, only passed to builtin functions.
- **Names reserved when each phase starts:** `Fn`, `Json`, `Socket`, `Listener`, `Process`, `Response`, `JSON`, `TCP`, and `HTTP`.

```ruby
def double(n: Int) -> Int
  return n * 2
end

def main() -> Nil
  f: Fn[Int, Int] = &double
  puts(String.from_int(f.call(21)))
  if String.contains?("agentica", "gent")
    puts("found")
  end
end
```

Programs that phase must reject:

```ruby
x = User               # A type is valid only as an argument of JSON.decode or JSON.schema.
f = &missing           # &name requires a declared function.
ready = done?          # A function name is not a value; use &name when phase 5j lands.
```

## 5. `Enum` module and list building

Today a program cannot build or sort a list: lists are immutable and the only list function is `List.size`. There is no append, concatenation, slice, reverse, or sort, and no way to pass a function. Many ordinary programs (sort these numbers, double every element, sum a list) cannot be written. This section fixes that with an Elixir-like `Enum` module. Not part of the core until its phase lands.

**Depends on function values** (section 4, phase 5j): `Enum.map`, `Enum.filter`, `Enum.reduce`, and `Enum.sort_by` take a function, written `&name` and called by the module. Without closures, a function cannot capture variables; extra state travels as an argument (`reduce` already passes the accumulator).

```text
Enum.map(list: List[A], f: Fn[A, B]) -> List[B]
Enum.filter(list: List[A], f: Fn[A, Bool]) -> List[A]
Enum.reduce(list: List[A], initial: B, f: Fn[B, A, B]) -> B     # f(accumulator, item)
Enum.sort(list: List[T]) -> List[T]                               # T is Int, Float, or String
Enum.sort_by(list: List[A], key: Fn[A, K]) -> List[A]             # K is Int, Float, or String; stable
Enum.reverse(list: List[T]) -> List[T]
Enum.concat(a: List[T], b: List[T]) -> List[T]
Enum.append(list: List[T], item: T) -> List[T]                    # a new list; the original is unchanged
Enum.take(list: List[T], count: Int) -> List[T]
Enum.drop(list: List[T], count: Int) -> List[T]
Enum.at(list: List[T], index: Int) -> T                           # out of range is RUNTIME-INDEX-OUT-OF-RANGE
Enum.count(list: List[T]) -> Int
Enum.sum(list: List[Int]) -> Int
Enum.member?(list: List[T], item: T) -> Bool                      # T is a primitive type
Enum.any?(list: List[A], f: Fn[A, Bool]) -> Bool
Enum.all?(list: List[A], f: Fn[A, Bool]) -> Bool
```

Companions for maps, so a map can be traversed and rebuilt without tuples:

```text
Map.values(map: Map[K, V]) -> List[V]                             # insertion order, like Map.keys
Map.get(map: Map[K, V], key: K, default: V) -> V
Map.delete(map: Map[K, V], key: K) -> Map[K, V]
```

Rules:

- The functions are generic and builtin, special-cased in the checker like `List` and `Map`. No user generics.
- `Enum.sort` and `Enum.sort_by` need an ordered element type: `Int`, `Float`, or `String`. Strings compare by Unicode code point; `Float` uses IEEE 754 order with a NaN placed last. Any other type is a `CHECK-TYPE-MISMATCH`. A `sort_by` key may not be a struct.
- The sort is stable.
- `Enum.reduce` passes the accumulator first: `f(accumulator, item)`. (Elixir passes the item first; Agentica chooses the accumulator first so the call reads like a left fold. Decide before the phase starts.)
- A function argument is checked exactly: parameter and result types must match (`CHECK-TYPE-MISMATCH` otherwise), as for any `Fn` value.
- All functions return a new list. `List.size` stays; `Enum.count` is the same thing and `List.size` may become an alias, or be dropped.
- Name clash to settle first: the future sum-type keyword is `enum` (section 2) and this module is `Enum`. They differ in case and position (keyword versus module name), but an agent may confuse them. Alternatives: rename the module to `Lists`, or the keyword to `variants`.
- Cost: each function copies, so `Enum.append` in a loop is O(n²). Acceptable for the prototype; a persistent vector is a later optimization (see the roadmap's "Later extensions").

Example, once phase 5j and this phase exist:

```ruby
def double(n: Int) -> Int
  return n * 2
end

def add(total: Int, n: Int) -> Int
  return total + n
end

def main() -> Nil
  numbers = [3, 1, 2]
  sorted = Enum.sort(numbers)
  doubled = Enum.map(sorted, &double)
  puts(String.from_int(Enum.reduce(doubled, 0, &add)))
end
```

Order of work: function values first (5j), then `Enum.append`, `Enum.concat`, `Enum.reverse`, `Enum.take`, `Enum.drop`, `Enum.at`, then `Enum.map`, `Enum.filter`, `Enum.reduce`, then `Enum.sort` and `Enum.sort_by`, then the `Map` companions. Each step needs the builtins catalog (phase 5e) so the checker, the evaluator, and the skill reference stay in sync.

### Other gaps for code-challenge programs

Besides `Enum`, function values (5j), and the builtins catalog (5e), these are missing. Check each against a real task in 6b before building it.

- **Math:** `abs`, `min`, `max`, `pow`, `sqrt`, `floor`, `ceil`, `gcd`.
- **Conversion:** `Int` to `Float` and back (for example `Float.from_int`, `Float.to_int`).
- **Strings:** the character at an index, a character code, `reverse`, `index_of`.
- **Maps and sets:** `Map.get` with a default, `Map.delete`, `Map.values` (above); a set type, or `Map[T, Bool]` as the documented way; stack, queue, and priority queue.
- **Input:** a helper for lines of integers; IO.gets/IO.gets!, Result, and try already handle line reads and EOF.
- **Structures:** tuples or pairs, and nested lists and matrices (check that `List[List[Int]]` works end to end).
- **Performance:** every `Map.put` and list update copies, so a loop of 10^5 steps is O(n²). Needs a persistent vector and map ("Faster maps" in the roadmap).
- **To verify:** the recursion depth the evaluator allows, and the integer range (arbitrary precision today in Racket; most challenges assume 64 bits).
- **Outside the language:** online judges do not accept Agentica, so challenges run locally against hidden cases, as in `tests/eval/`. The interpreter is a tree walker on Racket, so judge time limits are tight.

## 6. Native runtime

For a later native runtime, procedural C++20, structs and free functions, the Boehm GC, and, later, libevent have been considered. Those decisions are not part of the grammar and must not appear in Agentica programs.

Integrating the C++ host with a C library does not by itself solve the FFI of Agentica: an interpreter needs native wrappers or a call layer that respects the ABI. Including libevent does not automatically provide fibers or actors either.

For now we do not introduce interfaces, traits, inheritance, JIT, distribution, or parallelism. The semantics of the language must be preserved when the AST evaluator is replaced by a future VM.

## 7. Possible metatables: Ruby-style modules

Exploratory only: no implementation or phase is assigned. Group shared behavior visually, then attach it to maps, lists, or records. Prefer Ruby's `module ... end`, `def ... end`, `self`, and `.extend(...)` over new spellings such as `defmod` or Elixir's `defmodule`. Borrow Elixir's immutable-value approach and keep static checking; adopting this syntax does not require classes or inheritance.

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

The same idea could give a list named methods without changing its normal indexing:

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

- A module holds shared methods, not per-object state. A method's `self` is the attached receiver; methods can call sibling methods through `self`.
- Unlike Ruby's mutating `extend`, the candidate Agentica form returns a new immutable wrapper. The original value is unchanged. Module selection and method signatures must be known to the checker; incompatible receivers and unknown methods are check errors.
- Normal map/list indexing, insertion order, and missing-key/index diagnostics stay unchanged initially. Attachment adds behavior; it does not make collection lookup faster or combine List and Map into a mixed PHP-style array.
- Lua-style fallback lookup (`__index`), custom indexing, operators, or callable objects could be a later layer. Decide which typed hooks are useful before adding them; do not make every lookup run arbitrary callbacks by default.

Open decisions before implementation:

- How receiver, argument, and result types are declared while keeping Ruby-parsable syntax: signature comments or a separate RBS-style file are possibilities, not decisions.
- The static type of an attached value, visibility, method collisions, multiple modules, and whether collection operations preserve attached behavior.
- Whether `.extend(Module)` is sufficient or an explicit `Meta.attach(value, Module)` API is also needed. Prefer one spelling, not both without a real need.
- Name resolution for bare module arguments and how module namespaces relate to records and future imports.

**Ruby tooling goal, not a compatibility promise:** existing Agentica `->` signatures and `struct` declarations are not Ruby syntax. The examples use `=>` for String-keyed maps; Ruby's `{"name": value}` creates a Symbol key, unlike Agentica's current map literal. Reusing Ruby linters such as RuboCop requires a Ruby-parsable source subset or a translation step, plus configuration for Agentica conventions. Verify that with real tooling before claiming support. None of these spellings or type alternatives changes the core grammar today.
