---
title: Style guide
weight: 5
description: How to write Agentica code that is simple and easy to read, with a bad and a good example for each rule.
---

Code is read far more often than it is written. This guide keeps Agentica code simple and easy to read, in the spirit of the Ruby and Elixir style guides. When a rule gets in the way of clear code, clear code wins. Restyle only the code you touch.

Some rules are enforced: the program does not compile when it breaks them. Their examples are marked "Does not compile" and show the error code.

## Layout

Indent with two spaces. No tabs, no trailing spaces, and one newline at the end of the file.

Keep lines at 119 characters or less, comments included. Wrap a long call or list with one item per line and a trailing comma:

```agentica {mode="check"}
# good
struct User
  name: String
  age: Int
  email: String
end

def main() -> Void
  user = User(
    name: "Ana",
    age: 25,
    email: "ana@example.com",
  )
  puts(user.name)
end
```

Wrap a long expression in parentheses. Never continue an expression on a bare line:

```agentica {mode="check"}
# good
def label(first: String, last: String, title: String) -> String
  return (
    "#{title} #{first} #{last}, " +
    "member of the board since 2001"
  )
end

def main() -> Void
  puts(label("Ana", "Diaz", "Dr."))
end
```

Put spaces around operators and after commas, but not around `..` and `...` or inside brackets or parentheses: `total(a, b) + 1`, `[1, 2, 3]`, `0..9`.

Separate top-level declarations with one blank line. Do not put blank lines right after `def` or before `end`, or two blank lines in a row.

```agentica {expect="PARSE-MISSING-BLANK-LINE"}
# bad
def one() -> Int
  return 1
end
def main() -> Void
  puts(one())
end
```

## Naming

| What | Style | Example |
|---|---|---|
| functions, variables, fields, files | `snake_case` | `read_line`, `max_len`, `http_client.agc` |
| structs, enums, variants | `CamelCase` | `User`, `Shape.Circle` |
| constants | `UPPER_SNAKE_CASE` | `MAX_TRIES` |

The first letter is enforced, and so is a constant in capitals:

```agentica {expect="PARSE-CONSTANT-NAME"}
# bad
Limit = 10

def main() -> Void
  puts(Limit)
end
```

A function that returns a `Bool` ends in `?` and reads as a question. Do not use an `is_` prefix:

```agentica {mode="check"}
# bad
def is_blank(text: String) -> Bool
  return text.length == 0
end

def main() -> Void
  puts(is_blank(""))
end
```

```agentica {mode="check"}
# good
def blank?(text: String) -> Bool
  return text.length == 0
end

def main() -> Void
  puts(blank?(""))
end
```

A name that ends in `!` stops the program instead of returning a `Result`. Give a function a `!` only when it does that.

Name things by what they mean, not by their type: `price`, not `int_value`. Name a number that has a meaning, and use `_` in big numbers:

```agentica {mode="check"}
# bad
def too_big?(bytes: Int) -> Bool
  return bytes > 1048576
end

def main() -> Void
  puts(too_big?(2048))
end
```

```agentica {mode="check"}
# good
MAX_BYTES = 1_048_576

def too_big?(bytes: Int) -> Bool
  return bytes > MAX_BYTES
end

def main() -> Void
  puts(too_big?(2048))
end
```

Say it positively. Put the positive case first and do not pair a negated test with `else`:

```agentica {mode="check"}
# bad
def describe(hidden: Bool) -> String
  if !hidden
    return "shown"
  else
    return "hidden"
  end
end

def main() -> Void
  puts(describe(false))
end
```

```agentica {mode="check"}
# good
def describe(visible: Bool) -> String
  if visible
    return "shown"
  end
  return "hidden"
end

def main() -> Void
  puts(describe(true))
end
```

## Files and docs

A file has a fixed order: its doc and imports, constants, structs, enums and type aliases, exported functions, then private functions. Sort imports by path. A constant is imported by name (`import {LIMIT} from "limits"`) and the rest through the alias; a file may import one module both ways.

```agentica {expect="CHECK-DECL-ORDER"}
# bad
def main() -> Void
  puts("x")
end

struct Item
  name: String
end
```

Keep one topic per file, and export only the names that other files use.

Document as little as possible. Only public code gets a `##` doc: an exported function, struct or enum, saying what it returns or is, not how. A private function never gets `##`; when it needs a note, use one `#` comment. A field or variant gets a note only when its name does not say enough. A `#` comment says why the code is the way it is, not what the next line does:

```agentica {mode="check"}
# bad
## This function loops over the prices and adds them up.
def total(prices: List[Int]) -> Int
  sum = 0
  # add each price to sum
  for price in prices
    sum += price
  end
  return sum
end

def main() -> Void
  puts(total([250, 199]))
end
```

```agentica {mode="check"}
# good
## Returns the sum of the prices, in cents.
export def total(prices: List[Int]) -> Int
  sum = 0
  for price in prices
    sum += price
  end
  return sum
end

def main() -> Void
  puts(total([250, 199]))
end
```

Delete code instead of commenting it out.

## Functions

Give each function one job. If comments split it into parts, split it into functions.

Use four parameters or fewer. Put more in a struct. Return early on bad cases, so the main path stays flat:

```agentica {mode="check"}
# bad
def ship(weight: Int, width: Int, height: Int, depth: Int, rush: Bool) -> Int
  cost = 0
  if weight > 0
    if width > 0
      if rush
        cost = weight * 3
      else
        cost = weight * 2
      end
    end
  end
  return cost
end

def main() -> Void
  puts(ship(2, 10, 10, 10, true))
end
```

```agentica {mode="check"}
# good
struct Parcel
  weight: Int
  width: Int
  height: Int
  depth: Int
  rush: Bool
end

def ship(parcel: Parcel) -> Int
  if parcel.weight <= 0 or parcel.width <= 0
    return 0
  end
  if parcel.rush
    return parcel.weight * 3
  end
  return parcel.weight * 2
end

def main() -> Void
  puts(ship(Parcel(weight: 2, width: 10, height: 10, depth: 10, rush: true)))
end
```

A record with known fields is a struct, not a map:

```agentica {mode="check"}
# bad
def greet(user: Map[String, String]) -> String
  return "hello #{user.get("name").unwrap_or("?")}"
end

def main() -> Void
  puts(greet({"name": "Ana"}))
end
```

```agentica {mode="check"}
# good
struct User
  name: String
end

def greet(user: User) -> String
  return "hello #{user.name}"
end

def main() -> Void
  puts(greet(User(name: "Ana")))
end
```

Use a `for` loop for a running total, and a method such as `map` to transform a list. A block cannot assign a variable from outside it:

```agentica {expect="CHECK-CAPTURED-ASSIGNMENT"}
# bad
def main() -> Void
  sum = 0
  [1, 2].each do |x|
    sum += x
  end
  puts(sum)
end
```

```agentica {mode="check"}
# good
def main() -> Void
  sum = 0
  for x in [1, 2]
    sum += x
  end
  puts(sum)
  puts([1, 2].map do |x| x * 2 end)
end
```

Use a `Bool` as it is, with `and`, `or` and `not`:

```agentica {mode="check"}
# bad
def allowed(admin: Bool, banned: Bool) -> Bool
  if admin == true && banned == false
    return true
  end
  return false
end

def main() -> Void
  puts(allowed(true, false))
end
```

```agentica {mode="check"}
# good
def allowed?(admin: Bool, banned: Bool) -> Bool
  return admin and not banned
end

def main() -> Void
  puts(allowed?(true, false))
end
```

## if and case

Use `if` for a yes-or-no question. Use `case` for an enum, a `Result`, or three or more branches on one value:

```agentica {mode="check"}
# bad
def size_name(n: Int) -> String
  if n == 0
    return "empty"
  elsif n == 1
    return "one"
  else
    return "many"
  end
end

def main() -> Void
  puts(size_name(3))
end
```

```agentica {mode="check"}
# good
def size_name(n: Int) -> String
  case n
    0 -> return "empty"
    1 -> return "one"
    _ -> return "many"
  end
end

def main() -> Void
  puts(size_name(3))
end
```

Name an enum for states instead of passing number codes:

```agentica {mode="check"}
# bad
def color_name(code: Int) -> String
  if code == 0
    return "red"
  elsif code == 1
    return "green"
  end
  return "unknown"
end

def main() -> Void
  puts(color_name(1))
end
```

```agentica {mode="check"}
# good
enum Color
  Red
  Green
end

def color_name(color: Color) -> String
  case color
    Color.Red -> return "red"
    Color.Green -> return "green"
  end
end

def main() -> Void
  puts(color_name(Color.Green))
end
```

List every variant of a small enum in `case` and leave out `_`, so that a new variant fails the check where it must be handled. A `_` is fine when many variants share one outcome:

```agentica {mode="check"}
# bad
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> return r * r * 3
    _ -> return 0
  end
end

def main() -> Void
  puts(area(Shape.Circle(2)))
end
```

```agentica {mode="check"}
# good
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> return r * r * 3
    Shape.Dot -> return 0
  end
end

def main() -> Void
  puts(area(Shape.Circle(2)))
end
```

Leaving a variant out with no `_` does not compile:

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
# bad
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> return r * r * 3
  end
end

def main() -> Void
  puts(area(Shape.Dot))
end
```

## Pipes

Use a pipe for three or more steps on one value. Start with the value, and put one step per line inside parentheses:

```agentica {mode="check"}
# bad
def shout(text: String) -> String
  return text.upcase
end

def wrap(text: String, mark: String) -> String
  return "#{mark}#{text}#{mark}"
end

def banner(text: String) -> String
  out = shout(text)
  out = wrap(out, "*")
  out = wrap(out, " ")
  return out
end

def main() -> Void
  puts(banner("hi"))
end
```

```agentica {mode="check"}
# good
def shout(text: String) -> String
  return text.upcase
end

def wrap(text: String, mark: String) -> String
  return "#{mark}#{text}#{mark}"
end

def banner(text: String) -> String
  return (
    text
    |> shout()
    |> wrap("*")
    |> wrap(" ")
  )
end

def main() -> Void
  puts(banner("hi"))
end
```

One step is a plain call: `shout(text)`, not `text |> shout()`. A builtin that has a method form takes a `.` instead of a pipe:

```agentica {expect="CHECK-PIPE-METHOD"}
# bad
def main() -> Void
  puts("x" |> String.upcase())
end
```

## Errors

A function that can fail returns a `Result` and passes errors up with `try`. Use a halting form such as `to_i!` only when a failure is a bug, and say why in a comment:

```agentica {mode="check"}
# bad
def double_text(text: String) -> Int
  return text.to_i! * 2
end

def main() -> Void
  puts(double_text("21"))
end
```

```agentica {mode="check"}
# good
def double_text(text: String) -> Result[Int]
  n = try text.to_i
  return ok(n * 2)
end

def main() -> Void
  case double_text("21")
    ok(n) -> puts(n)
    error(message) -> IO.warn(message)
  end
end
```

Write error text in lowercase, without a final period, and include the bad value. Handle errors at the edge of the program, such as `main` or a request handler:

```agentica {mode="check"}
# bad
def parse_port(text: String) -> Result[Int]
  n = try text.to_i
  if n < 1 or n > 65535
    return error("Invalid port.")
  end
  return ok(n)
end

def main() -> Void
  puts(parse_port("70000").unwrap!)
end
```

```agentica {mode="check"}
# good
def parse_port(text: String) -> Result[Int]
  n = try text.to_i
  if n < 1 or n > 65535
    return error("port out of range: #{n}")
  end
  return ok(n)
end

def main() -> Void
  case parse_port("70000")
    ok(n) -> puts("port #{n}")
    error(message) -> IO.warn(message)
  end
end
```

## Text and collections

Build text with interpolation, not by joining pieces with `+` and `.to_s`. To wrap a long text, a few sentence-sized `+` pieces in parentheses are fine. Use a heredoc for text of several lines:

```agentica {mode="check"}
# bad
def line(name: String, count: Int) -> String
  return name + ": " + count.to_s + " items"
end

def main() -> Void
  puts(line("cart", 3))
end
```

```agentica {mode="check"}
# good
def line(name: String, count: Int) -> String
  return "#{name}: #{count} items"
end

def help() -> String
  return <<~TEXT
    usage: tool FILE
    prints the lines of FILE
  TEXT
end

def main() -> Void
  puts(line("cart", 3))
  puts(help())
end
```

Use a `List` for order, a `Set` for membership, a `Map` for lookup by key, and a struct for a record with known fields.
