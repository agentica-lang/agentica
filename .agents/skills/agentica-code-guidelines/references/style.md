# Style rules with examples

Read this when a rule in SKILL.md needs a bad/good pair, or a review needs an example to quote. Every example here was run with the release binary: a `bad` one is accepted by the checker unless its first line names a diagnostic, and then it is refused with that code. A `bad` one with no code is bad style only; the checker does not see it.

## Layout

Wrap a long call one item per line with a trailing comma, and a long expression in parentheses.

```ruby
# bad
def label(first: String, last: String, title: String, suffix: String) -> String
  return "#{title} #{first} #{last}, #{suffix}, member of the board of directors of the company since the year 2001"
end
```

```ruby
# good
def label(first: String, last: String, title: String, suffix: String) -> String
  return (
    "#{title} #{first} #{last}, #{suffix}, " +
    "member of the board of directors of the company since the year 2001"
  )
end
```

```ruby
# good
struct User
  name: String
  age: Int
  email: String
end

def sample() -> User
  return User(
    name: "Ana",
    age: 25,
    email: "ana@example.com",
  )
end
```

A blank line follows the `end` of every top-level declaration.

```ruby
# bad PARSE-MISSING-BLANK-LINE
def one() -> Int
  return 1
end
def main() -> Void
  puts(one().to_s)
end
```

## Naming

The checker refuses a wrong first letter, but not a wrong style inside the name.

```ruby
# bad
LIMIT = 10

def readLine(maxLen: Int) -> String
  return "x".slice(0, maxLen)
end

def is_blank(text: String) -> Bool
  return text.length == 0
end
```

```ruby
# good
LIMIT = 10

def read_line(max_len: Int) -> String
  return "x".slice(0, max_len)
end

def blank?(text: String) -> Bool
  return text.length == 0
end
```

A constant must be in capitals.

```ruby
# bad PARSE-CONSTANT-NAME
Limit = 10

def main() -> Void
  puts(Limit.to_s)
end
```

Say it positively. Put the positive branch first and never combine a negated test with `else`.

```ruby
# bad
def describe(hidden: Bool) -> String
  if !hidden
    return "shown"
  else
    return "hidden"
  end
end
```

```ruby
# good
def describe(visible: Bool) -> String
  if visible
    return "shown"
  end
  return "hidden"
end
```

## Modules and docs

The order of a file is fixed: a function declared before a struct is refused.

```ruby
# bad CHECK-DECL-ORDER
def main() -> Void
  puts("x")
end

struct Item
  name: String
end
```

A doc says what the function returns. A comment says why.

```ruby
# bad
## This function loops over the items and adds up the prices.
def total(prices: List[Int]) -> Int
  sum = 0
  # add each price to sum
  for price in prices
    sum += price
  end
  return sum
end
```

```ruby
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

```ruby
# bad PARSE-DETACHED-DOC
## Returns one.
# a comment between the doc and the def
def one() -> Int
  return 1
end

def main() -> Void
  puts(one().to_s)
end
```

```ruby
# good
# Why 3: the server drops a client after the third failed login.
MAX_TRIES = 3

## Returns true when the client may try again.
def retry?(tries: Int) -> Bool
  return tries < MAX_TRIES
end
```

## Functions

Group many parameters in a struct, and use guard returns so the main path stays flat.

```ruby
# bad
def ship(weight: Int, width: Int, height: Int, depth: Int, rush: Bool, insured: Bool) -> Int
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
```

```ruby
# good
struct Parcel
  weight: Int
  width: Int
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
```

A record with known fields is a struct, not a map of strings.

```ruby
# bad
def greet(user: Map[String, String]) -> String
  return "hello #{user.get("name").unwrap_or("?")}"
end
```

```ruby
# good
struct User
  name: String
end

def greet(user: User) -> String
  return "hello #{user.name}"
end
```

A running total is a `for` loop. A block cannot assign an outer name.

```ruby
# bad CHECK-CAPTURED-ASSIGNMENT
def total(xs: List[Int]) -> Int
  sum = 0
  xs.each do |x|
    sum += x
  end
  return sum
end
```

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

Use a Bool as itself, and `and`, `or`, `not`.

```ruby
# bad
def allowed(admin: Bool, banned: Bool) -> Bool
  if admin == true && banned == false
    return true
  end
  return false
end
```

```ruby
# good
def allowed?(admin: Bool, banned: Bool) -> Bool
  return admin and not banned
end
```

Name an enum for states instead of passing codes.

```ruby
# bad
def color_name(code: Int) -> String
  if code == 0
    return "red"
  elsif code == 1
    return "green"
  end
  return "unknown"
end
```

```ruby
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
```

## Pipes

Three or more steps on one value: a chain in parentheses, the value first (a name, a literal or the call that makes it), one step per line.

```ruby
# bad
def trim_all(text: String) -> String
  return text
end

def shout(text: String) -> String
  return text.upcase
end

def wrap(text: String, mark: String) -> String
  return "#{mark}#{text}#{mark}"
end

def banner(text: String) -> String
  out = trim_all(text)
  out = shout(out)
  out = wrap(out, "*")
  return out
end
```

```ruby
# good
def trim_all(text: String) -> String
  return text
end

def shout(text: String) -> String
  return text.upcase
end

def wrap(text: String, mark: String) -> String
  return "#{mark}#{text}#{mark}"
end

def banner(text: String) -> String
  return (
    text
    |> trim_all()
    |> shout()
    |> wrap("*")
  )
end
```

Nested calls three deep read inside out. A single step is a plain call.

```ruby
# bad
def inc(n: Int) -> Int
  return n + 1
end

def double(n: Int) -> Int
  return n * 2
end

def main() -> Void
  puts(double(inc(inc(1))))
  puts(1 |> inc())
end
```

```ruby
# good
def inc(n: Int) -> Int
  return n + 1
end

def double(n: Int) -> Int
  return n * 2
end

def main() -> Void
  puts(1 |> inc() |> inc() |> double())
  puts(inc(1))
end
```

A builtin with a method form is not piped.

```ruby
# bad CHECK-PIPE-METHOD
def main() -> Void
  puts("x" |> String.upcase())
end
```

```ruby
# good
def main() -> Void
  puts(["b", "a"].sort.join(","))
end
```

`try` goes in front of the step that returns a Result.

```ruby
# good
def parse(text: String) -> Result[Int]
  return text.trim.to_i
end

def check(n: Int) -> Result[Int]
  if n < 0
    return error("negative: #{n}")
  end
  return ok(n)
end

def load(text: String) -> Result[Int]
  return text |> try parse() |> check()
end
```

## case and if

List every variant of an enum and leave out `_`: a new variant then fails the check where it must be handled.

```ruby
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
```

```ruby
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
```

```ruby
# bad CHECK-NON-EXHAUSTIVE-CASE
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> return r * r * 3
  end
end
```

Nested `if` on one value is a `case`; specific arms and guards come first.

```ruby
# bad
def size_name(n: Int) -> String
  if n == 0
    return "empty"
  else
    if n == 1
      return "one"
    else
      if n < 10
        return "few"
      end
    end
  end
  return "many"
end
```

```ruby
# good
def size_name(n: Int) -> String
  case n
    0 -> return "empty"
    1 -> return "one"
    _ -> return pick_big(n)
  end
end

def pick_big(n: Int) -> String
  if n < 10
    return "few"
  end
  return "many"
end
```

```ruby
# good
enum Reading
  Value(Int)
  Missing
end

def describe(r: Result[Reading]) -> String
  case r
    ok(Reading.Value(n)) if n < 0 -> return "negative #{n}"
    ok(Reading.Value(n)) -> return "value #{n}"
    ok(_) -> return "missing"
    error(message) -> return message
  end
end
```

## Errors

Return a Result and pass it up with `try`. The halting form is for a bug.

```ruby
# bad
def double_text(text: String) -> Int
  return text.to_i! * 2
end
```

```ruby
# good
def double_text(text: String) -> Result[Int]
  n = try text.to_i
  return ok(n * 2)
end
```

An error text is lowercase, has no final period, and shows the bad value.

```ruby
# bad
def port(n: Int) -> Result[Int]
  if n < 1 or n > 65535
    return error("Invalid port.")
  end
  return ok(n)
end
```

```ruby
# good
def port(n: Int) -> Result[Int]
  if n < 1 or n > 65535
    return error("port out of range: #{n}")
  end
  return ok(n)
end
```

Handle the error at the edge.

```ruby
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

## Strings and collections

Interpolate; do not join pieces with `+` and `.to_s`.

```ruby
# bad
def line(name: String, count: Int) -> String
  return name + ": " + count.to_s + " items"
end
```

```ruby
# good
def line(name: String, count: Int) -> String
  return "#{name}: #{count} items"
end
```

Text of several lines is a heredoc.

```ruby
# good
def help() -> String
  return <<~TEXT
    usage: tool FILE
    prints the lines of FILE
  TEXT
end
```

Name a number that has a meaning, and use `_` to read a big one.

```ruby
# bad
def too_big?(bytes: Int) -> Bool
  return bytes > 1048576
end
```

```ruby
# good
MAX_BYTES = 1_048_576

def too_big?(bytes: Int) -> Bool
  return bytes > MAX_BYTES
end
```
