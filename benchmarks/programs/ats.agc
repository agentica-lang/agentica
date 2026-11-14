def scale() -> Int
  return 1
end

def main() -> Void
  rounds = 5 * scale()
  checksum = 0
  round = 0
  while round < rounds
    counts: ATS[Int, Int] = ATS.new()
    i = 0
    while i < 6000
      key = (i * 7919 + round) % 1009
      if i % 2 == 0
        _ = counts.add(key, 1)
      else
        counts.put(key, counts.get(key).unwrap_or(0) + 1)
      end

      i += 1
    end

    j = 0
    while j < 1009
      if j % 3 == 0 and counts.has_key?(j)
        counts.delete(j)
      end

      j += 1
    end

    for key in counts.keys
      checksum = (checksum + key * counts.get(key).unwrap_or(0)) % 1000000007
    end

    checksum = (checksum + counts.size) % 1000000007
    round += 1
  end

  puts("ats #{rounds}: checksum #{checksum}")
end
