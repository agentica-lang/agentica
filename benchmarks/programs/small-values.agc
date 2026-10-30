def scale() -> Int
  return 1
end

def main() -> Void
  rounds = 2 * scale()
  text = List.repeat("ab,cd ef,,g", 3000).join(" ")
  n = text.length
  nothing: List[String] = []
  no_ints: List[Int] = []
  no_items: Map[Int, Int] = {}
  checksum = 0
  round = 0
  while round < rounds
    # One-character Strings: at, slice, from_code and split("").
    i = 0
    while i < n
      checksum += text.at(i).code + text.slice(i, 1).code + String.from_code(97 + i % 26).code
      i += 1
    end
    checksum += text.split("").size

    # Empty Strings: pieces between separators, a slice of no characters, blanks trimmed away and a join of nothing.
    for piece in text.split(",")
      checksum += piece.slice(0, 0).length + "  ".trim.length + piece.trim.length + nothing.join(",").length
    end

    # Empty Lists and Maps: a default for a missing key, a seed for reduce, a filter that keeps nothing.
    groups: Map[Int, List[Int]] = {}
    j = 0
    while j < 8000
      groups = groups.put(j % 101, groups.get(j % 101, []).push(j))
      j += 1
    end
    counts = text.split(" ").reduce(no_items) do |acc, word| acc.put(word.length, acc.get(word.length, 0) + 1) end
    drops = 0
    k = 0
    while k < 8000
      drops += [k, k + 1, k + 2, k + 3].filter do |x| x < 0 end.size
      k += 1
    end
    checksum += groups.size + groups.get(7, []).size + counts.size + counts.get(2, 0) + drops

    # Empty Sets: a Set built from nothing, the last element deleted and a difference with nothing left.
    seen = 0
    m = 0
    while m < 8000
      one = Set.new([m])
      seen += Set.new(no_ints).size + one.delete(m).size + one.difference(one).size
      m += 1
    end
    checksum = (checksum + seen) % 1000000007
    round += 1
  end
  puts("small-values #{rounds}: checksum #{checksum}")
end
