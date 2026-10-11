def main() -> Void
  ages = {"Ana": 31, "Bo": 4, "Cy": 27}
  puts(Map.size(ages))
  puts(ages.size)
  empty: Map[String, Int] = {}
  puts(empty.size)
  puts(Map.has_key?(ages, "Bo"))
  puts(ages.has_key?("Zed"))
  puts(Map.keys(ages))
  puts(ages.values)
  puts(empty.keys)
  puts(empty.values)
  older = Map.put(ages, "Dee", 50)
  puts(older)
  puts(ages)
  puts(ages.put("Ana", 32))
  puts(ages.put("Ana", 32).keys)
  puts(Map.get(ages, "Ana"))
  puts(ages.get("Nope"))
  puts(ages.get("Nope", -1))
  puts(ages.get("Cy", -1))
  ints = {3: "three", -1: "minus one"}
  puts(ints.get(-1))
  puts(ints.get(7))
  odd = {"q\"uote\n": 1}
  puts(odd.get("tab\there"))
  puts(odd.get("λ"))
  puts(Map.delete(ages, "Bo"))
  puts(ages.delete("Nope"))
  puts(ages.delete("Ana").delete("Cy"))
  puts(ages.delete("Ana").delete("Cy").delete("Bo"))
  puts(ages.delete("Ana").delete("Cy").delete("Bo").size)
  puts(ages.delete("Bo").put("Bo", 5))
  puts(ages.delete("Cy").values)
  puts(ages)
  counts: Map[Int, Int] = {}
  i = 0
  while i < 26
    counts = counts.put(i % 13, counts.get(i % 13, 0) + i)
    i += 1
  end
  puts(counts)
  j = 0
  while j < 13
    if j % 2 == 0
      counts = counts.delete(j)
    end
    j += 1
  end
  puts(counts)
  puts(counts.keys)
  puts(counts.values)
  puts(counts.size)
  nested = {"a": [1, 2], "b": []}
  puts(nested.get("a"))
  puts(nested.values)
  case nested.get("c")
    ok(v) -> puts(v)
    error(m) -> puts("missing: #{m}")
  end
end
