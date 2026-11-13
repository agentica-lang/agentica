## Generic functions that another file imports: the type parameter stays local, in the signature and the body.

struct Pool[T]
  items: List[T]
end

def new[T](items: List[T]) -> Pool[T]
  return Pool(items: items)
end

def first_or[T](xs: List[T], fallback: T) -> T
  if xs.length == 0
    return fallback
  end

  return xs[0]
end

def with[T, R](pool: Pool[T], body: Fn[T, Result[R]]) -> Result[R]
  if pool.items.length == 0
    return error("empty pool")
  end

  return body.call(pool.items[0])
end
