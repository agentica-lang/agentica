# Agentica: grammar and language design

Status: implemented by the interpreter: the single binary `agentica`, a C VM (`vm/`) that runs every program, with a front end written in Agentica (`compiler/`) inside it that compiles to bytecode. The Racket front end (`src/`) stays only as a development oracle until it is deleted. This document describes what the interpreter accepts; remaining proposals live in [`future/`](../future/README.md).

## 1. What we want to validate

Agentica is a small statically typed language that AI agents can write, read and fix. This specification fixes its syntax, its rules and its diagnostics.

## 2. Design decisions

Each rule is stated once, in the section for its topic: lexical rules in §4, syntax and modules in §5, meaning and builtins in §6, and diagnostics in §7.

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

The executable starts by calling `main()`. The top level holds only declarations; there are no executable statements there.
