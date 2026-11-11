# Agentica: grammar and language design

Implemented by the interpreter: the single binary `agentica`, a C VM (`vm/`)
that runs every program, with a front end written in Agentica (`compiler/`)
inside it that compiles to bytecode. This document describes what the
interpreter accepts; planned work lives in GitHub issues.

## 1. What we want to validate

Agentica is a small statically typed language that AI agents can write, read and
fix. This specification fixes its syntax, its rules and its diagnostics.

## 2. Design decisions

Each rule is stated once, in the section for its topic: lexical rules in §4,
syntax and modules in §5, meaning and builtins in §6, and diagnostics in §7.

Agentica is "Ruby with types" for LLM agents. A form is accepted when it is real
Ruby (or a typed version of it) or makes Agentica consistent with itself,
keeping static checking and immutable values. A form from another language is
not accepted: its help names the Agentica form. Two limits do not move: no OOP
(no classes, inheritance or user methods on user types) and immutable values.

**One way to do each thing.** Strictness wins, so agents are precise. A Ruby
form is added only when it does not create a second way to write something the
language already has; otherwise the parser or the checker gives a diagnostic
whose help shows the canonical form.

**No warnings.** A diagnostic is an error or it does not exist (§7): a warning
means "wrong, but allowed", a second accepted way, and agents ignore warnings.
A new check is an error with a stable code, and only when the case is almost
always a mistake and the fix is local and mechanical. Nothing turns a check
off: the discard `_` and a name that starts with `_` are the one way to drop a
value or keep a name on purpose. Deprecation warnings may be considered only
after 1.0.

**The method test.** A method or form fails when it only renames or negates an
existing call, its callback, or a statement (an alias, `reject` for `filter`
with `!`, `unless` for `if !`), or re-spells one call or statement. A method
passes when the composition it replaces needs a loop, several calls, or a seed
value or typed accumulator the caller would otherwise choose. So `sum`, `find`,
`each_with_index`, `flat_map` and `Map.each` pass; `reject` and the `Range`
Enumerable methods (each is `to_a` and then one `List` call) fail.

## 3. A core program

```ruby
struct User
  name: String
  age: Int
end

def is_adult(user: User) -> Bool = user.age >= 18

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

The executable starts by calling `main()`. The top level holds only
declarations; there are no executable statements there.
