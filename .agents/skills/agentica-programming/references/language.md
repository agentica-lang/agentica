# Agentica language reference

Agentica is a small statically typed language with Ruby-like syntax. This file is the whole language: if a form is not here, it does not exist.

## Program shape

- A file has only top-level `def` and `struct` declarations. No statements at the top level.
- It needs exactly one `def main() -> Nil` with no parameters. Running a program calls `main()`.
- Blocks end with `end`. Indentation is for reading only.
- `#` starts a comment that runs to the end of the line.
- Calls always use parentheses, even with no arguments: `main()`, `puts("hi")`.
- A newline ends a statement. Inside `(...)`, `[...]`, and `{...}` an expression may span lines, and a trailing comma is allowed. To split a long expression, wrap it in parentheses.
- Reserved words: `def struct end if elsif else while for in return true false nil and or not`.

Full programs are at the end of this file.

## Types

| Type | Notes |
|---|---|
| `Int` | signed 64-bit; overflow is a runtime error |
| `Float` | IEEE 754 double |
| `Bool` | `true` / `false` only |
| `String` | Unicode text |
| `Nil` | the single value `nil`; the result of functions that return nothing |
| `List[T]` | homogeneous, immutable, indexed from 0 |
| `Map[K, V]` | homogeneous, immutable; `K` is `Int` or `String`; keeps insertion order |
| `Name` | a struct you declare; fields are typed and immutable |

Type names start with an uppercase letter. Variable, function, and field names start with a lowercase letter or `_`.

## Declarations

```ruby
struct User
  name: String
  age: Int
end

def greet(user: User, times: Int) -> String
  return user.name
end
```

- Every parameter and the return type need an annotation.
- Struct and function declarations are top level only. There are no methods, closures, nested functions, default arguments, or overloading.
- Functions can be called before they are declared, and can be recursive.
- A function whose result is not `Nil` must `return` on every path. A loop does not count as a return. The last expression is not returned implicitly.
- `return` alone is `return nil`. Reaching the end of a `-> Nil` function returns `nil`.

## Statements

```ruby
count = 0              # new variable, type inferred (Int)
total: Float = 0.5     # new variable with an annotation
count = count + 1      # update: same name, same type

if count > 3
  puts("big")
elsif count > 1
  puts("medium")
else
  puts("small")
end

while count < 10
  count = count + 1
end

for item in items      # items is a List[T]; item is a new, read-only variable
  puts(item)
end

return count
```

- The first assignment to a name creates it in the current block; later assignments change its value and cannot change its type.
- An annotation is only allowed when the variable is created.
- A name created in a block is not visible after that block's `end`.
- A new variable cannot reuse a name that is already visible in an outer scope (no shadowing).
- The `for` variable cannot be assigned to.
- `if` and `while` conditions must be `Bool`. There is no truthiness: `if 1` is an error.
- Assignment is a statement, not an expression. There is no `x[i] = v`, `x.f = v`, `+=`, `break`, or `continue`.

## Expressions

- Literals: `42`, `3.14`, `"text"` (escapes `\" \\ \n \r \t`), `true`, `false`, `nil`. A minus sign is an operator, not part of the literal. There is no string interpolation: `"#{x}"` is plain text.
- Lists: `[1, 2, 3]`. Maps: `{"a": 1, "b": 2}` (a repeated key keeps the last value).
- An empty `[]` or `{}` needs a known type: an annotation, a parameter, a field, or the function result. A non-empty list needs elements of one type.
- Struct construction uses named fields, all of them exactly once, in any order: `User(name: "Ana", age: 25)`.
- Field access `user.name`; index `items[0]` and `stock["apple"]`. Strings cannot be indexed.
- Function call `f(a, b)` with positional arguments. Builtin module call `String.upcase(s)`.

Operators, from highest to lowest precedence:

| Level | Operators |
|---|---|
| 1 | call, `.field`, `[index]`, `( )` |
| 2 | unary `-`, `not` |
| 3 | `*` `/` `%` |
| 4 | `+` `-` |
| 5 | `<` `<=` `>` `>=` |
| 6 | `==` `!=` |
| 7 | `and` |
| 8 | `or` |

- `+ - * /` take two numbers of the same type. There is no implicit conversion between `Int` and `Float`. `+` also joins two `String` values.
- `/` on `Int` truncates toward zero. `%` takes two `Int` values. A zero divisor is a runtime error, also for `Float`.
- `< <= > >=` take two numbers of the same type.
- `==` and `!=` take two values of the same primitive type (`Int`, `Float`, `Bool`, `String`, `Nil`). Lists, maps, and structs cannot be compared.
- Comparisons do not chain: write `a < b and b < c`, not `a < b < c`.
- `and`, `or`, `not` take `Bool`, and `and` / `or` short-circuit. `not` binds tightly: write `not (a >= b)`.
- Arguments and operands are evaluated left to right.

## Builtin functions

`puts(value: String) -> Nil` writes the text and a newline. The names `puts`, `Int`, `Float`, `Bool`, `String`, `Nil`, `List`, `Map`, `IO`, and `System` are reserved.

```text
Map.has_key?(map: Map[K, V], key: K) -> Bool
Map.keys(map: Map[K, V]) -> List[K]            # insertion order
Map.size(map: Map[K, V]) -> Int
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]   # returns a new map
List.size(list: List[T]) -> Int

String.length(s: String) -> Int                # counts Unicode characters
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.to_int!(s: String) -> Int               # halts on bad text
String.to_float!(s: String) -> Float           # halts on bad text

IO.puts(value: String) -> Nil
IO.print(value: String) -> Nil                 # no newline
IO.warn(value: String) -> Nil                  # standard error
IO.inspect(value: T) -> T                      # prints a debug form, returns the value
IO.gets() -> String                            # next line; halts at end of input
IO.read() -> String
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Nil
```

- A `?` or `!` suffix belongs to a function name only when `(` follows right away: `String.contains?(a, b)`. By convention `?` means the function returns `Bool`, and `!` means it halts the run on failure.
- Lists have no append or concatenation function. To build a list, write a literal; to change a map, use `Map.put`.
- Reading a missing map key, an index outside `0 .. length - 1`, or a bad `String.slice` range is a runtime error.

## Diagnostics

A failure prints to stderr and exits 1 (the run stops at the first error):

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The code prefix is the stage: `LEX-` (characters), `PARSE-` (syntax), `CHECK-` (names and types, before running), `RUNTIME-` (while running).

| Code | Meaning |
|---|---|
| `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER` | bad character, string, or bracket |
| `PARSE-UNEXPECTED-TOKEN` | the parser expected something else here |
| `PARSE-UNCLOSED-BLOCK` | missing `end` |
| `PARSE-TOP-LEVEL-STATEMENT` | a statement outside a function |
| `PARSE-CHAINED-COMPARISON` | `a < b < c` |
| `PARSE-INVALID-ASSIGNMENT-TARGET` | assignment to an index or field |
| `CHECK-TYPE-MISMATCH` | a value, operand, condition, argument, or return has the wrong type |
| `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD` | a name, type, or field that does not exist |
| `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING` | duplicate declaration, shadowing, annotation on an existing name |
| `CHECK-ARITY` | wrong number of arguments |
| `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD` | struct construction fields |
| `CHECK-EMPTY-LIST-TYPE` | an empty `[]` or `{}` with no expected type |
| `CHECK-MISSING-RETURN` | a path without `return` in a non-`Nil` function |
| `CHECK-MAIN` | missing or wrong `main` |
| `CHECK-NOT-A-STRUCT`, `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST` | field access on a non-struct, index on a non-list/map, `for` over a non-list |
| `CHECK-MAP-KEY-TYPE` | a map key that is not `Int` or `String` |
| `CHECK-IMMUTABLE-ASSIGNMENT` | assignment to a `for` variable |
| `CHECK-INT-RANGE` | an integer literal that does not fit in `Int` |
| `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW` | arithmetic failure |
| `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND` | list index or map key not present |
| `RUNTIME-INVALID-NUMBER` | `String.to_int!` / `String.to_float!` on bad text |
| `RUNTIME-END-OF-INPUT` | `IO.gets` with no input left |
| `RUNTIME-STACK-OVERFLOW` | recursion too deep |

## Complete programs

Control flow and functions:

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

def main() -> Nil
  puts(classify(25))
end
```

Structs and lists:

```ruby
struct Task
  title: String
  done: Bool
end

def main() -> Nil
  tasks: List[Task] = [
    Task(title: "write code", done: false),
    Task(title: "review code", done: true)
  ]

  for task in tasks
    if not task.done
      puts(task.title)
    end
  end
end
```

Maps and strings:

```ruby
def main() -> Nil
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = Map.put(stock, "kiwi", 7)
  for name in Map.keys(stock)
    if stock[name] > 0
      puts(String.upcase(name) + ": " + String.from_int(stock[name]))
    end
  end
end
```
