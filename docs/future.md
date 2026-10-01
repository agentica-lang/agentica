# Agentica: future grammar

Status: proposal. Nothing in this document is implemented or normative. The language the interpreter runs is in [`grammar.md`](grammar.md).

Working rule: when a phase of the [`roadmap.md`](roadmap.md) finishes, its syntax moves from this document to sections 4–6 of `grammar.md` and is deleted from here.

## 1. Planned changes to the current library

- `IO.gets() -> Result[String]` and `IO.gets!() -> String`. Today `IO.gets` returns `String` and fails with `RUNTIME-END-OF-INPUT`; the change is settled in phase 5d2 so we do not teach a form that 5e would break.
- `CHECK-EMPTY-MAP-TYPE` for a `{}` with no expected type. Today it uses `CHECK-EMPTY-LIST-TYPE`.
- The non-`!` forms of `String.to_int` and `String.to_float` return `Result[...]` (phase 5e).

## 2. Enums and pattern matching

This section documents the direction already discussed. It is not part of the initial core and requires extending the lexer, parser, checker, and evaluator.

```ruby
enum Result[T, E]
  Ok(T)
  Err(E)
end

enum Option[T]
  Some(T)
  None
end

def label(result: Result[String, String]) -> String
  case result
  in Ok(value)
    return value
  in Err(error)
    return error
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
| Error propagation | `value = try find_user(42)` | Phase 5e: `try` returns the error from the current function, which must return `Result[...]` |
| Function generics | Reuse functions with different types | Syntax, inference, and constraints |
| Closures and methods | Better ergonomics | Capture, representation, and resolution |
| Modules | Split programs into files | Import, visibility, and cycles |
| C FFI | Safe wrappers over native calls | Pointers, ownership, ABI, and calls from the interpreter |
| Async and fibers | Suspend execution on I/O; initially one thread | API, cancellation, and error propagation |
| Actors | Own messages and mailboxes | Syntax, isolation, shared values, and supervision |

## 4. Standard library and function values (phases 5e–5m)

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
- **Types:** `Fn[A, ..., R]` (the final type is the return, phase 5j), `Result[T]` (the error is always `String`), `Json`, `Socket`, `Listener`, `Process`, and `Response` (builtin struct with `status`, `body`, and `headers`). Opaque types cannot be built or inspected, only passed to builtin functions.
- **Names reserved when each phase starts:** `Fn`, `Result`, `Json`, `Socket`, `Listener`, `Process`, `Response`, `JSON`, `TCP`, and `HTTP`.

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
ok = done?             # The ? suffix exists only when followed by "(".
```

## 5. Native runtime

For a later native runtime, procedural C++20, structs and free functions, the Boehm GC, and, later, libevent have been considered. Those decisions are not part of the grammar and must not appear in Agentica programs.

Integrating the C++ host with a C library does not by itself solve the FFI of Agentica: an interpreter needs native wrappers or a call layer that respects the ABI. Including libevent does not automatically provide fibers or actors either.

For now we do not introduce interfaces, traits, inheritance, JIT, distribution, or parallelism. The semantics of the language must be preserved when the AST evaluator is replaced by a future VM.
