enum Command
  Add(Int)
  Show
end

def ready?() -> Bool
  return true
end

def done!() -> Bool
  puts("called")
  return true
end

def main() -> Void
  n = 0
  b = false
  if !b && (n < 3 || done!())
    n += 5
  end
  n -= 1
  n *= 3
  n /= 2
  n %= 4
  IO.inspect(n)
  IO.inspect(b && done!())
  IO.inspect(ready?() || done!())
  x = 1.5
  x += 0.5
  IO.inspect(x)
  s = "a"
  s += "b"
  IO.inspect(s)
  total = 0
  while !IO.eof? do
    line = IO.gets!.strip
    command: Command = Command.Show()
    if line != "show"
      command = Command.Add(line.to_i!)
    end
    case command do
      Command.Add(k) -> total += k
      Command.Show -> puts("total #{total}")
    end
  end
  big = 9223372036854775807
  big += 1
end
