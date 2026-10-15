def parse(text: String) -> Result[Int]
  n = try text.to_int
  if n < 0
    return error("negative")
  end
  return ok(n)
end

def twice(text: String) -> Result[Int]
  a = try parse(text)
  b = try parse(text + "0")
  return ok(a + b)
end

def run() -> Result[Void]
  try twice("1")
  return ok()
end

def main() -> Void
  r = twice("5")
  puts(r.ok?)
  puts(r.unwrap_or(0))
  puts(Result.message(parse("x")))
  puts(parse("7").unwrap!)
  case run()
    ok(_) -> puts("ok")
    error(m) -> puts(m)
  end
end
