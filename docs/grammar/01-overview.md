# Agentica: grammar and language design

Status: implemented by the interpreter: a Racket front end (`src/`) that compiles to bytecode for the C VM (`vm/`), which runs every program. This document describes what the interpreter accepts; remaining proposals live in [`future/`](../future/README.md).

## 1. What we want to validate

Agentica is a language designed so AI agents can write, read, and fix programs easily. The priority is to experiment with the syntax, the rules, and the diagnostics. Performance, concurrency, and the final runtime come later.

The direction is KISS: Ruby-like syntax, static types, local inference, and few ways to express each operation. This specification does not depend on the language the interpreter is written in.

## 2. Design decisions

| Aspect | Rule |
|---|---|
| Syntax | `def`, `struct`, `enum`, `case`, `if`, `while`, `for`, `end`; blocks end with `end` |
| Types | Static, with local inference where it is evident |
| Calls | Parentheses are required |
| Signatures | Explicit return type and required annotations |
| Data | Variables can be reassigned; lists, maps, and structs are immutable |
| Numbers | 64-bit `Int`, no implicit conversions |
| Names | Function names may end in `?` (predicate) or `!` (halting form), independently of whitespace before `(` |

Generic enums and exhaustive `case` matching are part of the current language. Other proposals remain in [`future/`](../future/README.md).

## 3. A core program

```ruby
struct User
  name: String
  age: Int
end

def is_adult(user: User) -> Bool
  return user.age >= 18
end

def main() -> Void
  users = [
    User(name: "Ana", age: 25),
    User(name: "Luis", age: 16)
  ]

  for user in users
    if is_adult(user)
      puts(user.name)
    end
  end
end
```

Blocks end with `end`. Indentation helps reading but does not determine structure. Calls use parentheses, even when they take no arguments; only builtin methods, and module functions without arguments (builtin or reached through an import alias), may drop them (`s.length`, `IO.gets!`, `Util.reset`). Structs are built with named fields; ordinary functions take positional arguments.

The executable starts by calling `main()`. The core has no executable statements at the top level, only declarations. This avoids having two different entry models.

## 8. Examples to review the design

### Function and control flow

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Void
  puts(classify(25))
end
```

### Programs that must be rejected

```ruby
age: Int = "25"        # Incompatible types.
if 1                   # The condition must be Bool.
  puts("hello")
end
values = []            # Missing expected type for the empty list.
puts "hello"           # The call requires parentheses.
```

These statements are shown as function body fragments. At the top level they would also be invalid because they are not declarations.

## 9. Guide for whoever implements the prototype

Implement the rules of sections 4–6 first. Keep the grammar, the AST, the checker, the VM, and the builtin functions independent. Do not generate host code without preserving the rules of Agentica: for example, `if 1` must be rejected even if the host accepts truthiness.

If a rule turns out to be too costly, change this specification and the examples explicitly before creating a silent exception. The goal is that any agent can consult a short document and predict the behavior of a program.

The first evaluation of the language should measure correct programs, attempts needed, and how useful the errors are. Run time can be measured later; the first question is whether the syntax and the rules help agents produce and repair code.
