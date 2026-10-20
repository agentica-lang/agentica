# Lazy

`Lazy[T]` is a lazy pipeline: a source and steps. Building one runs nothing. A
terminal runs it and pulls one item at a time through every step, so no step
builds a whole list. Each terminal runs the source again from the start. A
`Lazy` is a recipe, not a cursor: there is no `next`, `yield`,
`Enumerator.new` or generator (a producer is a task that sends into a
`Channel`, `references/tasks.md`).

Use it for an endless source, or when only the first results of a long chain
are needed. To walk a whole list, use the eager `List` methods.

```text
List.lazy(list: List[A]) -> Lazy[A]
Range.lazy(range: Range) -> Lazy[Int]                         # (1..n).lazy, (0...n).lazy
Lazy.produce(seed: A, f: Fn[A, A]) -> Lazy[A]                 # seed, f(seed), f(f(seed)) ... without end

# Steps: each gives a new Lazy and runs nothing
Lazy.map(lazy: Lazy[A], f: Fn[A, B]) -> Lazy[B]
Lazy.filter(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.take(lazy: Lazy[A], count: Int) -> Lazy[A]               # count < 0 is RUNTIME-INVALID-COUNT
Lazy.take_while(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.drop(lazy: Lazy[A], count: Int) -> Lazy[A]               # count < 0 is RUNTIME-INVALID-COUNT
Lazy.drop_while(lazy: Lazy[A], f: Fn[A, Bool]) -> Lazy[A]
Lazy.flat_map(lazy: Lazy[A], f: Fn[A, List[B]]) -> Lazy[B]
Lazy.with_index(lazy: Lazy[A], f: Fn[A, Int, B]) -> Lazy[B]   # f(item, index), index from 0
Lazy.each_slice(lazy: Lazy[A], size: Int) -> Lazy[List[A]]    # last slice shorter; size < 1 is RUNTIME-INVALID-COUNT
Lazy.each_cons(lazy: Lazy[A], size: Int) -> Lazy[List[A]]     # windows of size neighbours
Lazy.chunk_while(lazy: Lazy[A], f: Fn[A, A, Bool]) -> Lazy[List[A]]   # new group where f(prev, item) is false

# Terminals: always a Result
Lazy.to_a(lazy: Lazy[A]) -> Result[List[A]]
Lazy.first(lazy: Lazy[A], count: Int) -> Result[List[A]]      # take(count) then to_a
Lazy.each(lazy: Lazy[A], f: Fn[A, Result[Void]]) -> Result[Void]   # stops at f's first error and returns it
Lazy.reduce(lazy: Lazy[A], initial: B, f: Fn[B, A, B]) -> Result[B]
Lazy.find(lazy: Lazy[A], f: Fn[A, Bool]) -> Result[A]         # error("not found") when the source ends
```

```ruby
def main() -> Void
  naturals = Lazy.produce(1) do |n| n + 1 end
  odd_squares = naturals.map do |n| n * n end.filter do |n| n % 2 == 1 end
  puts(odd_squares.first(3))                                  # ok([1, 9, 25])
  puts((1..7).lazy.each_slice(3).to_a)                        # ok([[1, 2, 3], [4, 5, 6], [7]])
  done = naturals.each do |n|
    if n > 2
      return error("stop")
    end
    puts(n)
    ok()
  end
  puts(done)                                                  # 1, 2, then error("stop")
end
```

- `take`, `take_while`, `first` and `find` stop the source, so an endless
  source ends. `to_a`, `reduce` and `each` on an endless source never end;
  `--max-steps` stops them (`RUNTIME-STEP-LIMIT`).
- Each item pulled costs one step, each callback a step plus its body. Other
  tasks keep running while a terminal runs. Callbacks run on the calling task;
  a `Lazy` can be shared by tasks.
- No `filter_map`: write `filter` then `map`. No tuples: to keep an item and
  its index, return a struct from `with_index`.
- A `Lazy` has no `==`, `to_s` or JSON form. A `List` method on it (`lz.size`)
  is `CHECK-UNKNOWN-METHOD`: get a list first with `try lz.to_a`. A step only
  `Lazy` has, on a list or range (`xs.each_cons(2)`), is `CHECK-UNKNOWN-METHOD`:
  write `xs.lazy.each_cons(2)`.
- Steps are methods: `lz |> Lazy.map() do ... end` is `CHECK-PIPE-METHOD`.
