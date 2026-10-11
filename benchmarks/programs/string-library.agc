def scale() -> Int
  return 1
end

def main() -> Void
  base = "Crème brûlée, naïve café; Straße ΟΔΥΣΣΕΥΣ 😀 smörgåsbord, jalapeño"
  rounds = 300 * scale()
  checksum = 0
  last = ""
  round = 0
  while round < rounds
    text = "#{round}: #{base}, #{base}"
    parts = text.split(", ")
    words = parts.map do |part|
      part.trim.upcase
    end
    joined = words.join(" | ")
    swapped = joined.replace("É", "e").downcase
    found = swapped.index_of("smörgåsbord")
    case found
      ok(at) -> checksum += at
      error(message) -> checksum -= 1
    end
    j = 0
    n = swapped.length
    while j < n
      checksum += swapped.at(j).code % 7
      j += 1
    end
    last = swapped
    round += 1
  end
  puts("string-library #{rounds}: #{checksum}")
  puts(last)
end
