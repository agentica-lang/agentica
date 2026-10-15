def scale() -> Int
  return 1
end

def main() -> Void
  rounds = 5 * scale()
  checksum = 0
  round = 0
  while round < rounds
    seen: Set[Int] = Set.new([])
    i = 0
    while i < 6000
      seen = seen.add((i * 7919 + round) % 1009)
      i += 1
    end
    hits = 0
    j = 0
    while j < 6000
      if seen.include?((j * 31 + round) % 2003)
        hits += 1
      end
      j += 1
    end
    k = 0
    while k < 1009
      if k % 3 == 0
        seen = seen.delete(k)
      end
      k += 1
    end
    low = Set.new((round..(round + 499)).to_a)
    both = seen.intersection(low)
    either = seen.union(low)
    rest = seen.difference(low)
    position = 1
    for key in seen
      checksum = (checksum + key * position) % 1000000007
      position += 1
    end
    checksum = (checksum + hits + seen.size + both.size + either.size + rest.size) % 1000000007
    round += 1
  end
  puts("sets #{rounds}: checksum #{checksum}")
end
