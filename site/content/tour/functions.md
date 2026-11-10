---
title: Functions
weight: 6
description: Define functions, return values, recursion and function values.
---

## Define a function

`def` defines a function. Every parameter and the result need a type. A function whose body is one value is written on one line, after `=`; a longer body goes on the lines between the signature and `end` (see `return` and One-line functions below).

```agentica
def greet(name: String) -> String = "Hello, #{name}!"

def main() -> Void
  puts(greet("Ana"))
end
```

```output
Hello, Ana!
```

Calls always use parentheses, also with no arguments: `main()`, `puts("hi")`. Arguments are given by position, and trailing parameters can have default values (see below).

## return

The value of a function is its last expression. When the last statement is an `if` with an `else`, or a `case`, the value is the last expression of the branch or arm that runs. `return` leaves the function early, often as a guard:

```agentica
def max(a: Int, b: Int) -> Int
  return a if a > b

  b
end

def sign(n: Int) -> String
  if n > 0
    "plus"
  elsif n < 0
    "minus"
  else
    "zero"
  end
end

def main() -> Void
  puts(max(3, 9))
  puts(sign(-2))
end
```

```output
9
minus
```

Every path must give a value. An `if` without `else`, a loop or an assignment at the end gives none, and neither does a call of a `Void` function such as `puts`, so this is a checker error:

```agentica {expect="CHECK-MISSING-RETURN"}
def sign(n: Int) -> String
  if n > 0
    "plus"
  end
end

def main() -> Void
  puts(sign(2))
end
```

A `Void` function gives no value: its last expression is a statement like any other.

Code after a `return` can never run, so it is also an error (`CHECK-UNREACHABLE-CODE`): remove it or move it before the `return`.

## One-line functions

A function whose body is one value can be written on one line, with `=` after the result type. It is the same as a `def` whose body is that value.

```agentica
def double(n: Int) -> Int = n * 2

def label(name: String, count: Int = 1) -> String = "#{count} #{name}"

def main() -> Void
  puts(double(4))
  puts(label("apple"))
end
```

```output
8
1 apple
```

The value starts on the line of `=`; it can go on to more lines as any expression can: inside parentheses or a block, or on a next line that starts with `.name`. The result type is still required. A `Void` function has no value to give, so it cannot use this form, and neither can `case` or `if`, which are statements. One-line functions may follow each other with no empty line between them, as constants can; next to any other declaration the empty line is still needed, except right after an import, as for every declaration. `agentica fmt` writes a function whose body is one value, with or without `return`, as a one-line function when it fits and no comment sits from its `def` line to its `end` line, and writes a one-line function as a `def` with the value as its body and `end` when it does not fit, with an empty line on both sides. In an `extern` block, `= "name"` after a signature is the C name of the function instead (see [Native code](/library/io-and-system/native/)).

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
  return 1 if n <= 1

  n * factorial(n - 1)
end
```

```output
120
```

A call that is the whole value of a `return`, or the last expression that gives the function's value, reuses the caller's frame. Other calls count toward the limit of 10000 nested calls; a call of a builtin uses no frame. The nesting limits of the source (`PARSE-TOO-DEEP`, `CHECK-TOO-DEEP`) are in the [language reference](/reference/).

## Many results

A function returns one value. To give back several, return a [struct](/tour/structs/).

```agentica
struct MinMax
  min: Int
  max: Int
end

def min_max(xs: List[Int]) -> MinMax
  sorted = xs.sort
  MinMax(min: sorted[0], max: sorted[sorted.size - 1])
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
def double(n: Int) -> Int = n * 2

def apply(f: Fn[Int, Int], value: Int) -> Int = f.call(value)

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

A function in a struct field is called with the name of the field, like a method: `counter.next(1)` is `counter.next.call(1)`. `counter.next` without parentheses still reads the function. Only a field of type `Fn` can be called this way; any other name is `CHECK-UNKNOWN-METHOD`, as structs have no methods. A field named `to_s` or `inspect` that holds a function wins over the method of that name.

```agentica
struct Counter
  next: Fn[Int, Int]
end

def succ(n: Int) -> Int = n + 1

def main() -> Void
  counter = Counter(next: &succ)
  puts(counter.next(counter.next(1)))
end
```

```output
3
```

[Blocks](/tour/blocks/) are the short way to write a function value at the place where you use it.

## Chain calls with |>

`x |> f(a)` means `f(x, a)`: the left value becomes the first argument.

```agentica
def parse(text: String) -> Result[Int] = text.to_i

def validate(n: Int) -> Result[Int]
  return error("negative") if n < 0

  ok(n)
end

def add(a: Int, b: Int) -> Int = a + b

def load(text: String) -> Result[Int]
  (
    text.strip
    |> try parse()
    |> validate()
  )
end

def main() -> Void
  puts(1 |> add(2) |> add(3))
  puts(load(" 7 ").inspect)
  puts(load("-3").inspect)
  total = (
    10
    |> add(1)
    |> add(100)
  )

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
- A builtin with a method form uses `.`: `s.strip`, not `s |> String.trim()` (`CHECK-PIPE-METHOD`).

```agentica {expect="CHECK-PIPE-METHOD"}
def main() -> Void
  s = " hi "
  puts(s |> String.trim())
end
```

## Default parameter values

A parameter can end with `= value`. A call may leave it out.

- A default is a constant: a number, a string without `#{...}`, `true`, `false`, `nil`, `none`, `[]`, `{}` or a variant without a payload such as `Level.Info`. A struct built with no arguments, `options: Options = Options()`, is a default too when every field of `Options` has one. The name of a constant is a default too when its value is one of these, as in `limit: Int = LIMIT` or `Limits.LIMIT` (the value is used in place of the name, also for a caller in another module). Anything else, `some(1)` or a constant such as `SUM = 1 + 2` too, is `CHECK-DEFAULT-VALUE`. Each call gets its own `[]`, `{}` or struct.
- Parameters with a default go last (`CHECK-DEFAULT-ORDER`). The exception is a last `Fn` parameter, which a block fills.
- Arguments fill the parameters from the left. A wrong count is `CHECK-ARITY`, such as `expects 1 to 2 arguments`.

```agentica
def join(words: List[String], sep: String = ", ") -> String = words.join(sep)

def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void
  f.call("#{path} after #{timeout_ms} ms")
end

def show(line: String) -> Void
  puts(line)
end

def main() -> Void
  puts(join(["a", "b"]))
  puts(join(["a", "b"], "-"))
  each_line("a.txt") do |line| puts(line) end

  each_line("b.txt", 50, &show)
end
```

```output
a, b
a-b
a.txt after 1000 ms
b.txt after 50 ms
```

A default can name a constant, so one value serves many functions:

```agentica
LIMIT = 2

def first(words: List[String], count: Int = LIMIT) -> List[String] = words.take(count)

def main() -> Void
  puts(first(["a", "b", "c"]))
  puts(first(["a", "b", "c"], 3))
end
```

```output
["a", "b"]
["a", "b", "c"]
```

```agentica {expect="CHECK-DEFAULT-VALUE"}
def next_id() -> Int = 1

def label(id: Int = next_id()) -> String = "item #{id}"

def main() -> Void
  puts(label())
end
```

## Type parameters

A function can take type parameters after its name, so one definition works on any type. The call gives no type arguments: the checker finds them from the arguments.

```agentica
def first_or[T](xs: List[T], fallback: T) -> T
  return fallback if xs.length == 0

  xs[0]
end

def max_by[T](xs: List[T], key: Fn[T, Int]) -> Optional[T]
  return none if xs.length == 0

  best = xs[0]
  best_key = key.call(best)
  for x in xs
    k = key.call(x)
    if k > best_key
      best = x
      best_key = k
    end
  end

  some(best)
end

def main() -> Void
  puts(first_or(["ana", "ben"], "none"))
  puts(first_or([], 0))

  longest = max_by(["pear", "fig", "banana"]) do |w| w.length end

  puts(longest.unwrap_or("none"))
end
```

```output
ana
0
banana
```

In `first_or(["ana", "ben"], "none")` the type `T` is `String`, from the first argument. In `first_or([], 0)` the empty list says nothing, so `T` is `Int` from the `0`, and the list is checked last. The result type of the call can also fix `T`, as in `xs: List[Int] = empty_of()` for `def empty_of[T]() -> List[T]`. The block comes last: its parameter types come from `T`, and its result fixes the type parameters that only the result of the `Fn` mentions. A parameter still open is `CHECK-ENUM-TYPE-INFERENCE`. A parameter whose type has `T` takes a default as any other, such as `rest: List[T] = []` or `extra: Optional[T] = none`; a call must still show `T` through another argument or its expected type.

```agentica {expect="CHECK-ENUM-TYPE-INFERENCE"}
def empty_of[T]() -> List[T] = []

def main() -> Void
  xs = empty_of()
end
```

Inside the body, `T` can be any type, so the body can only store it, return it and pass it on. Comparing, adding, printing or reading a field of a `T` value is an error, such as `CHECK-TYPE-MISMATCH` for `==`. To act on the items, take a function, as `max_by` does with `key`. `JSON.encode` and `JSON.from` are the exception: they work on a `T` value, and each call checks that the type it gives `T` can be written as JSON ([JSON](/library/text-and-data/json/)).

```agentica {expect="CHECK-TYPE-MISMATCH"}
def same[T](a: T, b: T) -> Bool = a == b

def main() -> Void
  puts(same(1, 1))
end
```

A type parameter is a type name that no struct, enum or alias of the file has (`CHECK-REDEFINED-NAME`). `&first_or` is a function value only where the `Fn` type fixes each type parameter, as in `f: Fn[List[Int], Int, Int] = &first_or`. A generic function can be exported and imported like any other.

## No overloading

A name has one definition: no overloading, no keyword arguments and no methods on your own types. Use a default value instead of a second version.
