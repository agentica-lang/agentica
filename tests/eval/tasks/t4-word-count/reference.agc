def main() -> Nil
  counts: Map[String, Int] = {}
  while not IO.eof?()
    line = String.trim(IO.gets!())
    if String.length(line) > 0
      for word in String.split(String.downcase(line), " ")
        if Map.has_key?(counts, word)
          counts = Map.put(counts, word, counts[word] + 1)
        else
          counts = Map.put(counts, word, 1)
        end
      end
    end
  end
  for word in Map.keys(counts)
    puts(word + " " + String.from_int(counts[word]))
  end
end
