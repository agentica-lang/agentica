# Functions with type parameters: first_or and max_by work on any item type. A call gives no type arguments; the checker
# finds them from the arguments, then from the expected type, then from the empty literals, then from the block.
struct Pool[T]
  items: List[T]
end

# The first item of xs, or fallback when xs is empty.
def first_or[T](xs: List[T], fallback: T) -> T
  return fallback if xs.length == 0

  return xs[0]
end

# The item with the largest key, or none when xs is empty.
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

  return some(best)
end

# Runs body on the first item of the pool, or fails when the pool is empty.
def with[T, R](pool: Pool[T], body: Fn[T, Result[R]]) -> Result[R]
  return error("empty pool") if pool.items.length == 0

  return body.call(pool.items[0])
end

def double(n: Int) -> Int = n * 2

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
