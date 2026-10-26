# Map and Set order after many deletes: deleted keys put back go last, replaced
# values keep their place, and the key list is rebuilt once deleted keys
# outnumber the live ones. tests/fixtures/map-delete-order.py prints the same
# output from Python dicts.

def build_ints(n: Int) -> Map[Int, Int]
  m: Map[Int, Int] = {}
  i = 0
  while i < n
    m = m.put(i * 37 % 1009, i)
    i += 1
  end
  return m
end

def build_words(n: Int) -> Map[String, Int]
  m: Map[String, Int] = {}
  i = 0
  while i < n
    m = m.put("w#{i * 53 % 997}", i)
    i += 1
  end
  return m
end

def churn_ints(m: Map[Int, Int], n: Int) -> Map[Int, Int]
  out = m
  i = 0
  while i < n
    key = i * 37 % 1009
    if i % 3 != 0
      out = out.delete(key)
    end
    i += 1
  end
  i = 0
  while i < n
    key = i * 37 % 1009
    if i % 9 == 1
      out = out.put(key, -i)
    elsif i % 6 == 0
      out = out.put(key, i * 100)
    end
    i += 1
  end
  return out.delete(5000)
end

def churn_words(m: Map[String, Int], n: Int) -> Map[String, Int]
  out = m
  i = 0
  while i < n
    if i % 3 != 2
      out = out.delete("w#{i * 53 % 997}")
    end
    i += 1
  end
  i = 0
  while i < n
    if i % 7 == 0
      out = out.put("w#{i * 53 % 997}", -i)
    end
    i += 1
  end
  return out.delete("absent")
end

def same_ints(a: Map[Int, Int], b: Map[Int, Int]) -> Bool
  return a.size == b.size and a.to_s == b.to_s
end

def main() -> Void
  ints = churn_ints(build_ints(300), 300)
  puts(ints.size)
  puts(ints.keys)
  puts(ints.values)
  puts(ints)
  sum = 0
  position = 1
  for key in ints.keys
    sum = (sum + key * position + ints[key]) % 1000000007
    position += 1
  end
  puts(sum)
  puts(JSON.encode(ints.keys))

  words = churn_words(build_words(300), 300)
  puts(words.size)
  puts(words)
  puts(JSON.encode(words))

  # The same content reached by another history prints the same.
  fresh: Map[Int, Int] = {}
  for key in ints.keys
    fresh = fresh.put(key, ints[key])
  end
  puts(same_ints(ints, fresh))
  puts(same_ints(ints, ints.delete(ints.keys[0])))

  # Sets with deleted elements.
  s: Set[Int] = Set.new((0...300).to_a)
  i = 0
  while i < 300
    if i % 4 != 0
      s = s.delete(i)
    end
    i += 1
  end
  s = s.add(7).add(0).add(301)
  puts(s)
  low = Set.new((0...150).to_a)
  puts(s.intersection(low))
  puts(s.difference(low))
  puts(s.union(Set.new([302, 4, 3])))
  puts([s.subset?(Set.new((0...302).to_a)), s.subset?(low), s.delete(301).delete(7).subset?(Set.new((0...300).to_a))])
end
