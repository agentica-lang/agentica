---
title: Style guide
weight: 5
description: How to write Agentica code that is simple and easy to read, with a bad and a good example for each rule.
---

Code is read far more often than it is written. This guide keeps Agentica code simple and easy to read, in the spirit of the Ruby and Elixir style guides. When a rule gets in the way of clear code, clear code wins.

Some rules are enforced: the program does not compile when it breaks them, and the example shows the error code. The rest are style only. Restyle only the code you touch.

## Layout

Indent with two spaces. No tabs, no trailing spaces, and one newline at the end of the file.

Keep lines at 119 characters or less, comments included. Wrap a long call or list with one item per line and a trailing comma:

```ruby
# good
return User(
  name: "Ana",
  age: 25,
  email: "ana@example.com",
)
```

Wrap a long expression in parentheses. Never continue an expression on a bare line:

```ruby
# good
return (
  "#{title} #{first} #{last}, #{suffix}, " +
  "member of the board since 2001"
)
```

Put spaces around operators and after commas, but not inside brackets or parentheses: `total(a, b) + 1`, `[1, 2, 3]`, `0..9`.

Put one blank line after the `end` of each top-level declaration. Do not put blank lines right after `def` or before `end`, or two blank lines in a row.

```agentica {expect="PARSE-MISSING-BLANK-LINE"}
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

A function that returns a `Bool` ends in `?` and reads as a question. Do not use an `is_` prefix:

```ruby
# bad
def is_blank(text: String) -> Bool
  return text.length == 0
end

# good
def blank?(text: String) -> Bool
  return text.length == 0
end
```

A name that ends in `!` stops the program instead of returning a `Result`. Give a function a `!` only when it does that.

Name things by what they mean, not by their type: `price`, not `int_value`. Name a number that has a meaning, and use `_` in big numbers:

```ruby
# bad
def too_big?(bytes: Int) -> Bool
  return bytes > 1048576
end

# good
MAX_BYTES = 1_048_576

def too_big?(bytes: Int) -> Bool
  return bytes > MAX_BYTES
end
```

Say it positively. Put the positive case first and do not pair a negated test with `else`:

```ruby
# bad
if !hidden
  return "shown"
else
  return "hidden"
end

# good
if visible
  return "shown"
end
return "hidden"
```

## Files and docs

A file has a fixed order: its doc and imports, constants, structs and enums, exported functions, then private functions.

```agentica {expect="CHECK-DECL-ORDER"}
def main() -> Void
  puts("x")
end

struct Item
  name: String
end
```

Keep one topic per file, and export only the names that other files use.

A `##` doc says what a function returns. A `#` comment says why the code is the way it is, not what the next line does:

```ruby
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

# good
## Returns the sum of the prices, in cents.
def total(prices: List[Int]) -> Int
  sum = 0
  for price in prices
    sum += price
  end
  return sum
end
```

Delete code instead of commenting it out.

## Functions

Give each function one job. If comments split it into parts, split it into functions.

Use four parameters or fewer. Put more in a struct. Return early on bad cases, so the main path stays flat:

```ruby
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

# good
def ship(parcel: Parcel) -> Int
  if parcel.weight <= 0 or parcel.width <= 0
    return 0
  end
  if parcel.rush
    return parcel.weight * 3
  end
  return parcel.weight * 2
end
```

A record with known fields is a struct, not a map:

```ruby
# bad
def greet(user: Map[String, String]) -> String
  return "hello #{user.get("name").unwrap_or("?")}"
end

# good
def greet(user: User) -> String
  return "hello #{user.name}"
end
```

Use a `for` loop for a running total, and a method such as `map` to transform a list:

```ruby
# good
def total(xs: List[Int]) -> Int
  sum = 0
  for x in xs
    sum += x
  end
  return sum
end

def doubled(xs: List[Int]) -> List[Int]
  return xs.map do |x| x * 2 end
end
```

A block cannot assign a variable from outside it:

```agentica {expect="CHECK-CAPTURED-ASSIGNMENT"}
def main() -> Void
  sum = 0
  [1, 2].each do |x|
    sum += x
  end
  puts(sum)
end
```

Use a `Bool` as it is, with `and`, `or` and `not`:

```ruby
# bad
if admin == true && banned == false
  return true
end
return false

# good
return admin and not banned
```

## if and case

Use `if` for a yes-or-no question. Use `case` for an enum, a `Result`, or three or more branches on one value:

```ruby
# bad
if n == 0
  return "empty"
elsif n == 1
  return "one"
else
  return "many"
end

# good
case n
  0 -> return "empty"
  1 -> return "one"
  _ -> return "many"
end
```

Name an enum for states instead of passing number codes. Then list every variant in `case` and leave out `_`, so that a new variant fails the check where it must be handled:

```ruby
# bad
case shape
  Shape.Circle(r) -> return r * r * 3
  _ -> return 0
end

# good
case shape
  Shape.Circle(r) -> return r * r * 3
  Shape.Dot -> return 0
end
```

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
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

Put the specific arms and guards first.

## Pipes

Use a pipe for three or more steps on one value. Start with the value, and put one step per line inside parentheses:

```ruby
# bad
out = trim_all(text)
out = shout(out)
out = wrap(out, "*")
return out

# good
return (
  text
  |> trim_all()
  |> shout()
  |> wrap("*")
)
```

One step is a plain call: `shout(text)`, not `text |> shout()`. A builtin that has a method form takes a `.` instead of a pipe:

```agentica {expect="CHECK-PIPE-METHOD"}
def main() -> Void
  puts("x" |> String.upcase())
end
```

## Errors

A function that can fail returns a `Result` and passes errors up with `try`. Use a halting form such as `to_i!` only when a failure is a bug:

```ruby
# bad
def double_text(text: String) -> Int
  return text.to_i! * 2
end

# good
def double_text(text: String) -> Result[Int]
  n = try text.to_i
  return ok(n * 2)
end
```

Write error text in lowercase, without a final period, and include the bad value:

```ruby
# bad
return error("Invalid port.")

# good
return error("port out of range: #{n}")
```

Handle errors at the edge of the program, such as `main` or a request handler:

```ruby
# good
def main() -> Void
  case parse_port("70000")
    ok(n) -> puts("port #{n}")
    error(message) -> IO.warn(message)
  end
end
```

## Text and collections

Build text with interpolation, not with `+` and `.to_s`. Use a heredoc for text of several lines:

```ruby
# bad
return name + ": " + count.to_s + " items"

# good
return "#{name}: #{count} items"

# good
return <<~TEXT
  usage: tool FILE
  prints the lines of FILE
TEXT
```

Use a `List` for order, a `Set` for membership, a `Map` for lookup by key, and a struct for a record with known fields.
