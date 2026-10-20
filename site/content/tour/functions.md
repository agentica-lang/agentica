---
title: Functions
weight: 6
description: Define functions, return values, recursion and function values.
---

## Define a function

`def` defines a function. Every parameter and the result need a type.

```agentica
def greet(name: String) -> String
  return "Hello, #{name}!"
end

def main() -> Void
  puts(greet("Ana"))
end
```

```output
Hello, Ana!
```

Calls always use parentheses, also with no arguments: `main()`, `puts("hi")`. Arguments are given by position, and trailing parameters can have default values (see below).

## return

A function that gives a value must `return` on every path. The last line is not returned on its own.

```agentica
def max(a: Int, b: Int) -> Int
  if a > b
    return a
  end
  return b
end

def main() -> Void
  puts(max(3, 9))
end
```

```output
9
```

Forgetting a `return` is a checker error:

```agentica {expect="CHECK-MISSING-RETURN"}
def double(n: Int) -> Int
  n * 2
end

def main() -> Void
  puts(double(2))
end
```

## Void functions

A function that gives nothing returns `Void`. It ends at its last line, or at a bare `return`.

```agentica
def report(count: Int) -> Void
  if count == 0
    puts("nothing")
    return
  end
  puts("#{count} items")
end

def main() -> Void
  report(0)
  report(3)
end
```

```output
nothing
3 items
```

## Order and recursion

Functions can be called before they are defined, and can call themselves.

```agentica
def main() -> Void
  puts(factorial(5))
end

def factorial(n: Int) -> Int
  if n <= 1
    return 1
  end
  return n * factorial(n - 1)
end
```

```output
120
```

A call that is the whole value of a `return` reuses the caller's frame. Other calls count toward the limit of 10000 nested calls; a call of a builtin uses no frame. The nesting limits of the source (`PARSE-TOO-DEEP`, `CHECK-TOO-DEEP`) are in the [language reference](/reference/).

## Many results

A function returns one value. To give back several, return a [struct](/tour/structs/).

```agentica
struct MinMax
  min: Int
  max: Int
end

def min_max(xs: List[Int]) -> MinMax
  sorted = xs.sort
  return MinMax(min: sorted[0], max: sorted[sorted.size - 1])
end

def main() -> Void
  result = min_max([4, 1, 9, 3])
  puts("#{result.min} to #{result.max}")
end
```

```output
1 to 9
```

## Function values

`&name` is a function as a value. Its type is `Fn[...]`: the parameter types, then the result type. Call it with `.call(...)`.

```agentica
def double(n: Int) -> Int
  return n * 2
end

def apply(f: Fn[Int, Int], value: Int) -> Int
  return f.call(value)
end

def main() -> Void
  f: Fn[Int, Int] = &double
  puts(f.call(21))
  puts(apply(&double, 5))
  puts([1, 2, 3].map(&double))
end
```

```output
42
10
[2, 4, 6]
```

`Fn[Void]` is a function with no parameters that gives nothing. Function values can live in lists, maps and struct fields.

[Blocks](/tour/blocks/) are the short way to write a function value at the place where you use it.

## Chain calls with |>

`x |> f(a)` means `f(x, a)`: the left value becomes the first argument.

```agentica
def parse(text: String) -> Result[Int]
  return text.to_i
end

def validate(n: Int) -> Result[Int]
  if n < 0
    return error("negative")
  end
  return ok(n)
end

def add(a: Int, b: Int) -> Int
  return a + b
end

def load(text: String) -> Result[Int]
  return text.trim |> try parse() |> validate()
end

def main() -> Void
  puts(1 |> add(2) |> add(3))
  puts(load(" 7 ").inspect)
  puts(load("-3").inspect)
  total = (10
    |> add(1)
    |> add(100))
  puts(total)
end
```

```output
6
ok(7)
error("negative")
111
```

- The right side must be a call with parentheses. A multi-line chain goes in parentheses, as `total` above.
- It may start with `try`: `x |> try f()` means `try f(x)`.
- A builtin with a method form uses `.`: `s.trim`, not `s |> String.trim()` (`CHECK-PIPE-METHOD`).

```agentica {expect="CHECK-PIPE-METHOD"}
def main() -> Void
  s = " hi "
  puts(s |> String.trim())
end
```

## Default parameter values

A parameter can end with `= value`. A call may leave it out.

- A default is a constant: a number, a string without `#{...}`, `true`, `false`, `nil`, `[]`, `{}` or a variant without a payload such as `Level.Info`. Anything else is `CHECK-DEFAULT-VALUE`. Each call gets its own `[]` or `{}`.
- Parameters with a default go last (`CHECK-DEFAULT-ORDER`). The exception is a last `Fn` parameter, which a block fills.
- Arguments fill the parameters from the left. A wrong count is `CHECK-ARITY`, such as `expects 1 to 2 arguments`.

```agentica
def join(words: List[String], sep: String = ", ") -> String
  return words.join(sep)
end

def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void
  f.call("#{path} after #{timeout_ms} ms")
end

def show(line: String) -> Void
  puts(line)
end

def main() -> Void
  puts(join(["a", "b"]))
  puts(join(["a", "b"], "-"))
  each_line("a.txt") do |line|
    puts(line)
  end
  each_line("b.txt", 50, &show)
end
```

```output
a, b
a-b
a.txt after 1000 ms
b.txt after 50 ms
```

```agentica {expect="CHECK-DEFAULT-VALUE"}
def next_id() -> Int
  return 1
end

def label(id: Int = next_id()) -> String
  return "item #{id}"
end

def main() -> Void
  puts(label())
end
```

## No overloading

A name has one definition: no overloading, no keyword arguments and no methods on your own types. Use a default value instead of a second version.
