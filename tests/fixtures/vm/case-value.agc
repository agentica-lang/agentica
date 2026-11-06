enum Kind
  Big
  Small
  Sized(Int)
end

def label(kind: Kind) -> String
  return case kind
    Kind.Big -> "big"
    Kind.Small -> "small"
    Kind.Sized(n) if n > 10 -> "large #{n}"
    Kind.Sized(n) -> "sized #{n}"
  end
end

def noisy(n: Int) -> Int
  puts("noisy #{n}")
  return n
end

def main() -> Void
  r: Result[Int] = ok(3)
  text = case r
    ok(n) -> "got #{n}"
    error(message) -> "failed: #{message}"
  end
  puts(text)

  size = case text
    "got 3" ->
      base = noisy(2)
      base + 1
    _ -> noisy(0)
  end
  size += case size
    3 -> 10
    _ -> 20
  end
  puts(size)

  for kind in [Kind.Big, Kind.Small, Kind.Sized(4), Kind.Sized(40)]
    puts(label(kind))
  end

  names = [Kind.Big, Kind.Small, Kind.Sized(1)].map do |kind|
    case kind
      Kind.Big -> 1
      Kind.Small -> 2
      _ -> 0
    end
  end
  puts(names)

  steps = [1, 2, 3].map do |n|
    doubled = n * 2
    case doubled
      4 -> "four"
      _ -> "other #{doubled}"
    end
  end
  puts(steps)
end
