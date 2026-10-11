struct Pair
  left: Result[Int]
  right: Result[String]
end

struct Deep
  inner: Result[Result[Int]]
end

enum Wrap
  Held(Result[Bool])
  Empty
end

def half(n: Int) -> Result[Int]
  if n % 2 == 1
    return error("odd \"#{n}\"\n")
  end
  return ok(n / 2)
end

def quarter(n: Int) -> Result[Int]
  h = try half(n)
  q = try half(h)
  return ok(q)
end

def eighth(n: Int) -> Result[Int]
  return ok((try quarter(n)) / 2)
end

def check(flag: Bool) -> Result[Void]
  if flag
    return ok()
  end
  return error("flag is off")
end

def both(a: Bool, b: Bool) -> Result[Void]
  try check(a)
  try check(b)
  puts("both on")
  return ok()
end

def label(r: Result[Int]) -> String
  case r
    ok(value) -> return "ok #{value}"
    error(message) -> return "error #{message}"
  end
end

def kind(r: Result[Void]) -> String
  case r
    Result.Err(_) -> return "failed"
    Result.Ok(_) -> return "done"
  end
end

def first(r: Result[List[Int]]) -> Int
  case r
    error(_) -> return -1
    _ -> return Result.unwrap!(r)[0]
  end
end

def sum_halves(xs: List[Int]) -> Result[Int]
  total = 0
  for x in xs
    total = total + try half(x)
  end
  return ok(total)
end

def halve_from(start: Int) -> Result[Int]
  i = start
  total = 0
  while i < 7
    total = total + try half(i)
    i = i + 2
  end
  return ok(total)
end

def via_case(r: Result[Int]) -> Result[String]
  case r
    ok(v) ->
      w = try half(v)
      return ok("half #{w}")
    error(m) ->
      try half(1)
      return ok("never #{m}")
  end
end

def nest(n: Int) -> Result[Result[Int]]
  if n == 0
    return error("outer")
  end
  if n == 1
    return ok(error("inner"))
  end
  return ok(ok(n))
end

def peel_after(n: Int, at: Int) -> Result[Int]
  if n == 0
    return try nest(at)
  end
  return peel_after(n - 1, at)
end

def main() -> Void
  a = ok(1)
  b: Result[Int] = error("bad")
  c = ok()
  d = Result.Ok("text")
  e: Result[String] = Result.Err("tab\there")
  f = ok([ok(1.5), ok(-0.0)])
  g = ok(ok(nil))
  h: List[Result[Int]] = [error("x"), ok(2)]
  puts(a)
  puts(b)
  puts(c)
  puts(d)
  puts(e)
  puts(f)
  puts(g)
  puts(h)
  print(a)
  print("\n")
  IO.warn(b)
  puts("a=#{a} b=#{b} c=#{c}")
  puts(d.to_s)
  puts(d.inspect)
  puts(e.inspect)
  puts(c.to_s)
  puts(Pair(right: error("r"), left: ok(3)))
  puts(Wrap.Held(ok(true)))
  puts(Wrap.Held(error("no")))
  puts(Result.ok?(a))
  puts(b.ok?)
  puts(c.ok?)
  puts(Result.message(a))
  puts(b.message)
  puts(e.message)
  puts(Result.unwrap!(a))
  puts(d.unwrap!)
  Result.unwrap!(c)
  c.unwrap!
  puts(Result.unwrap_or(a, 9))
  puts(b.unwrap_or(9))
  puts(e.unwrap_or("fallback"))
  puts(half(8))
  puts(half(7))
  puts(quarter(8))
  puts(quarter(6))
  puts(quarter(5))
  puts(eighth(16))
  puts(eighth(12))
  puts(both(true, true))
  puts(both(true, false))
  puts(both(false, true))
  puts(label(a))
  puts(label(b))
  puts(label(quarter(12)))
  puts(kind(c))
  puts(kind(check(false)))
  puts(first(ok([4, 5])))
  puts(first(error("none")))
  for r in h
    case r
      ok(n) -> puts("item #{n}")
      error(m) -> puts("item error #{m}")
    end
  end
  case ok("pass")
    ok(text) ->
      puts(text)
    error(_) -> puts("unreachable")
  end
  puts(sum_halves([2, 4, 6]))
  puts(sum_halves([2, 3, 6]))
  puts(halve_from(2))
  puts(halve_from(1))
  puts(via_case(ok(4)))
  puts(via_case(ok(6)))
  puts(via_case(error("e")))
  for k in [0, 1, 2]
    puts(peel_after(3, k))
    case nest(k)
      ok(inner) ->
        case inner
          ok(v) -> puts("inner ok #{v}")
          error(m) -> puts("inner error #{m}")
        end
      error(m) -> puts("outer error #{m}")
    end
  end
  case half(6)
    ok(v) -> puts("called #{v}")
    error(m) -> puts(m)
  end
  z: Result[Int] = error("")
  puts(z)
  puts(z.inspect)
  puts(z.message)
  puts([Deep(inner: ok(error("in"))), Deep(inner: ok(ok(1))), Deep(inner: error("out"))])
  puts([Deep(inner: ok(error("q\"")))].inspect)
end
