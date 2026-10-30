struct Tags
  name: String
  seen: Set[String]
end

enum Slot
  Held(Set[Int])
  Free
end

def evens(limit: Int) -> Set[Int]
  found: Set[Int] = Set.new([])
  for i in 0..limit
    if i % 2 == 0
      found = found.add(i)
    end
  end
  return found
end

def count_words(words: List[String]) -> Int
  seen: Set[String] = Set.new([])
  for w in words
    seen = seen.add(w)
  end
  return seen.size
end

def describe(slot: Slot) -> String
  case slot
    Slot.Held(items) -> return "held #{items}"
    Slot.Free -> return "free"
  end
end

def main() -> Void
  # Dedup keeps the first insertion; the text form lists elements in that order.
  a = Set.new([3, 1, 2, 3, 1])
  puts(a)
  puts(a.size)
  puts(a.to_a)

  # Sets are immutable: add and delete build new sets.
  b = a.add(9).add(1).add(0)
  puts(a)
  puts(b)
  puts(b.delete(3))
  puts(b.delete(3).add(3))
  puts(b.delete(42))
  puts(a.include?(2))
  puts(a.include?(7))

  # Empty sets need a type; the text form is Set[].
  no_items: Set[Int] = Set.new([])
  puts(no_items)
  puts([no_items.empty?, a.empty?])
  puts(no_items.size)
  puts(no_items.add(5))
  puts(Set.size(a.delete(1).delete(2).delete(3)))

  # Set algebra keeps the order of the first set.
  x = Set.new([5, 4, 3, 2, 1])
  y = Set.new([2, 4, 6, 8])
  puts(x.union(y))
  puts(y.union(x))
  puts(x.intersection(y))
  puts(y.intersection(x))
  puts(x.difference(y))
  puts(y.difference(x))
  puts(Set.union(x, no_items))
  puts(Set.union(no_items, y))
  puts(x.intersection(no_items))
  puts(x.difference(no_items))
  puts(x.difference(x))
  puts([no_items.subset?(x), x.subset?(x), Set.new([2, 4]).subset?(y), y.subset?(x), x.subset?(no_items), no_items.subset?(no_items)])

  # Strings: write form in the text, any characters.
  words = Set.new(["pear", "apple", "pear", "", "日本", "a\"b", "line\nbreak", "é"])
  puts(words)
  puts(words.size)
  puts(words.include?(""))
  puts(words.include?("日本"))
  puts(words.include?("Pear"))
  IO.inspect(words.delete("pear"))
  puts("interpolated: #{words.delete("").delete("é")} and #{a.inspect}")

  # for visits the elements in order; the set is read once, so reassigning it in the body changes nothing.
  walk = Set.new([30, 10, 20])
  for n in walk
    print(n)
    print(" ")
    walk = walk.add(n + 1)
  end
  puts("")
  puts(walk)
  for n in no_items
    puts("never")
  end

  # Delete then add again moves an element to the end.
  order = Set.new(["a", "b", "c"]).delete("a").add("d").add("a")
  puts(order)

  # Extremes of Int, and Int next to String sets of digits.
  big = Set.new([9223372036854775807, -9223372036854775808, 0, -1, 9223372036854775807])
  puts(big)
  puts(big.include?(-9223372036854775808))
  puts(Set.new(["1", "01", "1"]))

  # Sets as values: lists, maps, structs, enums, results and function results.
  tags = Tags(name: "t", seen: Set.new(["x", "y", "x"]))
  puts(tags)
  puts(tags.seen.add("z").size)
  puts([Set.new([1, 2]), Set.new([2, 1]), no_items])
  puts({"low": Set.new([1]), "high": evens(10)})
  puts([describe(Slot.Held(evens(6))), describe(Slot.Free)])
  r: Result[Set[Int]] = ok(Set.new([7, 7]))
  puts(r)
  puts(count_words(["x", "y", "x", "z", "y"]))

  # Test.eq compares sets without regard to order.
  puts(Test.eq(Set.new([1, 2, 3]), Set.new([3, 2, 1])))
  puts(Test.eq(Set.new([1, 2]), Set.new([1, 2, 3])))
  puts(Test.eq(Set.new(["a"]), Set.new(["b"])))

  # A larger set: deduplication, membership and deletion past one trie level.
  grown: Set[Int] = Set.new([])
  for i in 0...300
    grown = grown.add((i * 7) % 100)
  end
  puts(grown.size)
  puts(grown.to_a.take(12))
  shrunk = grown
  for i in 0...90
    shrunk = shrunk.delete(i)
  end
  puts(shrunk)
  puts(grown.size)
  puts([grown.subset?(Set.new((0...100).to_a)), Set.new((0...100).to_a).subset?(grown), shrunk.subset?(grown)])
end
