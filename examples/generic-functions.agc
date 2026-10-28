# Functions with type parameters: first_or and max_by work on any item type. A call gives no type arguments; the checker
# finds them from the arguments, then from the expected type, then from the empty literals, then from the block.
struct Pool[T]
  items: List[T]
end

## The first item of xs, or fallback when xs is empty.
def first_or[T](xs: List[T], fallback: T) -> T
  if xs.length == 0
    return fallback
  end

  return xs[0]
end

## The item with the largest key, or an error when xs is empty.
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

## Runs body on the first item of the pool, or fails when the pool is empty.
def with[T, R](pool: Pool[T], body: Fn[T, Result[R]]) -> Result[R]
  if pool.items.length == 0
    return error("empty pool")
  end

  return body.call(pool.items[0])
end

def double(n: Int) -> Int
  return n * 2
end

def main() -> Void
  names = ["ana", "ben"]
  puts(first_or(names, "none"))
  puts(first_or([], 0))

  words = ["pear", "fig", "banana"]
  longest = max_by(words) do |w|
    w.length
  end
  puts(longest.unwrap_or("none"))

  db = Pool(items: [3, 4])
  doubled = with(db) do |conn|
    ok(conn * 2)
  end
  puts(doubled.unwrap_or(0))

  pick: Fn[List[Int], Int, Int] = &first_or
  puts(pick.call([], 7))
  puts(first_or([&double], &double).call(21))
end
