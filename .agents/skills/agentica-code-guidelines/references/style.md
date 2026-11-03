# Style rules with examples

Read this when a rule in SKILL.md needs a bad/good pair. Each example was run
with the release binary. A `bad` example whose first line names a diagnostic is
refused with that code; one without a code is accepted and is bad style only.

## Layout

Wrap a long call one item per line with a trailing comma, and a long expression
in parentheses.

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

## Naming

Say it positively. Put the positive branch first and never combine a negated
test with `else`.

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

A `##` doc, only on public code, says what it returns or is. A comment says why.

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
export def total(prices: List[Int]) -> Int
  sum = 0
  for price in prices
    sum += price
  end

  return sum
end
```

## Functions

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

## Pipes

Three or more steps on one value: a chain in parentheses, the value first (a
name, a literal or the call that makes it), one step per line.

Instead of rebinding `out = f(out)` three times:

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

List every variant of a small enum and leave out `_`: a new variant then fails
the check where it must be handled. A `_` is fine when many variants share one
outcome.

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

Specific arms and guards come first; a guarded arm covers nothing.

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
