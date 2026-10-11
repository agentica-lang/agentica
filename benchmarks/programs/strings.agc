def scale() -> Int
  return 1
end

def main() -> Void
  words = ["alpha", "beta", "gamma", "delta", "epsilon"]
  rounds = 2000 * scale()
  lines = 0
  last = ""
  round = 0
  while round < rounds
    line = "#{round}:"
    k = 0
    for word in words
      line = line + " " + word + "=" + "#{(round * 31 + k * 7) % 97}"
      k += 1
    end
    i = 0
    while i < 10
      line = line + "[#{i * round % 13}]"
      i += 1
    end
    if line != last
      lines += 1
    end
    last = line
    round += 1
  end
  puts("strings #{rounds}: distinct #{lines}")
  puts(last)
end
