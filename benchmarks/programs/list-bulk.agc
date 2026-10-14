def scale() -> Int
  return 1
end

def main() -> Void
  rounds = 4 * scale()
  total = 0
  round = 0
  while round < rounds
    filled = List.repeat(round, 500000)
    numbers = (0...500000).to_a
    backwards = numbers.reverse
    head = backwards.take(250000)
    tail = backwards.drop(250000)
    joined = head.concat(tail)
    text = List.repeat("x", 300000).join("")
    letters = String.split(text, "")
    ordered = backwards.take(60000).sort
    total = (total + filled[round] + numbers[round] + backwards[round] + head.size + tail.size + joined[499999] + letters.size + text.length + ordered[round]) % 1000000007
    round += 1
  end
  puts("list-bulk #{rounds}: checksum #{total}")
end
