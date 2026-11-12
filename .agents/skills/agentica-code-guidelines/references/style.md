# Style rules with examples

Bad/good pairs for the rules in SKILL.md that are not obvious. A `bad` example
whose first line names a diagnostic is refused with that code; one without a
code is accepted and is bad style only.

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

  sum
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

  sum
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

  sum
end
```

```ruby
# good
def total(xs: List[Int]) -> Int
  sum = 0
  for x in xs
    sum += x
  end

  sum
end

def doubled(xs: List[Int]) -> List[Int] = xs.map do |x| x * 2 end
```

## Pipes

Three or more steps on one value: a chain in parentheses, the value first (a
name, a literal or the call that makes it), one step per line.

Instead of rebinding `out = f(out)` three times:

```ruby
# good
def trim_all(text: String) -> String = text

def shout(text: String) -> String = text.upcase

def wrap(text: String, mark: String) -> String = "#{mark}#{text}#{mark}"

def banner(text: String) -> String
  (
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
def parse(text: String) -> Result[Int] = text.strip.to_i

def check(n: Int) -> Result[Int]
  return error("negative: #{n}") if n < 0

  ok(n)
end

def load(text: String) -> Result[Int]
  (
    text
    |> try parse()
    |> check()
  )
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
    Shape.Circle(r) -> r * r * 3
    _ -> 0
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
    Shape.Circle(r) -> r * r * 3
    Shape.Dot -> 0
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
    ok(Reading.Value(n)) if n < 0 -> "negative #{n}"
    ok(Reading.Value(n)) -> "value #{n}"
    ok(_) -> "missing"
    error(e) -> e.message
  end
end
```

## Errors

Return a Result and pass it up with `try`. The halting form is for a bug.

```ruby
# bad
def double_text(text: String) -> Int = text.to_i! * 2
```

```ruby
# good
def double_text(text: String) -> Result[Int]
  n = try text.to_i
  ok(n * 2)
end
```
