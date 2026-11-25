# Style rules with examples

Bad/good pairs for the rules in SKILL.md that are not obvious. A `bad` example
whose first line names a diagnostic is refused with that code; one without a
code is accepted and is bad style only.

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

## Effects

A test swaps an effect (file, clock, HTTP, random) through a struct of `Fn`
fields: the effects record. Build the real one once at startup, a test builds
another; the checker keeps both the same shape. Reference: `Workspace`
(`compiler/modules/workspace.agc`), built by `compiler/io/host.agc`. Example:
`site/content/style.md`, section Effects.

## Optional, numbers and tasks

Pairs for `&.`, sized numbers and `Task.spawn_link`: `site/content/style.md`,
sections Errors, Numbers and Tasks.
