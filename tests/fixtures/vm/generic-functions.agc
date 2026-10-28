import Lib from "lib/generic_functions_lib"
import {first_or} from "lib/generic_functions_lib"

enum Maybe[T]
  Some(T)
  Nothing
end

struct Box[T]
  value: T
end

def max_by[T](xs: List[T], key: Fn[T, Int]) -> Result[T]
  if xs.length == 0
    return error("empty list")
  end

  best = xs[0]
  best_key = key.call(best)
  for x in xs
    k = key.call(x)
    if k > best_key
      best = x
      best_key = k
    end
  end

  return ok(best)
end

def map_list[T, U](xs: List[T], f: Fn[T, U]) -> List[U]
  out: List[U] = []
  for x in xs
    out = out.push(f.call(x))
  end

  return out
end

def fold[T, A](xs: List[T], init: A, f: Fn[A, T, A]) -> A
  acc = init
  for x in xs
    acc = f.call(acc, x)
  end

  return acc
end

def wrap[T](x: T) -> Maybe[Box[T]]
  return Maybe.Some(Box(value: x))
end

def unwrap_or[T](m: Maybe[T], fallback: T) -> T
  case m
    Maybe.Some(v) -> return v
    Maybe.Nothing -> return fallback
  end
end

def empty_of[T]() -> List[T]
  return []
end

def count[T](xs: List[T]) -> Int
  if xs.size == 0
    return 0
  end

  return 1 + count(xs.drop(1))
end

# Polymorphic recursion: each call nests the item one list deeper.
def depth[T](x: T, n: Int) -> Int
  if n == 0
    return 0
  end

  return 1 + depth([x], n - 1)
end

def ping[T](x: T, n: Int) -> T
  if n == 0
    return x
  end

  return pong(x, n - 1)
end

def pong[T](x: T, n: Int) -> T
  return ping(x, n)
end

def apply[T](f: Fn[T, T], x: T) -> T
  return f.call(x)
end

def keep[T](x: T) -> T
  return x
end

# The builtin block methods read the element type of a List[T] inside the body.
def count_if[T](xs: List[T], keep: Fn[T, Bool]) -> Int
  return xs.filter do |x| keep.call(x) end.size
end

def groups[T](xs: List[T], key: Fn[T, String]) -> Int
  return xs.group_by do |x| key.call(x) end.size
end

def double(n: Int) -> Int
  return n * 2
end

def main() -> Void
  # T comes from the arguments, from left to right; an empty list is checked last.
  puts(first_or(["ana", "ben"], "none"))
  puts(first_or([], 0))
  puts(Lib.first_or([], "none"))

  # The block comes last: its parameter types come from T, and its result binds the others.
  words = ["pear", "fig", "banana"]
  longest = max_by(words) do |w|
    w.length
  end
  puts(longest.unwrap_or("none"))
  puts(max_by([]) do |w: String| w.length end.ok?)
  puts(map_list([1, 2, 3]) do |n| n.to_s end)
  puts(fold([1, 2, 3], "") do |a, n| a + n.to_s end)

  db = Lib.new([3, 4])
  doubled = Lib.with(db) do |conn|
    ok(conn * 2)
  end
  puts(doubled.unwrap_or(0))
  nobody: Lib.Pool[Int] = Lib.new([])
  puts(Lib.with(nobody) do |conn| ok(conn) end.unwrap_or(-1))

  # The expected type gives a type that only the result has.
  empty: List[Int] = empty_of()
  puts(empty.size)

  puts(unwrap_or(wrap(3), Box(value: 0)).value)
  puts(unwrap_or(Maybe.Nothing, 9))
  puts(count(["a", "b", "c"]))
  puts(depth(1, 3))
  puts(ping("done", 4))

  # A reference is a value where the Fn type fixes each type parameter.
  pick: Fn[List[Int], Int, Int] = &first_or
  puts(pick.call([], 7))
  puts(apply(&keep, 5))
  puts(apply(&double, 21))

  puts(count_if([1, 2, 3, 4]) do |n| n > 2 end)
  puts(groups(["a", "bb", "cc"]) do |w| w.length.to_s end)
end
