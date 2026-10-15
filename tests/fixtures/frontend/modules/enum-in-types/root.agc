import "a" as A

enum Local[T]
  Wrap(A.Opt[T])
  Two(T, List[T], A.W)
  Plain(Int)
end

def main() -> Void
  x = Local.Plain(1)
  y = A.Opt.Some(1)
  z = Await.TimedOut
  w = LogLevel.Debug
  case y
    A.Opt.Some(v) -> puts(v)
    A.Opt.Nope -> puts(0)
  end
  case x
    Local.Plain(n) -> puts(n)
    _ -> puts(0)
  end
  case ok(1)
    ok(v) -> puts(v)
    error(m) -> puts(m)
  end
end

